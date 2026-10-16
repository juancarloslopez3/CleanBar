import AppKit
import SwiftUI

/// Helps allow a permission: a panel below System Settings' window with CleanBar's icon, to drag into the permission's
/// list there, as if from Finder. System Settings asks for Touch ID or the password, then adds CleanBar to the list and
/// turns it on, which is quicker than looking for CleanBar with the list's + button.
///
/// The panel follows System Settings' window, found in the public window list (no permission needed), and shows while
/// System Settings is the app in front. It rises into place just below the window, or as low as the Dock lets it, over
/// the window's bottom. It goes once the permission is allowed (after saying so for a moment, and CleanBar's settings
/// come back), when System Settings' window closes, or with its close button. If System Settings' window doesn't show up,
/// it shows at the bottom of the screen instead.
///
/// Like the floating bar, it never takes the keyboard or makes CleanBar the active app, so System Settings stays in front
/// with its list.
final class PermissionGuide {
    static let shared = PermissionGuide()

    /// Called once the panel has gone with the permission allowed. Screen Recording only reads as allowed once CleanBar
    /// has restarted (macOS offers to), so it's for Accessibility.
    var onAllowed: (() -> Void)?

    /// The permission the panel helps with, while it's open.
    private var permission: Permission?
    private var phase = Phase.guiding
    /// Set while CleanBar asks macOS whether the permission is allowed.
    private var isCheckingPermission = false
    private var panel: NSPanel?
    private var hostingView: NSHostingView<PermissionGuideView>?
    /// Measures the panel's content. The view on screen can't: the glass it's in sets its size.
    private let measuringView = NSHostingView(rootView: PermissionGuideView())
    private var size = NSSize.zero
    private lazy var ticker = FrameTicker { [weak self] now, _ in self?.step(now: now) }

    /// When the panel was asked for, and when it last moved.
    private var startTime: CFTimeInterval?
    private var lastStep: CFTimeInterval?
    /// System Settings' window, once found, and when it was last on screen.
    private var windowID: CGWindowID?
    private var lastSearch: CFTimeInterval = 0
    private var lastSeen: CFTimeInterval?
    private var lastCheck: CFTimeInterval = 0
    /// Where the panel is once it has risen into place, whether that's below System Settings' window (or else at the
    /// bottom of the screen), and until when it eases over to a new place.
    private var origin: NSPoint?
    private var isBelowWindow = false
    private var easesUntil: CFTimeInterval = 0
    /// How far the panel is on its way in: 0 while it's hidden, 1 once it has risen into place and faded in.
    private var presence: CGFloat = 0
    private var isDragging = false

    private enum Phase: Equatable {
        /// Showing CleanBar's icon to drag.
        case guiding
        /// Saying the permission is allowed, since a moment.
        case allowed(since: CFTimeInterval)
        /// Going away.
        case closing
    }

    /// Space between System Settings' window and the panel.
    private static let gap: CGFloat = 12
    private static let screenMargin: CGFloat = 8
    /// How far below its place the panel starts as it rises in, and sinks to as it goes.
    private static let rise: CGFloat = 14
    private static let cornerRadius: CGFloat = 24
    /// Seconds to wait for System Settings' window before showing at the bottom of the screen.
    private static let fallbackDelay: CFTimeInterval = 2
    /// Seconds the panel says the permission is allowed before it goes.
    private static let allowedDuration: CFTimeInterval = 1.5
    private static let settingsBundleID = "com.apple.systempreferences"

    private static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Shows the panel for `permission` below System Settings' window, once that's on screen: it's just been asked to
    /// open the permission's list. While the panel is open for another permission, it switches to this one.
    func show(for permission: Permission) {
        self.permission = permission
        phase = .guiding
        // System Settings may only be opening now.
        startTime = nil
        lastSeen = nil
        lastCheck = 0
        showContent()
        ticker.start(on: NSScreen.main)
    }

    /// Closes the panel: it sinks away as it fades out.
    func close() {
        guard permission != nil else { return }
        phase = .closing
    }

    // MARK: Following System Settings' window

