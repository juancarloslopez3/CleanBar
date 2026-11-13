import AppKit
import SwiftUI

/// Which sensors the list shows, and in what order.
struct SensorListSection: View {
    @Bindable var settings: AppSettings
    let monitor: SensorMonitor

    /// Half a row short of a whole number of rows, which shows there's more to scroll to.
    private static let maxHeight = SensorOrderTable.rowHeight * 10.5

    var body: some View {
        let rows = monitor.rows(order: settings.sensorOrder)
        Section {
            if rows.isEmpty {
                Text("CleanBar can't read this Mac's sensors.")
                    .foregroundStyle(.secondary)
            } else {
                Toggle("Show icons in the menu bar list", isOn: $settings.showsSensorListIcons)
                SensorOrderTable(rows: rows, settings: settings, monitor: monitor)
                    .fillingFormRow(height: min(CGFloat(rows.count) * SensorOrderTable.rowHeight, Self.maxHeight))
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text("Sensors List")
                if !rows.isEmpty {
                    Spacer()
                    Text("\(rows.count { !settings.hiddenSensors.contains($0.id) }) of \(rows.count) shown")
                        .font(.subheadline.weight(.regular))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } footer: {
            if !rows.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text("Drag sensors to put them in the order you like, and turn off those you don't want to see.")
                    Spacer()
                    // Always there: without it the text wraps differently, and all that's below jumps when turning a sensor off.
                    Button("Restore Defaults") {
                        settings.sensorOrder = []
                        settings.hiddenSensors = []
                    }
                    .controlSize(.small)
                    .disabled(settings.hiddenSensors.isEmpty && rows == monitor.rows(order: []))
                }
            }
        }
    }
}

/// The sensors and fans, to drag into order. One of AppKit's tables rather than a SwiftUI `List`: inside a `Form`, a `List`
/// doesn't scroll, but passes the wheel on to the form (seen on macOS 27).
private struct SensorOrderTable: NSViewRepresentable {
    let rows: [SensorRow]
    let settings: AppSettings
    let monitor: SensorMonitor

    static let rowHeight: CGFloat = 30

    func makeCoordinator() -> Coordinator {
        Coordinator(rows: rows, settings: settings, monitor: monitor)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let table = ReorderingTableView()
        table.addTableColumn(NSTableColumn(identifier: Coordinator.columnID))
        table.headerView = nil
        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = coordinator
        table.delegate = coordinator
        table.rowContent = { [weak coordinator] row in coordinator?.content(ofRow: row) }
        table.onMove = { [weak coordinator] from, to in coordinator?.moveRow(from: from, to: to) }
        table.onDrop = { [weak coordinator] in coordinator?.saveOrder() }
        table.onToggle = { [weak coordinator] row in coordinator?.toggleRow(row) }
        let menu = NSMenu()
        menu.delegate = coordinator
        table.menu = menu
        coordinator.table = table
        let scrollView = NSScrollView.holding(table, in: PageChainingScrollView())
        // Stops dead at its ends, for the page to take over from there.
        scrollView.verticalScrollElasticity = .none
        // Clear of the switches at the right end of the rows.
        scrollView.verticalScroller = RowMarginScroller()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.show(rows)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        static let columnID = NSUserInterfaceItemIdentifier("sensor")
        private static let slideDuration = 0.2

        weak var table: ReorderingTableView?
        /// In the order they're showing, which is ahead of the settings while a row is being dragged.
        private var rows: [SensorRow]
        private let settings: AppSettings
        private let monitor: SensorMonitor

        init(rows: [SensorRow], settings: AppSettings, monitor: SensorMonitor) {
            self.rows = rows
            self.settings = settings
            self.monitor = monitor
        }

        /// Goes by what the settings say now. Rows that only changed places slide there.
        func show(_ newRows: [SensorRow]) {
            guard newRows != rows, let table, !table.isDraggingRow else { return }
            var order = rows.map(\.id)
            rows = newRows
            guard order.sorted() == newRows.map(\.id).sorted() else {
                table.reloadData()
                return
            }
            slide {
                table.beginUpdates()
                for (index, row) in newRows.enumerated() where order[index] != row.id {
                    guard let from = order.firstIndex(of: row.id) else { continue }
                    order.insert(order.remove(at: from), at: index)
                    table.moveRow(at: from, to: index)
                }
                table.endUpdates()
            }
        }

        func content(ofRow row: Int) -> SensorSettingRow {
            SensorSettingRow(row: rows[row], isLast: row == rows.count - 1, settings: settings, monitor: monitor)
        }

        /// A row being dragged went past another.
        func moveRow(from: Int, to: Int) {
            rows.insert(rows.remove(at: from), at: to)
            slide { table?.moveRow(at: from, to: to) }
        }

        func saveOrder() {
            settings.sensorOrder = rows.map(\.id)
        }

        func toggleRow(_ row: Int) {
            let id = rows[row].id
            // Animated, for the knob to slide across as it does when it's clicked itself.
            withAnimation(.easeInOut(duration: Self.slideDuration)) {
                if settings.hiddenSensors.remove(id) == nil {
                    settings.hiddenSensors.insert(id)
                }
            }
        }

        private func slide(_ moves: () -> Void) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.slideDuration
                moves()
            }
            // The last row has no line below it.
            table?.enumerateAvailableRowViews { rowView, row in
                if let cell = rowView.view(atColumn: 0) as? NSHostingView<SensorSettingRow>,
                   cell.rootView.isLast != (row == rows.count - 1) {
                    cell.rootView = content(ofRow: row)
                }
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let content = content(ofRow: row)
            // One view for each sensor: in a view that had shown another one, the switch would be seen flipping as the
            // list scrolls.
            let identifier = NSUserInterfaceItemIdentifier(content.row.id)
            if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSHostingView<SensorSettingRow> {
                cell.rootView = content
                return cell
            }
            let cell = NSHostingView(rootView: content)
            cell.identifier = identifier
            cell.sizingOptions = []
            return cell
        }

