import AppKit

/// CleanBar's own status items. There's only the icon: other apps' icons are hidden with macOS's menu bar allowlist,
/// so no divider is needed.
nonisolated enum ControlRole: String, Sendable {
    case icon = "CleanBar.Icon"

    var accessibilityLabel: String { "CleanBar" }
}

/// Wraps CleanBar's `NSStatusItem`. It shows the symbol the user picked, filled in (or turned around) while hidden icons
/// are showing, and can be left out of the menu bar.
final class ControlItem: NSObject {
    /// Called with the click's event.
    var onClick: ((NSEvent?) -> Void)?

    private let statusItem: NSStatusItem
    private var showsHiddenIcons = false

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
        button.toolTip = String(localized: "CleanBar — click to show or hide icons, right-click for options")
        updateImage()
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

    var screen: NSScreen? { statusItem.button?.window?.screen }

    /// Where the icon is, in screen coordinates.
    var frameOnScreen: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func setShowsHiddenIcons(_ showing: Bool) {
        guard showing != showsHiddenIcons else { return }
        showsHiddenIcons = showing
        updateImage()
    }

    private func updateImage() {
        statusItem.button?.image = style.image(showingHiddenIcons: showsHiddenIcons, opensBelow: opensBelow)
    }

    func showMenu(_ menu: NSMenu) {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func clicked() {
        onClick?(NSApp.currentEvent)
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
