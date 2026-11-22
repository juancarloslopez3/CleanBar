import AppKit
import SwiftUI

/// What's next to the sensors list, for the row under the pointer.
enum SensorFlyout: Hashable {
    /// The history of a sensor or a fan.
    case history(SensorRow)
    /// How fast the fans turn, for the fans' own row at the top of the list.
    case fans
}

/// Where the flyout's arrow is, pointing at its row.
nonisolated struct FlyoutArrow: Equatable, Sendable {
    /// The side of the flyout it comes out of.
    var edge = HorizontalEdge.trailing
    /// How far its middle is below the flyout's top.
    var y: CGFloat = 0
}

/// The state behind the sensors list.
@Observable
final class SensorPanelModel {
    let monitor: SensorMonitor
    let fans: FanController
    let settings: AppSettings
    private(set) var flyout: SensorFlyout?
    /// The row the flyout goes with. The fans' rows share one.
    private(set) var flyoutRowID: String?
    /// The row under the pointer.
    fileprivate(set) var hoveredRowID: String?
    fileprivate(set) var arrow = FlyoutArrow()

    /// The fans' own row at the top of the list.
    static let fanModeRowID = "fans"

    @ObservationIgnored fileprivate var onHover: ((String, SensorFlyout, NSRect) -> Void)?
    @ObservationIgnored fileprivate var onEndHover: ((String) -> Void)?
    @ObservationIgnored fileprivate var onShowNow: ((String, SensorFlyout, NSRect) -> Void)?
    @ObservationIgnored fileprivate var onEditProfiles: (() -> Void)?

    init(monitor: SensorMonitor, fans: FanController, settings: AppSettings) {
        self.monitor = monitor
        self.fans = fans
        self.settings = settings
    }

    fileprivate func setFlyout(_ flyout: SensorFlyout?, rowID: String?) {
        self.flyout = flyout
        flyoutRowID = rowID
    }

    /// The rows the user wants in the list, in their order.
    var rows: [SensorRow] {
        monitor.rows(order: settings.sensorOrder).filter { !settings.hiddenSensors.contains($0.id) }
    }
}

/// What clicking the temperature in the menu bar shows: a list of the sensors and fans below it, like a menu, and next to
/// it what goes with the row under the pointer, with an arrow pointing at the row: the history of a sensor or a fan, or the
/// fans' settings.
///
/// Like the floating bar, these panels never take the keyboard or make CleanBar the active app, so the app in front keeps
/// both, and they close on Esc, on a click anywhere else, when another app comes to the front, or when the Space or the
/// screens change. The flyout also closes by itself once the pointer has stayed away from it for a moment.
final class SensorPanel {
    /// Called whenever the list closes.
    var onClose: (() -> Void)?
    /// Whether a click outside the list leaves it open, because it opens and closes the list itself, like one on the
    /// temperature in the menu bar. Takes the click's place on the screen.
    var ignoresClick: ((NSPoint) -> Bool)?
    /// "Fan Settings" was clicked, once the list has closed.
    var onEditProfiles: (() -> Void)?

    private(set) var isOpen = false
    private var openedDate = Date.distantPast

    private let model: SensorPanelModel
    private var listPanel: NSPanel?
    private var listHost: NSHostingView<SensorListView>?
    private var flyoutPanel: NSPanel?
    private var anchor: NSRect?
    private var screen: NSScreen?
    /// The row the flyout was last placed next to, in screen coordinates.
    private var flyoutRowFrame = NSRect.zero
    private var flyoutTask: Task<Void, Never>?
    /// Watches for the pointer staying away from the flyout, while there's one.
    private var flyoutPointerTimer: Timer?
    /// When the pointer was first seen away from the flyout.
    private var pointerAwaySince: Date?
    private var monitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private static let gap: CGFloat = 5
    private static let screenMargin: CGFloat = 8
    private static let cornerRadius: CGFloat = 16
    /// How long the pointer has to rest on a row for its flyout to show: a moment when there's none yet, and longer when
    /// there's one, so crossing other rows on the way to it doesn't change it.
    private static let firstFlyoutDelay = 0.1
    private static let nextFlyoutDelay = 0.2
    /// How long the flyout stays once the pointer has left it.
    private static let flyoutLingerTime = 1.0
    private static let flyoutPointerCheckInterval = 0.1
    private static let fadeDuration = 0.12
    private static let openingClickTime = 0.4
    /// How far the tip of the flyout's arrow reaches into the list, close to its row, as a popover's does.
    private static let arrowOverlap: CGFloat = 3