        // MARK: Right-clicking

        /// It's a long way to drag in a long list.
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, rows.indices.contains(table.clickedRow) else { return }
            let row = rows[table.clickedRow]
            for (title, action, isAvailable) in [
                (String(localized: "Move to Top"), #selector(moveToTop(_:)), row.id != rows.first?.id),
                (String(localized: "Move to Bottom"), #selector(moveToBottom(_:)), row.id != rows.last?.id),
            ] {
                let item = menu.addItem(withTitle: title, action: isAvailable ? action : nil, keyEquivalent: "")
                item.target = self
                item.representedObject = row.id
            }
        }

        @objc private func moveToTop(_ item: NSMenuItem) {
            putRow(of: item, at: 0)
        }

        @objc private func moveToBottom(_ item: NSMenuItem) {
            putRow(of: item, at: rows.count - 1)
        }

        private func putRow(of item: NSMenuItem, at index: Int) {
            var order = rows.map(\.id)
            guard let id = item.representedObject as? String, let from = order.firstIndex(of: id) else { return }
            order.insert(order.remove(at: from), at: index)
            settings.sensorOrder = order
        }
    }
}

/// A table whose rows are dragged into order right there in the list: the row comes up under the pointer, the others slide out
/// of its way, and near the ends of the list it scrolls at a pace that's easy to follow.
///
/// AppKit's own row dragging, a drag session, scrolled the list too fast to stop where you wanted. That happens in a private
/// method (`_autoscrollForDraggingInfo:timeDelta:`), so there's no way to slow it down short of doing without it.
private final class ReorderingTableView: NSTableView {
    /// What a row shows, for the copy of it that follows the pointer.
    var rowContent: ((Int) -> SensorSettingRow?)?
    /// A row being dragged went past others, and has to move from one place to another now.
    var onMove: ((_ from: Int, _ to: Int) -> Void)?
    /// A row was dropped in another place than it came from.
    var onDrop: (() -> Void)?
    /// A row's switch was clicked.
    var onToggle: ((Int) -> Void)?

    var isDraggingRow: Bool { drag != nil }

    private struct Drag {
        let lifted: NSView
        let liftState: RowLiftState
        let link: CADisplayLink
        let startRow: Int
        /// Where the row is now, which is the place it'd be dropped in.
        var row: Int
        /// How far down the row it was picked up, which stays the same.
        let grabOffset: CGFloat
        /// Where the button went down, and where the pointer is now, in the window.
        let press: NSPoint
        var pointer: NSPoint
        /// How far the list has scrolled, with the fractions the list itself rounds away, or it'd never move at slow speeds.
        var scrollOffset: CGFloat
        var lastStep: CFTimeInterval?
        /// A row picked up close to an end of the list doesn't set it scrolling until the pointer goes on towards that end.
        var canScrollUp: Bool
        var canScrollDown: Bool
    }