    /// Places the panel as the screen refreshes: below System Settings' window, rising in or sinking away as it shows or
    /// hides.
    private func step(now: CFTimeInterval) {
        guard let permission, let panel else {
            ticker.stop()
            return
        }
        // While the panel is hidden, a few looks a second are enough. As it starts to show, it moves one screen refresh's
        // worth, however long it was hidden, so it rises in from the start.
        if presence == 0, let lastStep, now - lastStep < 0.1 { return }
        let elapsed = presence == 0 ? 1.0 / 60 : min(now - (lastStep ?? now), 0.1)
        lastStep = now
        let startTime = self.startTime ?? now
        self.startTime = startTime

        checkPermission(permission, now: now)

        let window = settingsWindowFrame(now: now)
        if window != nil {
            lastSeen = now
        } else if let lastSeen, now - lastSeen > 1, !isDragging {
            // System Settings' window closed, or it was minimized, hidden or left on another Space.
            phase = .closing
        }
        var target: NSPoint?
        if let window {
            target = place(below: window)
        } else if lastSeen == nil, now - startTime > Self.fallbackDelay {
            target = placeAtBottomOfScreen()
        }
        let isBelowWindow = window != nil
        let isSettingsInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.settingsBundleID
        let shows = isDragging || phase != .closing && target != nil && (isSettingsInFront || !isBelowWindow)

        if let target {
            // It eases over from the bottom of the screen to below the window, and follows the window exactly.
            if presence > 0, isBelowWindow != self.isBelowWindow {
                easesUntil = now + 0.5
            }
            if let origin, now < easesUntil {
                self.origin = origin.moved(toward: target, elapsed: elapsed, timeConstant: 0.08)
            } else {
                origin = target
            }
            self.isBelowWindow = isBelowWindow
        }
        presence = presence.moved(toward: shows ? 1 : 0, elapsed: elapsed, timeConstant: shows ? 0.08 : 0.05, within: 0.01)

        if let origin {
            let sink = Self.reducesMotion ? 0 : (1 - presence) * Self.rise
            // Windows go on whole points.
            let frame = NSRect(x: origin.x.rounded(), y: (origin.y - sink).rounded(), width: size.width, height: size.height)
            if panel.frame != frame {
                panel.setFrame(frame, display: true)
                // The shadow follows what's drawn.
                panel.invalidateShadow()
            }
            if panel.alphaValue != presence {
                panel.alphaValue = presence
            }
        }
        if presence > 0, origin != nil {
            if !panel.isVisible {
                panel.orderFrontRegardless()
                // The glass settles a moment after it first shows.
                DispatchQueue.main.async { panel.invalidateShadow() }
            }
        } else {
            if panel.isVisible {
                panel.orderOut(nil)
            }
            if phase == .closing {
                finish()
            }
        }
    }

    private func checkPermission(_ permission: Permission, now: CFTimeInterval) {
        switch phase {
        case .guiding:
            // Asking about Screen Recording takes about 15 ms, and it only reads as allowed once CleanBar has restarted.
            // It's asked off the main thread, so the panel keeps up with System Settings' window meanwhile.
            let interval: CFTimeInterval = permission == .accessibility ? 0.5 : 2
            guard now - lastCheck >= interval, !isCheckingPermission else { return }
            lastCheck = now
            isCheckingPermission = true
            Task {
                let isGranted = await Task.detached { permission.isGranted }.value
                isCheckingPermission = false
                // Not when the panel closed or switched to another permission meanwhile.
                guard isGranted, self.permission == permission, phase == .guiding else { return }
                phase = .allowed(since: CACurrentMediaTime())
                showContent()
            }
        case .allowed(let since):
            if now - since >= Self.allowedDuration, !isDragging {
                phase = .closing
            }
        case .closing:
            break
        }
    }

    /// Once the panel has gone. CleanBar's settings come back if the permission is allowed now.
    private func finish() {
        ticker.stop()
        panel?.orderOut(nil)
        let permission = self.permission
        self.permission = nil
        phase = .guiding
        origin = nil
        presence = 0
        lastStep = nil
        windowID = nil
        isDragging = false
        if permission?.isGranted == true {
            onAllowed?()
        }
    }

    /// Where System Settings' window is on screen now, in AppKit's screen coordinates, or nil while it has none there.
    private func settingsWindowFrame(now: CFTimeInterval) -> NSRect? {
        if let windowID, let frame = WindowInfo.frame(ofWindow: windowID) {
            return Self.appKitFrame(frame)
        }
        // Looking through all the windows takes longer, so only a few times a second.
        guard now - lastSearch >= 0.2 else { return nil }
        lastSearch = now
        guard let settings = NSRunningApplication.runningApplications(withBundleIdentifier: Self.settingsBundleID).first,
              let window = WindowInfo.largestWindow(of: settings.processIdentifier)
        else {
            windowID = nil
            return nil
        }
        windowID = window.id
        return Self.appKitFrame(window.frame)
    }