    init(model: SensorPanelModel) {
        self.model = model
        model.onHover = { [weak self] rowID, flyout, frame in self?.pointerEntered(rowID, flyout, rowFrame: frame) }
        model.onEndHover = { [weak self] rowID in self?.pointerExited(rowID) }
        model.onShowNow = { [weak self] rowID, flyout, frame in self?.showFlyout(flyout, rowID: rowID, rowFrame: frame) }
        model.onEditProfiles = { [weak self] in
            self?.close()
            self?.onEditProfiles?()
        }
    }

    /// Opens the list below `anchor` (the temperature in the menu bar, in screen coordinates).
    func show(below anchor: NSRect?, on screen: NSScreen?) {
        guard !isOpen, let screen = screen ?? NSScreen.main else { return }
        isOpen = true
        openedDate = .now
        self.anchor = anchor
        self.screen = screen
        installMonitors()
        let panel = listPanel ?? makeListPanel()
        placeList()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        // The glass settles a moment after it first shows.
        DispatchQueue.main.async { panel.invalidateShadow() }
        fade(panel, to: 1)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        removeMonitors()
        flyoutTask?.cancel()
        stopWatchingFlyoutPointer()
        model.hoveredRowID = nil
        model.setFlyout(nil, rowID: nil)
        if let listPanel {
            fade(listPanel, to: 0) { listPanel.orderOut(nil) }
        }
        if let flyoutPanel {
            fade(flyoutPanel, to: 0) { flyoutPanel.orderOut(nil) }
        }
        onClose?()
    }