    private var drag: Drag?
    /// The copy that's on its way to the row's place, once dropped.
    private var landing: NSView?

    /// How far the pointer has to move for a press to become a drag, so a click doesn't move anything.
    private static let dragThreshold: CGFloat = 4
    /// Room around the copy of the row for its shadow.
    private static let liftMargin: CGFloat = 12
    private static let landDuration = 0.2
    /// How close to the ends of what's showing of the list the pointer has to be for it to scroll.
    private static let scrollZone: CGFloat = 36
    /// In points a second. A row is 30, so that's one row a second where the pointer enters the zone, and two or three at the
    /// end of the list. Only with the pointer well past the end does it get up to the fastest.
    private static let slowestScroll: CGFloat = 30
    private static let fastestScroll: CGFloat = 200
    private static let moveTowardsEnd: CGFloat = 8
    /// How far from the row's right end a click counts as being on its switch: the row's margin, the switch, and a little more.
    private static let switchAreaWidth: CGFloat = 52

    /// Whether a point in the table is where a click flips its row's switch: the right end of the row, full height, which is
    /// more than the switch itself.
    private func isInSwitchArea(_ point: NSPoint) -> Bool {
        row(at: point) >= 0 && point.x >= bounds.maxX - Self.switchAreaWidth
    }

    /// The list takes the clicks on its switches instead of leaving them to the switches themselves, as a first click on one
    /// can do nothing (macOS 27). Presses on the rows have always got here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isInSwitchArea(convert(point, from: superview)) ? self : super.hitTest(point)
    }

    /// As with the switches themselves: one click is enough while another app is in front.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        event.map { isInSwitchArea(convert($0.locationInWindow, from: nil)) } ?? false
    }

    /// When the button comes up still on the row's switch, changes what the switch shows rather than clicking it: with real
    /// clicks, `performClick` did nothing the first time on each switch, and only worked from the second on.
    private func trackSwitchClick(inRow pressedRow: Int, window: NSWindow) {
        window.trackEvents(matching: [.leftMouseUp], timeout: NSEvent.foreverDuration, mode: .eventTracking) { [self] event, stop in
            guard let event else { return }
            let point = convert(event.locationInWindow, from: nil)
            if row(at: point) == pressedRow, isInSwitchArea(point) {
                onToggle?(pressedRow)
            }
            stop.pointee = true
        }
    }

    /// Comes here through the row's hosting view. The row gets dragged if the pointer moves before the button comes up.
    override func mouseDown(with event: NSEvent) {
        let press = event.locationInWindow
        let pressedRow = row(at: convert(press, from: nil))
        guard pressedRow >= 0, !event.modifierFlags.contains(.control), let window else {
            super.mouseDown(with: event)
            return
        }
        finishLanding()
        // As clicking anywhere in a table does, which ends typing in a field.
        window.makeFirstResponder(self)
        if isInSwitchArea(convert(press, from: nil)) {
            trackSwitchClick(inRow: pressedRow, window: window)
            return
        }
        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp, .keyDown, .scrollWheel],
            timeout: NSEvent.foreverDuration,
            mode: .eventTracking
        ) { [self] event, stop in
            guard let event else { return }
            switch event.type {
            case .leftMouseDragged:
                let location = event.locationInWindow
                if drag == nil, hypot(location.x - press.x, location.y - press.y) >= Self.dragThreshold {
                    beginDrag(ofRow: pressedRow, press: press)
                }
                pointerMoved(to: location)
            case .leftMouseUp:
                endDrag(isCancelled: false)
                stop.pointee = true
            case .keyDown where event.keyCode == 53:
                // Esc, as with any other drag.
                endDrag(isCancelled: true)
                stop.pointee = true
            default:
                // What's not asked for would wait for the drag to end, and only then scroll or type.
                break
            }
        }
    }

    private func beginDrag(ofRow row: Int, press: NSPoint) {
        guard let content = rowContent?(row) else { return }
        let liftState = RowLiftState()
        let lifted = NSHostingView(rootView: LiftedSensorRow(content: content, state: liftState))
        lifted.sizingOptions = []
        lifted.wantsLayer = true
        // Above the row views the list adds as it scrolls.
        lifted.layer?.zPosition = 1
        let frame = rect(ofRow: row)
        lifted.frame = frame.insetBy(dx: 0, dy: -Self.liftMargin)
        addSubview(lifted)
        // Leaves a gap where it'll go.
        rowView(atRow: row, makeIfNecessary: false)?.alphaValue = 0
        let link = displayLink(target: self, selector: #selector(stepDrag(_:)))
        link.add(to: .main, forMode: .common)
        drag = Drag(
            lifted: lifted,
            liftState: liftState,
            link: link,
            startRow: row,
            row: row,
            grabOffset: convert(press, from: nil).y - frame.minY,
            press: press,
            pointer: press,
            scrollOffset: enclosingScrollView?.contentView.bounds.minY ?? 0,
            canScrollUp: false,
            canScrollDown: false
        )
        // Once it's been drawn without its background, or that wouldn't animate.
        lifted.layoutSubtreeIfNeeded()
        withAnimation(.easeOut(duration: 0.12)) {
            liftState.isLifted = true
        }
    }

    private func pointerMoved(to location: NSPoint) {
        guard var drag else { return }
        drag.pointer = location
        let y = convert(location, from: nil).y
        let area = draggingArea
        // The window's y goes up, the table's down.
        if y >= area.minY + Self.scrollZone || location.y - drag.press.y >= Self.moveTowardsEnd {
            drag.canScrollUp = true
        }
        if y <= area.maxY - Self.scrollZone || drag.press.y - location.y >= Self.moveTowardsEnd {
            drag.canScrollDown = true
        }
        self.drag = drag
        placeLiftedRow()
    }

    /// Under the pointer, within what's showing of the list, and the row goes to the place the copy is over.
    private func placeLiftedRow() {
        guard var drag else { return }
        let area = draggingArea
        let wanted = convert(drag.pointer, from: nil).y - drag.grabOffset
        let top = min(max(wanted, area.minY), max(area.maxY - rowHeight, area.minY))
        drag.lifted.setFrameOrigin(NSPoint(x: 0, y: top - Self.liftMargin))
        let place = min(max(Int((top + rowHeight / 2) / rowHeight), 0), numberOfRows - 1)
        if place != drag.row {
            onMove?(drag.row, place)
            drag.row = place
        }
        self.drag = drag
    }

    /// The part of the list that can be seen, which the page around it may be hiding some of.
    private var draggingArea: NSRect {
        guard let window else { return visibleRect }
        let area = visibleRect.intersection(convert(window.contentLayoutRect, from: nil))
        return area.isEmpty ? visibleRect : area
    }

    /// Scrolls the list a little every frame while the pointer's close to its ends or past them.
    @objc private func stepDrag(_ link: CADisplayLink) {
        guard var drag, let scrollView = enclosingScrollView else { return }
        let elapsed = min(link.timestamp - (drag.lastStep ?? link.timestamp), 0.05)
        drag.lastStep = link.timestamp
        let clipView = scrollView.contentView
        let speed = scrollSpeed(for: drag)
        guard speed != 0 else {
            drag.scrollOffset = clipView.bounds.minY
            self.drag = drag
            return
        }
        let limit = max(frame.height - clipView.bounds.height, 0)
        drag.scrollOffset = min(max(drag.scrollOffset + speed * elapsed, 0), limit)
        self.drag = drag
        let scale = window?.backingScaleFactor ?? 2
        let offset = (drag.scrollOffset * scale).rounded() / scale
        if offset != clipView.bounds.minY {
            clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: offset))
            scrollView.reflectScrolledClipView(clipView)
            placeLiftedRow()
        }
    }

    /// In points a second, negative for up.
    private func scrollSpeed(for drag: Drag) -> CGFloat {
        let y = convert(drag.pointer, from: nil).y
        let area = draggingArea
        func speed(atDepth depth: CGFloat) -> CGFloat {
            // Slowly for a long way, so it's easy to keep to a speed: the depth is twice the zone at the fastest.
            let fraction = min(depth / (Self.scrollZone * 2), 1)
            return Self.slowestScroll + (Self.fastestScroll - Self.slowestScroll) * fraction * fraction
        }
        let depthAtTop = area.minY + Self.scrollZone - y
        let depthAtBottom = y - (area.maxY - Self.scrollZone)
        if drag.canScrollUp, depthAtTop > 0 {
            return -speed(atDepth: depthAtTop)
        }
        if drag.canScrollDown, depthAtBottom > 0 {
            return speed(atDepth: depthAtBottom)
        }
        return 0
    }

    /// The copy goes to the row's place and turns into the row.
    private func endDrag(isCancelled: Bool) {
        guard var drag else { return }
        drag.link.invalidate()
        if isCancelled, drag.row != drag.startRow {
            onMove?(drag.row, drag.startRow)
            drag.row = drag.startRow
        }
        self.drag = nil
        landing = drag.lifted
        rowView(atRow: drag.row, makeIfNecessary: false)?.alphaValue = 0
        let liftState = drag.liftState
        withAnimation(.easeOut(duration: Self.landDuration)) {
            liftState.isLifted = false
        }
        let origin = NSPoint(x: 0, y: rect(ofRow: drag.row).minY - Self.liftMargin)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.landDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            drag.lifted.animator().setFrameOrigin(origin)
        }
        // By the clock: this animation ends at once for a row dropped right where it goes, but its shadow still has to fade.
        Task { [weak self, lifted = drag.lifted] in
            try? await Task.sleep(for: .seconds(Self.landDuration))
            if self?.landing === lifted {
                self?.finishLanding()
            }
        }
        if drag.row != drag.startRow {
            onDrop?()
        }
    }

    private func finishLanding() {
        guard let landing else { return }
        self.landing = nil
        landing.removeFromSuperview()
        enumerateAvailableRowViews { rowView, _ in rowView.alphaValue = 1 }
    }

    override func didAdd(_ rowView: NSTableRowView, forRow row: Int) {
        super.didAdd(rowView, forRow: row)
        // Row views get reused, and the one that was left empty may be used for another row.
        rowView.alphaValue = row == drag?.row ? 0 : 1
    }
}

