import AppKit

/// The menu bar strip of one screen. Frames use the Accessibility / Core Graphics coordinate space: points, with the
/// origin at the top-left of the primary screen.
nonisolated struct MenuBarStrip: Sendable, Hashable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let scale: CGFloat
}

/// An app whose menu bar items should be read.
nonisolated struct ScanTarget: Sendable {
    let pid: pid_t
    let bundleID: String?
    let name: String
    /// Where the app's bundle is.
    let path: String?
}

/// One item in the right side of the menu bar, as seen through the Accessibility API.
nonisolated struct MenuBarItem: Identifiable, Hashable, Sendable {
    /// Bundle identifier plus the item's index among that app's items. Stable while the app keeps running.
    let id: String
    let pid: pid_t
    /// Position among the app's `AXExtrasMenuBar` children, used to find the item again.
    let axIndex: Int
    let bundleID: String?
    let appName: String
    let appPath: String?
    /// The Accessibility identifier, which names macOS's own items (such as `com.apple.menuextra.wifi`).
    let identifier: String?
    /// A title or description, when the app provides one.
    let label: String?
    let frame: CGRect
    /// The menu bar the item sits in, or nil when macOS parked it somewhere else.
    let strip: MenuBarStrip?
    /// False when the item doesn't actually appear in the menu bar: hidden, or moved into macOS's overflow menu.
    /// Such items still report a position, but it's stale.
    let isOnScreen: Bool
    /// Set for CleanBar's own items.
    let controlRole: ControlRole?
    let supportsPress: Bool

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    /// Names the item across launches, to remember a place next to it. macOS's own items go by their identifier, since
    /// their position among macOS's items changes.
    var placeKey: String { isSystemItem ? identifier ?? id : id }

    /// The processes that draw macOS's own items.
    static let systemBundleIDs: Set<String> = ["com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver"]

    var isSystemItem: Bool {
        Self.systemBundleIDs.contains(bundleID ?? "")
    }

    /// Which of macOS's own icons this is, for those macOS's allowlist can hide one by one.
    var systemItem: SystemMenuItem? {
        guard isSystemItem, let identifier else { return nil }
        return SystemMenuItem(identifier: identifier)
    }

    /// Other apps' icons hide per app, which needs a bundle identifier. macOS's own icons hide one by one, but only
    /// those its allowlist names, and never the clock. CleanBar's icon always stays.
    var canBeHidden: Bool {
        guard controlRole == nil else { return false }
        guard isSystemItem else { return bundleID != nil }
        return systemItem?.canBeHidden == true
    }

    /// macOS only tells which app an icon belongs to when the app runs from /Applications, /Library or the system. Icons
    /// of other apps disappear too while CleanBar hides icons.
    var isRecognizedByMacOS: Bool { IconHider.isRecognized(appPath: appPath) }

    var displayName: String {
        let owner = isSystemItem ? "macOS" : appName
        if let label, !label.isEmpty, label != appName {
            return "\(owner) — \(label)"
        }
        return isSystemItem ? String(localized: "macOS system item") : owner
    }
}

/// Apple's « button, which macOS 27 shows when some items don't fit in the menu bar. Clicking it shows those items in
/// place of the app menus.
nonisolated struct OverflowButton: Sendable {
    let frame: CGRect
    let isOnScreen: Bool
}