    private func fade(_ panel: NSPanel, to alpha: CGFloat, then finish: @escaping @MainActor () -> Void = {}) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = alpha
        } completionHandler: {
            MainActor.assumeIsolated {
                // Not when it opened again meanwhile.
                if panel.alphaValue == alpha {
                    finish()
                }
            }
        }
    }

    // MARK: The list

    private func makeListPanel() -> NSPanel {
        let (panel, host) = Self.makePanel(
            title: String(localized: "Sensors"),
            rootView: SensorListView(model: model, onRowsChange: { [weak self] in self?.placeList() })
        )
        listPanel = panel
        listHost = host
        return panel
    }

    /// Below the temperature, its left end under the temperature's, as with a menu. When it's too long for the screen, it
    /// scrolls.
    ///
    /// Only while it's open, as opening it does this anyway. Resized while it's closed, as when sensors get turned on in
    /// settings, the glass adds the change in height to what's in it a second time once it's next laid out, which cut off the
    /// top of the list and left a gap below it (seen on macOS 27).
    private func placeList() {
        guard isOpen, let listPanel, let listHost, let screen else { return }
        let onRowsChange: () -> Void = { [weak self] in self?.placeList() }
        let fitting = NSHostingView(rootView: SensorListView(model: model, onRowsChange: {})).fittingSize
        let area = screen.visibleFrame
        let top = screen.frame.maxY - MenuBarStrip.height(of: screen) - Self.gap
        let room = top - area.minY - Self.screenMargin
        let height = min(fitting.height, room)
        listHost.rootView = SensorListView(model: model, scrollingHeight: fitting.height > room ? room : nil, onRowsChange: onRowsChange)
        let x = Self.listLeftEdge(below: anchor, width: fitting.width, in: area)
        listPanel.setFrame(NSRect(x: x, y: top - height, width: fitting.width, height: height), display: true)
        listPanel.invalidateShadow()
    }

    /// Where the left end of the list goes when it opens below `anchor`.
    private static func listLeftEdge(below anchor: NSRect?, width: CGFloat, in area: NSRect) -> CGFloat {
        let left = anchor?.minX ?? area.maxX
        return min(max(left, area.minX + screenMargin), area.maxX - screenMargin - width)
    }

    // MARK: The flyout

    /// The pointer came onto a row. Its flyout shows once it stays there for a moment.
    private func pointerEntered(_ rowID: String, _ flyout: SensorFlyout, rowFrame: NSRect) {
        model.hoveredRowID = rowID
        flyoutTask?.cancel()
        guard flyout != model.flyout else {
            model.setFlyout(flyout, rowID: rowID)
            return
        }
        let delay = model.flyout == nil ? Self.firstFlyoutDelay : Self.nextFlyoutDelay
        flyoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.showFlyout(flyout, rowID: rowID, rowFrame: rowFrame)
        }
    }

    /// It stays as it is: the pointer may be on its way to it. Only another row changes it.
    private func pointerExited(_ rowID: String) {
        guard model.hoveredRowID == rowID else { return }
        model.hoveredRowID = nil
        flyoutTask?.cancel()
    }

    private func showFlyout(_ flyout: SensorFlyout, rowID: String, rowFrame: NSRect) {
        guard isOpen else { return }
        flyoutTask?.cancel()
        flyoutRowFrame = rowFrame
        let isNew = flyoutPanel?.isVisible != true || flyoutPanel?.alphaValue != 1
        model.setFlyout(flyout, rowID: rowID)
        let panel = flyoutPanel ?? makeFlyoutPanel()
        placeFlyout()
        if isNew {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            DispatchQueue.main.async { panel.invalidateShadow() }
            fade(panel, to: 1)
        }
        watchFlyoutPointer()
    }

    private func watchFlyoutPointer() {
        pointerAwaySince = nil
        guard flyoutPointerTimer == nil else { return }
        let timer = Timer(timeInterval: Self.flyoutPointerCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFlyoutPointer() }
        }
        // Also while a slider is being dragged, or a click on one would count from where it started.
        RunLoop.main.add(timer, forMode: .common)
        flyoutPointerTimer = timer
    }

    private func stopWatchingFlyoutPointer() {
        flyoutPointerTimer?.invalidate()
        flyoutPointerTimer = nil
        pointerAwaySince = nil
    }

    /// The flyout stays with the pointer on it, on a row of the list, whose flyout it is or soon will be, or with a button
    /// held down, as when dragging a slider past its end. Anywhere else, it goes after a moment.
    private func checkFlyoutPointer() {
        guard let flyoutPanel, let listPanel else { return }
        let pointer = NSEvent.mouseLocation
        let isOnRow = model.hoveredRowID != nil && NSMouseInRect(pointer, listPanel.frame, false)
        if NSMouseInRect(pointer, flyoutPanel.frame, false) || isOnRow || NSEvent.pressedMouseButtons != 0 {
            pointerAwaySince = nil
            return
        }
        let since = pointerAwaySince ?? .now
        pointerAwaySince = since
        if Date.now.timeIntervalSince(since) >= Self.flyoutLingerTime {
            closeFlyout()
        }
    }

    /// Only the flyout: the list stays open.
    private func closeFlyout() {
        stopWatchingFlyoutPointer()
        model.setFlyout(nil, rowID: nil)
        if let flyoutPanel {
            fade(flyoutPanel, to: 0) { flyoutPanel.orderOut(nil) }
        }
    }

    private func makeFlyoutPanel() -> NSPanel {
        let panel = NonactivatingPanel(title: String(localized: "Sensors"), level: .statusBar)
        let host = NSHostingView(rootView: SensorFlyoutFrame(model: model, onContentChange: { [weak self] in self?.placeFlyout() }))
        // Sized and placed by hand, as what's in it changes while it's open.
        host.sizingOptions = []
        panel.contentView = host
        flyoutPanel = panel
        return panel
    }

    /// Left of the list, which is usually near the right end of the screen, or else right of it, with its middle by the
    /// row's as far as the screen allows, and its arrow pointing at the row.
    private func placeFlyout() {
        guard let flyoutPanel, let listPanel, let screen else { return }
        // A chart takes a while to lay out, and its size is known.
        let content: NSSize
        if case .history = model.flyout {
            content = SensorHistoryView.size
        } else {
            content = NSHostingView(rootView: SensorFlyoutView(model: model, onContentChange: {})).fittingSize
        }
        let area = screen.visibleFrame
        let list = listPanel.frame
        let width = content.width + FlyoutOutline.arrowLength
        let hasRoomOnLeft = list.minX + Self.arrowOverlap - width >= area.minX + Self.screenMargin
        let x = hasRoomOnLeft ? list.minX + Self.arrowOverlap - width : list.maxX - Self.arrowOverlap
        let rowMiddle = flyoutRowFrame.midY
        let top = min(rowMiddle + content.height / 2, list.maxY)
        let y = max(top - content.height, area.minY + Self.screenMargin)
        model.arrow = FlyoutArrow(edge: hasRoomOnLeft ? .trailing : .leading, y: y + content.height - rowMiddle)
        flyoutPanel.setFrame(NSRect(x: x, y: y, width: width, height: content.height), display: true)
        flyoutPanel.invalidateShadow()
    }

    // MARK: Closing on other clicks

    private func installMonitors() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let elsewhere = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDownOutside() }
        }
        // Clicks in CleanBar's own windows, like its settings.
        let inCleanBar = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.listPanel, event.window !== self.flyoutPanel {
                    self.mouseDownOutside()
                }
            }
            return event
        }
        monitors = [elsewhere, inCleanBar].compactMap { $0 }
        HotKeyCenter.shared.registerEscape { [weak self] in self?.close() }

        let workspace = NSWorkspace.shared.notificationCenter
        let closingNotifications: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.didActivateApplicationNotification),
            (workspace, NSWorkspace.activeSpaceDidChangeNotification),
            (.default, NSApplication.didChangeScreenParametersNotification),
        ]
        observers = closingNotifications.map { center, name in
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                // CleanBar coming back to the front isn't another app, as when a click on its icon opens this.
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                MainActor.assumeIsolated {
                    // Nor is it another app coming to the front by itself right after opening: that's the click that opened this,
                    // which sends the front to the app that owns the menu bar, and a quick click ends before CleanBar hears of it.
                    if let self, name == NSWorkspace.didActivateApplicationNotification,
                       Date.now.timeIntervalSince(self.openedDate) < Self.openingClickTime {
                        return
                    }
                    self?.close()
                }
            }
            return (center, observer)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        HotKeyCenter.shared.unregisterEscape()
        for (center, observer) in observers {
            center.removeObserver(observer)
        }
        observers = []
    }

    private func mouseDownOutside() {
        if ignoresClick?(NSEvent.mouseLocation) == true { return }
        close()
    }

    // MARK: The windows

    /// A panel of glass with a view in it. The view is sized by hand, like the floating bar's: inside glass it can't say
    /// how big it wants to be, so that's measured apart.
    private static func makePanel<Content: View>(title: String, rootView: Content) -> (NSPanel, NSHostingView<Content>) {
        // Over other apps' windows, below the menu bar's own menus.
        let panel = NonactivatingPanel(title: title, level: .statusBar)
        let host = NSHostingView(rootView: rootView)
        host.sizingOptions = []
        let glass = NSGlassEffectView()
        glass.cornerRadius = cornerRadius
        glass.contentView = host
        panel.contentView = glass
        return (panel, host)
    }
}