@Observable
private final class RowLiftState {
    var isLifted = false
}

/// The copy of a row that follows the pointer, on a background of its own to pass over the other rows.
private struct LiftedSensorRow: View {
    let content: SensorSettingRow
    let state: RowLiftState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        content
            .frame(height: SensorOrderTable.rowHeight)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    // Lighter than the list in dark mode too, or it'd look sunk in instead of raised.
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.white.opacity(isDark ? 0.14 : 0))
                    }
                    .padding(.horizontal, 4)
                    .shadow(color: .black.opacity(isDark ? 0.5 : 0.25), radius: 6, y: 2)
                    .opacity(state.isLifted ? 1 : 0)
            }
            .allowsHitTesting(false)
    }
}

/// A scroller for a list with controls at the right end of its rows. An overlay scroller takes clicks a good bit further in
/// than it draws: with one showing, as it is after scrolling and for as long as the pointer stays near it, clicks on the end
/// of a switch did nothing, and that's where the knob is on a sensor that's on. With scroll bars set to always show, it has
/// a column of its own instead.
private final class RowMarginScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        scrollerStyle == .legacy || point.x >= frame.maxX - formRowInset ? super.hitTest(point) : nil
    }
}

private struct SensorSettingRow: View {
    let row: SensorRow
    let isLast: Bool
    @Bindable var settings: AppSettings
    let monitor: SensorMonitor