    /// Centered below System Settings' window. Where the Dock or the screen's edge leaves no room below it, the panel goes
    /// as low as it can, over the window's bottom.
    private func place(below window: NSRect) -> NSPoint {
        let screen = NSScreen.containing(NSPoint(x: window.midX, y: window.midY)) ?? NSScreen.main
        let area = screen?.visibleFrame ?? window
        let x = min(max(window.midX - size.width / 2, area.minX + Self.screenMargin), area.maxX - Self.screenMargin - size.width)
        let y = min(max(window.minY - Self.gap - size.height, area.minY + Self.screenMargin), area.maxY - Self.screenMargin - size.height)
        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    private func placeAtBottomOfScreen() -> NSPoint? {
        guard let area = NSScreen.main?.visibleFrame else { return nil }
        return NSPoint(x: (area.midX - size.width / 2).rounded(), y: (area.minY + 3 * Self.screenMargin).rounded())
    }

    /// A frame from the window list (origin at the top left of the primary screen) in AppKit's screen coordinates (origin
    /// at the bottom left).
    private static func appKitFrame(_ frame: CGRect) -> NSRect {
        NSRect(x: frame.minX, y: NSScreen.primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    // MARK: The window

    /// Shows what the panel says now, and sizes it to fit.
    private func showContent() {
        guard let permission else { return }
        var view = PermissionGuideView(permission: permission, isAllowed: phase != .guiding)
        view.onClose = { [weak self] in self?.close() }
        view.onDragging = { [weak self] isDragging in self?.isDragging = isDragging }
        measuringView.rootView = view
        size = measuringView.fittingSize
        if panel == nil {
            makePanel()
        }
        hostingView?.rootView = view
    }

    private func makePanel() {
        let panel = NonactivatingPanel(title: String(localized: "Allow CleanBar"), level: .floating)
        let hostingView = NSHostingView(rootView: PermissionGuideView())
        // The panel is sized by hand, to what the measuring view says, and the view fills it.
        hostingView.sizingOptions = []
        let glass = NSGlassEffectView()
        glass.cornerRadius = Self.cornerRadius
        glass.contentView = hostingView
        panel.contentView = glass
        self.panel = panel
        self.hostingView = hostingView
    }
}

private extension Permission {
    /// What dropping CleanBar into the list does.
    var dropHint: String {
        switch self {
        case .accessibility:
            String(localized: "Dropping it there allows Accessibility. If CleanBar is already in the list, turn it on instead.")
        case .screenRecording:
            String(localized: "Dropping it there allows Screen Recording, and macOS then asks to reopen CleanBar. If CleanBar is already in the list, turn it on instead.")
        }
    }

    /// What CleanBar can do once it's allowed.
    var allowedHint: String {
        switch self {
        case .accessibility: String(localized: "CleanBar can read and move your menu bar icons now.")
        case .screenRecording: String(localized: "CleanBar can take pictures of your menu bar icons now.")
        }
    }
}

private extension CGFloat {
    /// Part of the way to `target` after `elapsed` seconds, slowing down as it gets there: about two thirds of the way
    /// after `timeConstant` seconds, and there once it's `within` that of it.
    func moved(
        toward target: CGFloat, elapsed: CFTimeInterval, timeConstant: CFTimeInterval, within: CGFloat = 0.001
    ) -> CGFloat {
        let value = target + (self - target) * CGFloat(exp(-elapsed / timeConstant))
        return abs(value - target) < within ? target : value
    }
}

private extension NSPoint {
    func moved(toward target: NSPoint, elapsed: CFTimeInterval, timeConstant: CFTimeInterval) -> NSPoint {
        NSPoint(
            x: x.moved(toward: target.x, elapsed: elapsed, timeConstant: timeConstant),
            y: y.moved(toward: target.y, elapsed: elapsed, timeConstant: timeConstant)
        )
    }
}

/// What the panel shows: CleanBar's icon to drag and what to do with it, or that the permission is allowed now.
private struct PermissionGuideView: View {
    var permission = Permission.accessibility
    var isAllowed = false
    var onClose: () -> Void = {}
    var onDragging: (Bool) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 14) {
            DraggableAppIcon(isAllowed: isAllowed, onDragging: onDragging)
            VStack(alignment: .leading, spacing: 3) {
                if isAllowed {
                    Text("\(permission.title) is allowed")
                        .font(.headline)
                    Text(permission.allowedHint)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 5) {
                        Text("Drag CleanBar into the list above")
                            .font(.headline)
                        RisingArrow()
                    }
                    Text(permission.dropHint)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.subheadline)
            .frame(width: 272, alignment: .leading)
            CloseButton(action: onClose)
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 12))
        .fixedSize()
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isAllowed)
    }
}

