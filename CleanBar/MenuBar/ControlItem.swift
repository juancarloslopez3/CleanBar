import AppKit

/// CleanBar's own status items: its icon and, when the Sensors setting is on, the temperature (`SensorItem`). Other apps'
/// icons are hidden with macOS's menu bar allowlist, so no divider is needed.
nonisolated enum ControlRole: String, Sendable {
    case icon = "CleanBar.Icon"
    case sensors = "CleanBar.Sensors"

    var accessibilityLabel: String {
        switch self {
        case .icon: "CleanBar"
        case .sensors: String(localized: "Temperature")
        }
    }
}

/// Wraps CleanBar's `NSStatusItem`. It shows the symbol the user picked, filled in (or turned around) while hidden icons
/// are showing, and can be left out of the menu bar.
final class ControlItem: NSObject {
    /// Called with the click's event.
    var onClick: ((NSEvent?) -> Void)?

    private let statusItem: NSStatusItem
    private var showsHiddenIcons = false
    private var edgeClicks: StatusItemEdgeClicks?

    init(role: ControlRole) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // macOS remembers where the user puts the item under this name.
        statusItem.autosaveName = role.rawValue
        super.init()

        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // The scanner recognizes CleanBar's items by this identifier.
        button.setAccessibilityIdentifier(role.rawValue)
        button.setAccessibilityLabel(role.accessibilityLabel)
        updateImage()
        edgeClicks = StatusItemEdgeClicks(statusItem: statusItem) { [weak self] event in self?.onClick?(event) }
    }

    var style = MenuBarIconStyle.circle {
        didSet { if style != oldValue { updateImage() } }
    }

    /// Hidden icons show in the floating bar, below the menu bar, so the arrow points down.
    var opensBelow = false {
        didSet { if opensBelow != oldValue { updateImage() } }
    }

    /// Whether the icon is in the menu bar. macOS puts it back where it was.
    var isVisible: Bool {
        get { statusItem.isVisible }
        set { if statusItem.isVisible != newValue { statusItem.isVisible = newValue } }
    }

    var screen: NSScreen? { statusItem.screen }

    /// Where the icon is, in screen coordinates.
    var frameOnScreen: NSRect? { statusItem.frameOnScreen }

    /// Where a click counts as being on the icon, in screen coordinates.
    var clickArea: NSRect? { statusItem.clickArea }

    func setShowsHiddenIcons(_ showing: Bool) {
        guard showing != showsHiddenIcons else { return }
        showsHiddenIcons = showing
        updateImage()
    }

    private func updateImage() {
        statusItem.button?.image = style.image(showingHiddenIcons: showsHiddenIcons, opensBelow: opensBelow)
    }

    func showMenu(_ menu: NSMenu) {
        statusItem.showMenu(menu)
    }

    @objc private func clicked() {
        edgeClicks?.clickEnded()
        onClick?(NSApp.currentEvent)
    }
}

extension NSStatusItem {
    var screen: NSScreen? { button?.window?.screen }

    /// Where the item is, in screen coordinates.
    var frameOnScreen: NSRect? {
        guard let button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Where a click counts as being on the item: all of the menu bar's height, like macOS's own items. Nil while the item
    /// isn't in the menu bar, as when there's no room for it.
    var clickArea: NSRect? {
        guard isVisible, let screen, let frame = frameOnScreen else { return nil }
        let height = MenuBarStrip.height(of: screen)
        guard frame.width > 0, frame.midY > screen.frame.maxY - height else { return nil }
        // A point more on top: at the very top of the screen the pointer is at the screen's maxY, which a rect leaves out.
        return NSRect(x: frame.minX, y: screen.frame.maxY - height, width: frame.width, height: height + 1)
    }

    /// Opens a menu below the item, as if it were the item's own.
    func showMenu(_ menu: NSMenu) {
        self.menu = menu
        button?.performClick(nil)
        self.menu = nil
    }
}

/// Makes clicks above and below a status item count as clicks on it. Other apps' items are shorter than the menu bar on a
/// Mac with a camera housing, while macOS's own fill it (seen on macOS 27.2: 24 pt, centered in 33 pt), so a click at the top
/// edge goes to the menu bar and the item never hears of it. Those clicks only reach CleanBar through a global monitor.
///
/// Pressing an item also takes the front from CleanBar, so its settings window drops behind the app that owns the menu bar
/// (seen on macOS 27.2, within 30 ms of the press), and that's undone here once the click has ended: done during the press,
/// quick clicks could end up doing nothing.
///
/// It lasts as long as the item, which is as long as CleanBar runs.
final class StatusItemEdgeClicks {
    private let statusItem: NSStatusItem
    private let onClick: (NSEvent) -> Void
    /// The kind of button that went down in the area, until it comes up.
    private var pressed: NSEvent.EventType?
    /// When a press on this item last took the front from CleanBar.
    private var lostFrontDate: Date?
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?