// MARK: The list

private struct SensorListView: View {
    let model: SensorPanelModel
    /// When the list is too long for the screen, the height to scroll in.
    var scrollingHeight: CGFloat?
    var onRowsChange: () -> Void = {}

    private static let titleHeight: CGFloat = 30

    var body: some View {
        let rows = model.rows
        VStack(spacing: 0) {
            Text("SENSORS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: Self.titleHeight)
            if let scrollingHeight {
                ScrollView {
                    list(rows)
                }
                .frame(height: scrollingHeight - Self.titleHeight)
            } else {
                list(rows)
                    .padding(.bottom, 8)
            }
        }
        .frame(minWidth: 240)
        .onChange(of: rows.map(\.id)) { onRowsChange() }
    }

    private func list(_ rows: [SensorRow]) -> some View {
        VStack(spacing: 0) {
            if !model.monitor.fans.isEmpty {
                SensorRowView(
                    model: model,
                    rowID: SensorPanelModel.fanModeRowID,
                    symbol: SensorRow.fanSymbol,
                    tint: SensorRow.fanTint,
                    name: String(localized: "Fans"),
                    value: model.fans.summary,
                    flyout: .fans
                )
                PanelDivider()
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                // A line between the fans and the temperatures, wherever the user put them.
                if index > 0, rows[index - 1].isFan != row.isFan {
                    PanelDivider()
                }
                SensorRowView(
                    model: model,
                    rowID: row.id,
                    symbol: row.symbol,
                    tint: row.tint,
                    name: row.name,
                    value: model.monitor.value(of: row),
                    level: model.monitor.level(of: row),
                    isFan: row.isFan,
                    flyout: .history(row)
                )
            }
        }
    }
}

private struct PanelDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
    }
}