nonisolated struct MenuBarScan: Sendable {
    var items: [MenuBarItem]
    var overflowButton: OverflowButton?

    /// Turned off under System Settings → Menu Bar. macOS parks most such items outside the menu bar, but some keep a
    /// place in it without being drawn (seen with LuLu on macOS 27.0.1). Apps that hide their own item take it out of
    /// the Accessibility tree, so the only other items in the menu bar that aren't drawn are those behind Apple's «.
    /// That only holds while the menu bar is showing and CleanBar isn't hiding anything, as in the layout editor.
    func isTurnedOff(_ item: MenuBarItem) -> Bool {
        if item.strip == nil { return true }
        guard !item.isOnScreen, items.contains(where: \.isOnScreen) else { return false }
        return !isBehindOverflowButton(item)
    }

    /// Items behind Apple's « report a place stacked onto it, their right end within «. A turned-off item keeps a place
    /// of its own, even when it's next to «.
    func isBehindOverflowButton(_ item: MenuBarItem) -> Bool {
        guard let overflowButton, overflowButton.isOnScreen else { return false }
        let button = overflowButton.frame
        return (button.minX - 1...button.maxX + 1).contains(item.frame.maxX)
    }

    /// Whether « is showing the items behind it. They're then drawn left of it in its menu bar, in place of the app
    /// menus, and stay there until « is clicked again or one of them is dragged out.
    var isOverflowOpen: Bool {
        guard let overflowButton, overflowButton.isOnScreen else { return false }
        let button = overflowButton.frame
        let center = CGPoint(x: button.midX, y: button.midY)
        return items.contains { $0.isOnScreen && $0.frame.maxX <= button.minX && $0.strip?.frame.contains(center) == true }
    }
}

/// Where the layout editor's "New icons appear here" marker is in its row. At either end it stays there as new icons
/// come in; in between, it stays in front of the item it was dropped on.
nonisolated enum NewIconsPlace: Equatable, Sendable {
    case start
    /// The `placeKey`s of the row's items right of the marker, nearest first.
    case before([String])
    case end

    /// The item the marker is in front of: the row's first at the start, or the first of `before` still in the row.
    /// Nil at the end of the row.
    func anchor(in row: [MenuBarItem]) -> MenuBarItem? {
        switch self {
        case .start: row.first
        case .before(let keys): keys.lazy.compactMap { key in row.first { $0.placeKey == key } }.first
        case .end: nil
        }
    }

    /// Stored as "start", or as the `before` keys, empty at the end.
    var propertyList: Any {
        switch self {
        case .start: "start"
        case .before(let keys): keys
        case .end: [String]()
        }
    }

    init?(propertyList: Any) {
        if let keys = propertyList as? [String] {
            self = keys.isEmpty ? .end : .before(keys)
        } else if propertyList as? String == "start" {
            self = .start
        } else {
            return nil
        }
    }
}

extension MenuBarStrip {
    static func all() -> [MenuBarStrip] {
        NSScreen.screens.map { screen in
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let top = NSScreen.primaryHeight - screen.frame.maxY
            let frame = CGRect(x: screen.frame.minX, y: top, width: screen.frame.width, height: height(of: screen))
            return MenuBarStrip(displayID: displayID, frame: frame, scale: screen.backingScaleFactor)
        }
    }

    static func height(of screen: NSScreen?) -> CGFloat {
        guard let screen else { return NSStatusBar.system.thickness }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return max(menuBar, screen.safeAreaInsets.top, NSStatusBar.system.thickness)
    }
}

extension NSScreen {
    /// The primary screen's height, to turn AppKit's screen coordinates (origin at the bottom left of the primary screen)
    /// into those of Accessibility and the window list (origin at its top left), and back.
    static var primaryHeight: CGFloat { screens.first?.frame.maxY ?? 0 }

    /// The screen a point in AppKit's screen coordinates is on.
    static func containing(_ point: NSPoint) -> NSScreen? {
        screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    /// Whether `x` is within the camera housing that splits the menu bar of some MacBooks.
    func isInCameraHousing(x: CGFloat) -> Bool {
        guard let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return false }
        return x > left.maxX && x < right.minX
    }
}

extension ScanTarget {
    init(_ app: NSRunningApplication) {
        self.init(
            pid: app.processIdentifier,
            bundleID: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "App",
            path: app.bundleURL?.path
        )
    }

    static var runningApps: [ScanTarget] {
        NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map(ScanTarget.init)
    }
}