/// CleanBar's icon and name, the way Finder shows an app, to drag into the list. It lifts under the pointer, and stays
/// dimmed where it was while it's dragged, as in Finder. Once the permission is allowed, it gets a checkmark.
private struct DraggableAppIcon: View {
    let isAllowed: Bool
    let onDragging: (Bool) -> Void
    @State private var isHovered = false
    @State private var isDragging = false

    private static let size: CGFloat = 48

    var body: some View {
        VStack(spacing: 2) {
            Image(nsImage: AppDragSourceView.appIcon)
                .resizable()
                .frame(width: Self.size, height: Self.size)
                .opacity(isDragging ? 0.35 : 1)
                .scaleEffect(isHovered && !isDragging && !isAllowed ? 1.08 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isHovered)
                .overlay(alignment: .bottomTrailing) {
                    if isAllowed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                            .offset(x: 3, y: 3)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay {
                    if !isAllowed {
                        AppDragSource(isHovered: $isHovered, isDragging: $isDragging, onDragging: onDragging)
                    }
                }
            Text("CleanBar")
                .font(.caption)
                .accessibilityHidden(true)
        }
    }
}

/// Points up at the list, rising a little and back, unless Reduce Motion is on.
private struct RisingArrow: View {
    @State private var isUp = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "arrow.up")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.tint)
            .offset(y: isUp ? -3 : 0)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    isUp = true
                }
            }
    }
}

/// Closes the panel: an × in a circle, shaded under the pointer like the floating bar's buttons.
private struct CloseButton: View {
    let action: () -> Void
    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .background {
                Circle()
                    .fill(isPressed ? .secondary : isHovered ? .tertiary : .quaternary)
                    .animation(.easeOut(duration: 0.12), value: isHovered)
            }
            .overlay {
                ClickArea(name: String(localized: "Close"), isHovered: $isHovered, isPressed: $isPressed) { click in
                    if !click.isRightClick {
                        action()
                    }
                }
            }
    }
}

/// Makes CleanBar's icon draggable, as CleanBar's app bundle, the way Finder drags an app: that's what System Settings'
/// lists take. SwiftUI's own dragging offers the app as a file promise instead, which they turn down.
private struct AppDragSource: NSViewRepresentable {
    @Binding var isHovered: Bool
    @Binding var isDragging: Bool
    /// Told straight from the drag's start and end, which always come in pairs, so the panel can't be kept waiting.
    let onDragging: (Bool) -> Void

    func makeNSView(context: Context) -> AppDragSourceView {
        AppDragSourceView()
    }

    func updateNSView(_ view: AppDragSourceView, context: Context) {
        view.onHover = { isHovered = $0 }
        view.onDrag = {
            isDragging = $0
            onDragging($0)
        }
    }
}

private final class AppDragSourceView: NSView, NSDraggingSource {
    /// CleanBar's icon as Finder shows it, which is also how System Settings shows it in its list.
    static let appIcon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

    var onHover: (Bool) -> Void = { _ in }
    var onDrag: (Bool) -> Void = { _ in }
    private var pressLocation: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("CleanBar")
        setAccessibilityHelp(String(localized: "Drag into the list in System Settings to allow CleanBar."))
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    // CleanBar isn't the active app while System Settings is in front, so the press that starts a drag is a first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func mouseDown(with event: NSEvent) {
        pressLocation = event.locationInWindow
    }

    override func mouseUp(with event: NSEvent) {
        pressLocation = nil
    }

    /// As in Finder, the drag starts once the pointer has moved a little with the button down.
    override func mouseDragged(with event: NSEvent) {
        guard let start = pressLocation else { return }
        let location = event.locationInWindow
        guard hypot(location.x - start.x, location.y - start.y) >= 3 else { return }
        pressLocation = nil
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: Self.appIcon)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // System Settings' lists take a copy (a SwiftUI drop of a file URL). Nothing else is offered, so a drop on Finder
        // can't move CleanBar out of the Applications folder, nor one on the Trash delete it, which the Trash does with a
        // "generic" drop.
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        onHover(false)
        onDrag(true)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDrag(false)
    }
}
