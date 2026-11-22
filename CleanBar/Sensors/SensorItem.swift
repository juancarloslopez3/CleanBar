import AppKit

/// The temperature in the menu bar, or a symbol in its place, in the color and size the user picked. It's macOS that remembers
/// where it goes, as with CleanBar's icon, and being CleanBar's it stays when CleanBar hides icons.
final class SensorItem: NSObject {
    /// Called with the click's event.
    var onClick: ((NSEvent?) -> Void)?

    private let statusItem: NSStatusItem
    private var edgeClicks: StatusItemEdgeClicks?
    /// What it's showing, so it's only drawn again when that changes.
    private var look: Look?

    private struct Look: Equatable {
        /// Nil for the symbol.
        let text: String?
        let color: NSColor?
        let size: CGFloat
    }

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // macOS remembers where the user puts the item under this name.
        statusItem.autosaveName = ControlRole.sensors.rawValue
        super.init()

        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
        // The scanner recognizes CleanBar's items by this identifier.
        button.setAccessibilityIdentifier(ControlRole.sensors.rawValue)
        button.setAccessibilityLabel(ControlRole.sensors.accessibilityLabel)
        edgeClicks = StatusItemEdgeClicks(statusItem: statusItem) { [weak self] event in self?.onClick?(event) }
    }

    /// Whether it's in the menu bar. macOS puts it back where it was.
    var isVisible: Bool {
        get { statusItem.isVisible }
        set { if statusItem.isVisible != newValue { statusItem.isVisible = newValue } }
    }

    var screen: NSScreen? { statusItem.screen }
    var frameOnScreen: NSRect? { statusItem.frameOnScreen }
    /// Where a click counts as being on the item, in screen coordinates.
    var clickArea: NSRect? { statusItem.clickArea }

    /// Shows pressed while the sensors list is open, as when a menu is.
    var isHighlighted = false {
        didSet { statusItem.button?.highlight(isHighlighted) }
    }

    /// Shows `text`, or the symbol when there's none.
    func show(_ text: String?, color: NSColor?, size: CGFloat) {
        let look = Look(text: text, color: color, size: size)
        guard look != self.look else { return }
        self.look = look
        statusItem.button?.image = Self.image(text: text, color: color, size: size)
        statusItem.button?.setAccessibilityValue(text)
    }

    func showMenu(_ menu: NSMenu) {
        statusItem.showMenu(menu)
    }

    @objc private func clicked() {
        edgeClicks?.clickEnded()
        onClick?(NSApp.currentEvent)
    }

    /// `text`, or the symbol when there's none.
    ///
    /// A picture rather than the button's title, so the temperature sits the same whatever its color. Without a color it's a
    /// template, which macOS draws to look like the other icons. Digits are all as wide, so it doesn't shift as they change.
    static func image(text: String?, color: NSColor?, size: CGFloat) -> NSImage {
        guard let string = text else {
            return symbol(color: color, size: size)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: color ?? NSColor.black,
        ]
        let text = NSAttributedString(string: string, attributes: attributes)
        let textSize = text.size()
        let image = NSImage(size: NSSize(width: textSize.width.rounded(.up), height: textSize.height.rounded(.up)), flipped: false) { rect in
            text.draw(in: rect)
            return true
        }
        image.isTemplate = color == nil
        image.accessibilityDescription = string
        return image
    }

    private static func symbol(color: NSColor?, size: CGFloat) -> NSImage {
        var configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        if let color {
            configuration = configuration.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        }
        let name = ControlRole.sensors.accessibilityLabel
        let image = NSImage(systemSymbolName: SettingsTab.sensors.symbol, accessibilityDescription: name)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = color == nil
        return image
    }
}