private struct SensorRowView: View {
    let model: SensorPanelModel
    let rowID: String
    /// Its icon, if the user wants icons in the list.
    let symbol: String
    /// Its group's color, the same as in the settings' list.
    let tint: Color
    let name: String
    let value: String
    /// How full its bar is, for rows with one.
    var level: Double?
    var isFan = false
    let flyout: SensorFlyout

    /// Under the pointer, or, while the pointer's elsewhere, the row the flyout goes with, like a menu item with its
    /// submenu open.
    private var isActive: Bool {
        model.hoveredRowID.map { $0 == rowID } ?? (model.flyoutRowID == rowID)
    }

    var body: some View {
        HStack(spacing: 8) {
            if model.settings.showsSensorListIcons {
                SymbolBadge(symbol: symbol, tint: tint, size: 16)
            }
            Text(name)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
            if let level {
                LevelBar(level: level, warns: !isFan)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
                .opacity(isActive ? 1 : 0)
        }
        .padding(.horizontal, 6)
        .overlay {
            PointerArea(label: "\(name), \(value)") { isInside, frame in
                if isInside {
                    model.onHover?(rowID, flyout, frame)
                } else {
                    model.onEndHover?(rowID)
                }
            } onClick: { frame in
                model.onShowNow?(rowID, flyout, frame)
            }
        }
    }
}

/// How full a row's bar is. A temperature's bar goes from green to red as it gets hotter; a fan's is the fans' color.
private struct LevelBar: View {
    let level: Double
    let warns: Bool

    private static let width: CGFloat = 56

    private var tint: Color {
        warns ? Self.heatColor(level) : SensorRow.fanTint
    }

    /// Green while cool, then yellow, orange, and red when close to the most the part should get.
    static func heatColor(_ level: Double) -> Color {
        switch level {
        case ..<0.6: .green
        case ..<0.75: .yellow
        case ..<0.9: .orange
        default: .red
        }
    }

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: Self.width, height: 8)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(Self.width * level, 8), height: 8)
            }
            .animation(.easeInOut(duration: 0.3), value: level)
    }
}

// MARK: The flyout

