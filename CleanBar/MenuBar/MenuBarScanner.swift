import AppKit
import ApplicationServices

/// Small typed wrappers around the Accessibility C API.
nonisolated enum AX {
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, "AXChildren") as? [AXUIElement]) ?? []
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, "AXPosition"), let size = value(element, "AXSize"),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: point, size: extent)
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    /// Performs `AXPress` and returns whether the press went through. A menu bar item with a menu only answers once its
    /// menu has closed, so while the menu is open the press times out (`cannotComplete`, seen on macOS 27.0.1): it went
    /// through all the same.
    static func press(_ element: AXUIElement) -> Bool {
        let result = AXUIElementPerformAction(element, "AXPress" as CFString)
        return result == .success || result == .cannotComplete
    }

    static func application(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }
}

/// Reads menu bar items through the Accessibility API.
///
/// Everything here blocks on other processes, so call it off the main thread. That's required when CleanBar's own items
/// are involved: its main thread is what answers those queries, so asking from the main thread would deadlock.
nonisolated enum MenuBarScanner {
    static let menuBarAgentBundleID = "com.apple.MenuBarAgent"

    static func scan(_ targets: [ScanTarget], strips: [MenuBarStrip], ownPID: pid_t) -> MenuBarScan {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        var items: [MenuBarItem] = []
        var overflowButton: OverflowButton?

        for target in targets {
            guard let extras = AX.element(AX.application(target.pid), "AXExtrasMenuBar") else { continue }
            let isOwn = target.pid == ownPID

            for (index, child) in AX.children(extras).enumerated() {
                guard let frame = AX.frame(child), frame.width > 0, frame.height > 0 else { continue }

                // Apple's « button is a plain button among the system's items.
                if target.bundleID == menuBarAgentBundleID, AX.string(child, "AXRole") == "AXButton" {
                    overflowButton = OverflowButton(
                        frame: frame,
                        isOnScreen: isDisplayed(child, frame: frame, pid: target.pid, systemWide: systemWide)
                    )
                    continue
                }

                // macOS's own items are groups hosting the actual item, which carries the identifier and name.
                let described = target.bundleID == menuBarAgentBundleID ? AX.children(child).first ?? child : child
                let identifier = AX.string(described, "AXIdentifier")
                let strip = strips.first { $0.frame.insetBy(dx: 0, dy: -4).contains(CGPoint(x: frame.midX, y: frame.midY)) }
                let label = [AX.string(described, "AXTitle"), AX.string(described, "AXDescription"), identifier]
                    .compactMap { $0 }
                    .first { !$0.isEmpty }

                items.append(MenuBarItem(
                    id: "\(target.bundleID ?? "pid-\(target.pid)")#\(index)",
                    pid: target.pid,
                    axIndex: index,
                    bundleID: target.bundleID,
                    appName: target.name,
                    appPath: target.path,
                    identifier: identifier,
                    label: label,
                    frame: frame,
                    strip: strip,
                    isOnScreen: strip != nil && isDisplayed(child, frame: frame, pid: target.pid, systemWide: systemWide),
                    controlRole: isOwn ? identifier.flatMap(ControlRole.init(rawValue:)) : nil,
                    supportsPress: AX.actions(child).contains("AXPress")
                ))
            }
        }
        return MenuBarScan(items: items.sorted { $0.frame.minX < $1.frame.minX }, overflowButton: overflowButton)
    }

    /// Hidden items keep reporting their last position, so the position alone can't be trusted. Hit-testing the item
    /// tells whether it's really the thing drawn there. Besides the middle, the right end is tried too, in case the
    /// middle of a wide item sits behind the camera notch.
    private static func isDisplayed(_ element: AXUIElement, frame: CGRect, pid: pid_t, systemWide: AXUIElement) -> Bool {
        let points = [CGPoint(x: frame.midX, y: frame.midY), CGPoint(x: frame.maxX - min(3, frame.width / 2), y: frame.midY)]
        return points.contains { point in
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
                  let hit
            else { return false }
            if CFEqual(hit, element) { return true }
            // macOS's own items are hosted views: the hit test returns an element inside them rather than the item itself.
            var hitPID: pid_t = 0
            AXUIElementGetPid(hit, &hitPID)
            return hitPID == pid && AX.string(element, "AXRole") != "AXMenuBarItem"
        }
    }

    /// Whether nothing is at `point` in the menu bar, nor a few points to either side. There, the hit test finds the menu
    /// bar itself of the app whose menus it shows (seen on macOS 27.0.1). It does in the gaps between icons too, which
    /// the points on either side leave out, and around some apps' icons it finds that app's own menu bar instead.
    static func isEmptySpace(around point: CGPoint, menuBarOwner: pid_t) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        return [CGFloat(-12), 0, 12].allSatisfy { offset in
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x + offset), Float(point.y), &hit) == .success,
                  let hit
            else { return false }
            var pid: pid_t = 0
            AXUIElementGetPid(hit, &pid)
            return pid == menuBarOwner && AX.string(hit, "AXRole") == "AXMenuBar"
        }
    }

    /// Whether nothing is drawn in the menu bar for 46 points left of an icon's frame, so no icon is left of it: icons
    /// are at least 16 points wide and at most 16 apart (seen on macOS 27.0.1). The camera housing counts as empty.
    static func hasNothingLeft(of frame: CGRect, menuBarOwner: pid_t) -> Bool {
        [CGFloat(16), 34].allSatisfy { distance in
            isEmptySpace(around: CGPoint(x: frame.minX - distance, y: frame.midY), menuBarOwner: menuBarOwner)
        }
    }

    /// Where the items are now, by item id, read again from the elements they were read from. Missing for items that are
    /// gone.
    static func frames(of items: [MenuBarItem]) -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        for (pid, appItems) in Dictionary(grouping: items, by: \.pid) {
            guard let extras = AX.element(AX.application(pid), "AXExtrasMenuBar") else { continue }
            let children = AX.children(extras)
            for item in appItems where children.indices.contains(item.axIndex) {
                frames[item.id] = AX.frame(children[item.axIndex])
            }
        }
        return frames
    }

    /// Opens a menu bar item as if it had been clicked. Only works for items that support `AXPress`.
    static func press(_ item: MenuBarItem) -> Bool {
        guard let extras = AX.element(AX.application(item.pid), "AXExtrasMenuBar") else { return false }
        let children = AX.children(extras)
        guard children.indices.contains(item.axIndex) else { return false }
        return AX.press(children[item.axIndex])
    }

    /// One of macOS's own items, by its identifier (such as `com.apple.menuextra.clock`). Each sits in a group.
    static func systemItem(_ identifier: String) -> AXUIElement? {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: menuBarAgentBundleID).first,
              let extras = AX.element(AX.application(agent.processIdentifier), "AXExtrasMenuBar")
        else { return nil }
        for group in AX.children(extras) {
            if let item = AX.children(group).first(where: { AX.string($0, "AXIdentifier") == identifier }) {
                return item
            }
        }
        return nil
    }

    static func systemItemFrame(_ identifier: String) -> CGRect? {
        systemItem(identifier).flatMap(AX.frame)
    }

    static func pressSystemItem(_ identifier: String) -> Bool {
        guard let item = systemItem(identifier) else { return false }
        return AX.press(item)
    }
}