    private static let handleWidth: CGFloat = 14
    private static let spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: Self.spacing) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: Self.handleWidth)
                .accessibilityHidden(true)
            // What's off stays in the list, to turn back on, but looks it.
            HStack(spacing: Self.spacing) {
                SymbolBadge(symbol: row.symbol, tint: row.tint)
                Text(row.name)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(monitor.value(of: row))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .opacity(isShown.wrappedValue ? 1 : 0.4)
            .animation(.easeInOut(duration: 0.2), value: isShown.wrappedValue)
            Toggle(row.name, isOn: isShown)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                // In a table's row it comes with no action of its own, so VoiceOver couldn't press it (seen on macOS 27).
                .accessibilityAction { isShown.wrappedValue.toggle() }
        }
        .padding(.horizontal, formRowInset)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if !isLast {
                // In line with the names, as in System Settings.
                Divider()
                    .padding(.leading, formRowInset + Self.handleWidth + Self.spacing)
                    .padding(.trailing, formRowInset)
            }
        }
    }

    private var isShown: Binding<Bool> {
        Binding {
            !settings.hiddenSensors.contains(row.id)
        } set: { isShown in
            if isShown {
                settings.hiddenSensors.remove(row.id)
            } else {
                settings.hiddenSensors.insert(row.id)
            }
        }
    }
}