/// A rounded rectangle with an arrow coming out of one side, like a popover's.
nonisolated struct FlyoutOutline: Shape {
    let arrow: FlyoutArrow

    /// How far the arrow comes out, which is room the flyout needs on that side.
    static let arrowLength: CGFloat = 9
    private static let arrowWidth: CGFloat = 22
    private static let tipRadius: CGFloat = 2.5
    /// The arrow curves into the rectangle's side at its base, so it looks grown out of it.
    private static let baseRadius: CGFloat = 5
    private static let cornerRadius: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        let right = rect.width - Self.arrowLength
        let halfWidth = Self.arrowWidth / 2
        // Clear of the corners, which it can't grow out of.
        let reach = Self.cornerRadius + Self.baseRadius + halfWidth
        let middle = min(max(arrow.y, reach), max(rect.height - reach, reach))

        // Drawn on the right side, and turned around when it goes on the left.
        var path = Path()
        path.move(to: CGPoint(x: Self.cornerRadius, y: 0))
        path.addArc(tangent1End: CGPoint(x: right, y: 0), tangent2End: CGPoint(x: right, y: rect.height), radius: Self.cornerRadius)
        let tip = CGPoint(x: rect.width, y: middle)
        path.addArc(tangent1End: CGPoint(x: right, y: middle - halfWidth), tangent2End: tip, radius: Self.baseRadius)
        path.addArc(tangent1End: tip, tangent2End: CGPoint(x: right, y: middle + halfWidth), radius: Self.tipRadius)
        path.addArc(tangent1End: CGPoint(x: right, y: middle + halfWidth), tangent2End: CGPoint(x: right, y: rect.height), radius: Self.baseRadius)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.height), tangent2End: CGPoint(x: 0, y: rect.height), radius: Self.cornerRadius)
        path.addArc(tangent1End: CGPoint(x: 0, y: rect.height), tangent2End: .zero, radius: Self.cornerRadius)
        path.addArc(tangent1End: .zero, tangent2End: CGPoint(x: Self.cornerRadius, y: 0), radius: Self.cornerRadius)
        path.closeSubpath()
        guard arrow.edge == .leading else { return path }
        return path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.width, ty: 0))
    }
}

/// The flyout's glass, with what it shows inside the rectangle's part of it.
private struct SensorFlyoutFrame: View {
    let model: SensorPanelModel
    let onContentChange: () -> Void

    var body: some View {
        SensorFlyoutView(model: model, onContentChange: onContentChange)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(model.arrow.edge == .leading ? .leading : .trailing, FlyoutOutline.arrowLength)
            .glassEffect(.regular, in: FlyoutOutline(arrow: model.arrow))
    }
}

private struct SensorFlyoutView: View {
    let model: SensorPanelModel
    var onContentChange: () -> Void = {}

    var body: some View {
        switch model.flyout {
        case .history(let row):
            // A new one for each row, as one's samples mean nothing on the chart of another.
            SensorHistoryView(row: row, monitor: model.monitor, settings: model.settings)
                .id(row.id)
        case .fans:
            FanSettingsView(model: model, onContentChange: onContentChange)
        case nil:
            EmptyView()
        }
    }
}

/// How fast the fans turn: left to macOS or the user's rules, one of the user's profiles, or what the sliders say.
private struct FanSettingsView: View {
    let model: SensorPanelModel
    var onContentChange: () -> Void

    private var fans: FanController { model.fans }
    private var fanReadings: [FanReading] { model.monitor.fans }
    private var note: String? {
        if let problem = fans.problem {
            return problem
        }
        if fans.isHeldByAnotherApp {
            return String(localized: "Another app is setting the speed of the fans. Turn that off in that app for CleanBar to take over.")
        }
        if !fans.isHelperInstalled {
            return String(localized: "The first time, macOS asks for your password to install CleanBar's fan helper.")
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("FANS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
            if !model.settings.fanRules.isEmpty {
                FlyoutChoice(title: String(localized: "Automatic"), isChecked: fans.mode == .automatic) {
                    fans.select(.automatic)
                }
            }
            FlyoutChoice(title: String(localized: "System Controlled"), isChecked: fans.isSystemControlled) {
                fans.select(.system)
            }
            PanelDivider()
            ForEach(model.settings.fanProfiles) { profile in
                FlyoutChoice(title: profile.name, isChecked: fans.mode == .profile(profile.id)) {
                    fans.select(.profile(profile.id))
                }
            }
            PanelDivider()
            ForEach(fanReadings) { fan in
                FanSliderRow(fan: fan, percent: fans.percent(ofFan: fan)) { percent in
                    fans.setSpeed(percent, ofFan: fan)
                }
            }
            PanelDivider()
            FlyoutChoice(title: String(localized: "Fan Settings…")) {
                model.onEditProfiles?()
            }
            if let note {
                PanelDivider()
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 2)
            }
        }
        .padding(.bottom, 8)
        .frame(width: 280)
        .onChange(of: note) { onContentChange() }
    }
}