/// Questions about on-screen windows, answered with the public window list (no permission needed).
nonisolated enum WindowInfo {
    private static func onScreenWindows() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    }

    private static func bounds(_ info: [String: Any]) -> CGRect {
        guard let dictionary = info["kCGWindowBounds"] else { return .null }
        return CGRect(dictionaryRepresentation: dictionary as! CFDictionary) ?? .null
    }

    /// Whether Notification Center's panel is open. Its notification banners are much shorter.
    static func isNotificationCenterOpen() -> Bool {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
            .first?.processIdentifier
        else { return false }
        return onScreenWindows().contains { info in
            (info["kCGWindowOwnerPID"] as? pid_t) == pid
                && (info["kCGWindowAlpha"] as? Double ?? 1) > 0
                && bounds(info).height > 300
        }
    }

    /// The windows on screen now, to tell later which ones opened since.
    static func onScreenWindowIDs() -> Set<CGWindowID> {
        Set(onScreenWindows().compactMap { $0["kCGWindowNumber"] as? CGWindowID })
    }

    /// An app's windows on screen now.
    static func onScreenWindowIDs(ownedBy pid: pid_t) -> Set<CGWindowID> {
        Set(onScreenWindows().filter { ($0["kCGWindowOwnerPID"] as? pid_t) == pid }.compactMap { $0["kCGWindowNumber"] as? CGWindowID })
    }

    /// Whether a window that opened since `earlier` is still open above apps' normal windows: a menu, a popover or a
    /// panel, like the ones menu bar icons open. CleanBar's own windows don't count, nor Window Server's, like the menu
    /// bar itself.
    static func hasWindowOpened(since earlier: Set<CGWindowID>) -> Bool {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return onScreenWindows().contains { info in
            guard let id = info["kCGWindowNumber"] as? CGWindowID, !earlier.contains(id) else { return false }
            return (info["kCGWindowLayer"] as? Int ?? 0) > 0
                && (info["kCGWindowOwnerPID"] as? pid_t) != ownPID
                && (info["kCGWindowOwnerName"] as? String) != "Window Server"
                && (info["kCGWindowAlpha"] as? Double ?? 1) > 0
                && bounds(info).height > 1
        }
    }

    /// An app's largest normal window on screen now, like System Settings' window, and where it is (origin at the top left
    /// of the primary screen, like Accessibility frames). Not while it fades in or out as it opens or closes.
    static func largestWindow(of pid: pid_t) -> (id: CGWindowID, frame: CGRect)? {
        var largest: (id: CGWindowID, frame: CGRect)?
        for info in onScreenWindows() {
            guard (info["kCGWindowOwnerPID"] as? pid_t) == pid,
                  (info["kCGWindowLayer"] as? Int) == 0,
                  isOpaque(info),
                  let id = info["kCGWindowNumber"] as? CGWindowID
            else { continue }
            let frame = bounds(info)
            if !frame.isNull, frame.width * frame.height > largest.map({ $0.frame.width * $0.frame.height }) ?? 0 {
                largest = (id, frame)
            }
        }
        return largest
    }

    /// Where a window is now (origin at the top left of the primary screen), or nil once it's closed or off screen:
    /// minimized, hidden or on another Space. Nil too while it fades in or out: a closing window stays in the list for a
    /// moment, shrinking. Asking about one window is about five times quicker than listing them all.
    static func frame(ofWindow id: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
              info["kCGWindowIsOnscreen"] as? Bool == true,
              isOpaque(info)
        else { return nil }
        let frame = bounds(info)
        return frame.isNull ? nil : frame
    }

    private static func isOpaque(_ info: [String: Any]) -> Bool {
        (info["kCGWindowAlpha"] as? Double ?? 1) >= 1
    }

    /// Whether some app has a menu open, e.g. the menu of an item the user just revealed.
    static func isMenuOpen() -> Bool {
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return onScreenWindows().contains { info in
            (info["kCGWindowLayer"] as? Int) == menuLevel
                && (info["kCGWindowAlpha"] as? Double ?? 1) > 0
                && bounds(info).height > 1
        }
    }
}