    /// How long a press that took the front can be held for it to be taken back, so it's never long after the user may have
    /// gone on to something else.
    private static let longestPress = 3.0

    init(statusItem: NSStatusItem, onClick: @escaping (NSEvent) -> Void) {
        self.statusItem = statusItem
        self.onClick = onClick
        let buttons: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        let elsewhere = NSEvent.addGlobalMonitorForEvents(matching: buttons) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        // The item's window can be a little taller than its button.
        let inCleanBar = NSEvent.addLocalMonitorForEvents(matching: buttons) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        monitors = [elsewhere, inCleanBar].compactMap { $0 }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lostFront() }
        }
    }

    private func lostFront() {
        // CleanBar hears of this before it gets the press itself.
        if NSEvent.pressedMouseButtons != 0, let area = statusItem.clickArea, NSMouseInRect(NSEvent.mouseLocation, area, false) {
            lostFrontDate = .now
        }
    }

    /// Takes the front back if this click took it, and there's a window that had it. To be called before what the click does.
    func clickEnded() {
        defer { lostFrontDate = nil }
        guard let lostFrontDate, Date.now.timeIntervalSince(lostFrontDate) < Self.longestPress, !NSApp.isActive,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })
        else { return }
        // The app in front has to agree: plain `NSApp.activate()` can be turned down.
        if let front = NSWorkspace.shared.frontmostApplication, front != .current {
            NSRunningApplication.current.activate(from: front, options: [])
        } else {
            NSApp.activate()
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func handle(_ event: NSEvent) {
        // Other apps' events have no window here: the location is on the screen.
        let location = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        let isInArea = statusItem.clickArea.map { NSMouseInRect(location, $0, false) } ?? false
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            // What lands on the item itself is its button's. ⌘ is for moving the item.
            let isOnButton = event.window != nil && statusItem.frameOnScreen.map { NSMouseInRect(location, $0, false) } ?? false
            pressed = isInArea && !isOnButton && !event.modifierFlags.contains(.command) ? event.type : nil
        case .leftMouseUp, .rightMouseUp:
            let wasPressed = pressed == (event.type == .leftMouseUp ? .leftMouseDown : .rightMouseDown)
            pressed = nil
            if wasPressed, isInArea {
                // Out of the monitor, as this may open a menu, which takes over until it closes.
                DispatchQueue.main.async { [weak self, onClick] in
                    self?.clickEnded()
                    onClick(event)
                }
            }
        default:
            break
        }
    }
}

extension MenuBarIconStyle {
    /// The icon's picture. It's filled in, or turned around, while hidden icons are showing. The arrow points to where
    /// they show: left, where they come back in the menu bar, or down, when they show in the floating bar.
    func image(showingHiddenIcons showing: Bool, opensBelow: Bool = false) -> NSImage {
        let image: NSImage = switch self {
        case .circle: .symbol(showing ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        case .dots: .dots(inPill: showing)
        // A small dot, which gets a ring around it.
        case .dot: showing ? .symbol("smallcircle.filled.circle") : .symbol("circle.fill", pointSize: 6)
        case .star: .symbol(showing ? "star.fill" : "star")
        case .arrow: opensBelow
            ? .symbol(showing ? "chevron.up" : "chevron.down")
            : .symbol(showing ? "chevron.right" : "chevron.left")
        }
        image.accessibilityDescription = "CleanBar"
        image.isTemplate = true
        return image
    }
}

private extension NSImage {
    static func symbol(_ name: String, pointSize: CGFloat? = nil) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        guard let pointSize else { return image }
        return image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)) ?? image
    }

    /// Three dots, bigger than the "ellipsis" symbol's. While hidden icons are showing, they're cut out of a pill that
    /// fits around them, so they keep their size ("ellipsis.circle.fill" has much smaller dots).
    static func dots(inPill: Bool) -> NSImage {
        let diameter: CGFloat = 3.5, spacing: CGFloat = 5.5, pillHeight: CGFloat = 10
        // Both pictures are the pill's size, so the dots don't move. It still fits the 22 pt square status item.
        let size = NSSize(width: 2 * spacing + pillHeight, height: 16)
        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath()
            // The dots are holes in the pill.
            path.windingRule = .evenOdd
            if inPill {
                let pill = NSRect(x: 0, y: rect.midY - pillHeight / 2, width: rect.width, height: pillHeight)
                path.appendRoundedRect(pill, xRadius: pillHeight / 2, yRadius: pillHeight / 2)
            }
            for index in -1...1 {
                let x = rect.midX + CGFloat(index) * spacing
                path.appendOval(in: NSRect(x: x - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter))
            }
            NSColor.black.setFill()
            path.fill()
            return true
        }
    }
}