private struct FlyoutChoice: View {
    let title: String
    var isChecked = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack {
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 16)
            if isChecked {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
                .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, 6)
        .overlay {
            PointerArea(label: title) { isInside, _ in
                isHovered = isInside
            } onClick: { _ in
                action()
            }
        }
    }
}

/// A fan's name, its speed in rpm and percent, and a slider. While the slider is dragged, it shows the speed it'll go to.
/// That's set when the slider is let go.
private struct FanSliderRow: View {
    let fan: FanReading
    let percent: Double
    let onChange: (Double) -> Void
    @State private var draggedPercent: Double?

    var body: some View {
        let shown = draggedPercent ?? fan.percent
        VStack(spacing: 2) {
            HStack {
                Image(systemName: SensorRow.fanSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SensorRow.fanTint)
                    .accessibilityHidden(true)
                Text(fan.name)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Text(verbatim: "\(Int(draggedPercent.map(fan.rpm(forPercent:)) ?? fan.rpm)) (\(Int(shown.rounded()))%)")
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            PanelSlider(
                value: draggedPercent ?? percent,
                range: 0...100,
                onDrag: { draggedPercent = $0 },
                onRelease: { percent in
                    draggedPercent = nil
                    onChange(percent)
                }
            )
            .frame(height: 20)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
    }
}

// MARK: The fan slider

/// A slider for panels that are never key: a native one, which takes first clicks.
struct PanelSlider: NSViewRepresentable {
    var value: Double
    var range: ClosedRange<Double>
    var onDrag: (Double) -> Void
    var onRelease: (Double) -> Void

    func makeNSView(context: Context) -> PanelSliderView {
        let slider = PanelSliderView(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: context.coordinator, action: #selector(Coordinator.changed))
        slider.isContinuous = true
        slider.controlSize = .small
        return slider
    }

    func updateNSView(_ slider: PanelSliderView, context: Context) {
        context.coordinator.parent = self
        // Not while it's being dragged: it has the latest value, and this one's a moment behind.
        if NSEvent.pressedMouseButtons == 0 {
            slider.doubleValue = value
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject {
        var parent: PanelSlider

        init(parent: PanelSlider) {
            self.parent = parent
        }

        @objc func changed(_ slider: NSSlider) {
            if NSApp.currentEvent?.type == .leftMouseUp {
                parent.onRelease(slider.doubleValue.rounded())
            } else {
                parent.onDrag(slider.doubleValue.rounded())
            }
        }
    }
}

final class PanelSliderView: NSSlider {
    override class var cellClass: AnyClass? {
        get { BlueTrackSliderCell.self }
        set {}
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The panel is never the key window, and AppKit draws a slider's fill gray there, whatever its `trackFillColor`.
/// This draws the track itself, filled with the accent color (blue by default) up to the knob, like a slider in a key window.
final class BlueTrackSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let height: CGFloat = 4
        let track = NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: track, xRadius: height / 2, yRadius: height / 2).fill()

        let knob = knobRect(flipped: flipped)
        var filled = track
        filled.size.width = max(knob.midX - track.minX, 0)
        guard filled.width > 0 else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: height / 2, yRadius: height / 2).fill()
    }
}
