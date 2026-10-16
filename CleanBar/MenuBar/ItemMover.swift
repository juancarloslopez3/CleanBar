import AppKit
import os

/// Moves menu bar items by posting mouse events, the same way a person ⌘-drags an icon, and clicks them.
/// Requires the Accessibility permission.
///
/// macOS drags a menu bar icon with the pointer itself, so the events have to move the pointer. CleanBar hides it
/// meanwhile and shows it again where it was, so all the user sees is the icon moving: a drag hides the pointer for about
/// 0.3 s, a click for about 0.15 s. The user's own mouse input is set aside meanwhile (`UserMouseInput`): their moves
/// still count, so the pointer comes back where they moved it, and their clicks are dropped, since they would land
/// wherever the hidden pointer is.
///
/// CleanBar has no menus, so while it's in front the menus in the menu bar are still those of the app in front before
/// it, and a click or drag in the menu bar switches to that app, whose windows then cover CleanBar's (seen on macOS 27.0.1
/// with the click on « and with ⌘-drags). When a CleanBar window was in front, CleanBar comes back to the front
/// afterwards, which leaves « open. Until then the window floats above the other apps' windows, so it doesn't flash away
/// and back.
nonisolated enum ItemMover {
    enum Destination: Sendable {
        case leftOf(CGRect)
        case rightOf(CGRect)
    }

    /// Marks CleanBar's own events, to tell them from the user's.
    fileprivate static let eventMark: Int64 = 0x436C_6561_6E42_6172 // "CleanBar"

    private static let userInput = UserMouseInput()

    /// A ⌘-drag, seen on macOS 27.0.1: moving a few points with the button down starts it. About 40 ms later macOS hands
    /// the drag to the Window Server, which moves a picture of the icon with the pointer in a window of MenuBarAgent's,
    /// on screen 65–100 ms after the first move. When the button comes up, the icon goes where the pointer is. So the
    /// rest of the way waits for that window, and the drag takes about 0.3 s.
    static func drag(from start: CGPoint, to destination: Destination) async {
        let end = switch destination {
        case .leftOf(let frame): CGPoint(x: frame.minX + 2, y: frame.midY)
        case .rightOf(let frame): CGPoint(x: frame.maxX - 2, y: frame.midY)
        }
        let window = await keepWindowInFront()
        let source = CGEventSource(stateID: .combinedSessionState)
        let agent = NSRunningApplication.runningApplications(withBundleIdentifier: MenuBarScanner.menuBarAgentBundleID)
            .first?.processIdentifier
        let agentWindows = agent.map(WindowInfo.onScreenWindowIDs(ownedBy:)) ?? []
        await withPointerHidden {
            post(.mouseMoved, at: start, source: source)
            await pause(20)
            post(.leftMouseDown, at: start, flags: .maskCommand, source: source)
            await pause(20)
            let firstStep = min(8, abs(end.x - start.x)) * (end.x < start.x ? -1 : 1)
            post(.leftMouseDragged, at: CGPoint(x: start.x + firstStep, y: start.y), flags: .maskCommand, source: source)
            await waitForDragPicture(of: agent, besides: agentWindows)
            let steps = 3
            for step in 1...steps {
                let progress = CGFloat(step) / CGFloat(steps)
                let point = CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress)
                post(.leftMouseDragged, at: point, flags: .maskCommand, source: source)
                await pause(16)
            }
            await pause(50)
            post(.leftMouseUp, at: end, flags: .maskCommand, source: source)
            await pause(30)
        }
        if let window {
            await comeBackToFront(window)
        }
    }

    /// Clicks at `point`.
    static func click(at point: CGPoint, isRightClick: Bool = false, flags: CGEventFlags = []) async {
        let window = await keepWindowInFront()
        let source = CGEventSource(stateID: .combinedSessionState)
        let button: CGMouseButton = isRightClick ? .right : .left
        await withPointerHidden {
            post(.mouseMoved, at: point, source: source)
            await pause(40)
            post(isRightClick ? .rightMouseDown : .leftMouseDown, at: point, flags: flags, button: button, source: source)
            await pause(60)
            post(isRightClick ? .rightMouseUp : .leftMouseUp, at: point, flags: flags, button: button, source: source)
            await pause(40)
        }
        if let window {
            await comeBackToFront(window)
        }
    }

    /// Runs `body`, whose events move the pointer, with the pointer hidden. Then it shows again where it was, moved as
    /// far as the user moved the mouse meanwhile.
    private static func withPointerHidden(_ body: () async -> Void) async {
        let location = CGEvent(source: nil)?.location
        userInput.setAside()
        Pointer.hide()
        await body()
        let moved = userInput.takeBack()
        if let location {
            let target = CGPoint(x: location.x + moved.dx, y: location.y + moved.dy)
            CGWarpMouseCursorPosition(isOnDisplay(target) ? target : location)
            // Otherwise macOS ignores the mouse for a moment after the pointer was put somewhere.
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        Pointer.show()
    }

    private static func isOnDisplay(_ point: CGPoint) -> Bool {
        var count: UInt32 = 0
        return CGGetDisplaysWithPoint(point, 0, nil, &count) == .success && count > 0
    }

    /// Waits until MenuBarAgent shows the picture it drags, a window besides the ones it had on screen before (the menu
    /// bar itself is the Window Server's), or for 0.3 s.
    private static func waitForDragPicture(of agent: pid_t?, besides windowsBefore: Set<CGWindowID>) async {
        let deadline = Date.now + 0.3
        while Date.now < deadline, !Task.isCancelled {
            if let agent, !WindowInfo.onScreenWindowIDs(ownedBy: agent).isSubset(of: windowsBefore) { return }
            await pause(5)
        }
    }

    /// CleanBar's window, when CleanBar is in front with one, like the layout editor. It floats above other apps'
    /// windows until CleanBar is back in front. Nil otherwise: once the editor closed, CleanBar shouldn't take the
    /// keyboard with no window to show.
    @MainActor private static func keepWindowInFront() -> NSWindow? {
        guard NSApp.isActive, let window = NSApp.keyWindow, window.level == .normal else { return nil }
        window.level = .floating
        return window
    }

    /// Activating CleanBar brings its window back as the key window. The switch to the other app has usually happened by
    /// the time the events are posted. The app now in front has to agree: plain `NSApp.activate()` is turned down while
    /// Xcode is in front, for example, but activating from that app works. Once CleanBar is in front again, or nothing
    /// switched, the window stops floating and stays in front of the other windows.
    @MainActor private static func comeBackToFront(_ window: NSWindow) async {
        var deadline = Date.now + 0.5
        var hasAsked = false
        while Date.now < deadline, !(hasAsked && NSApp.isActive) {
            if !hasAsked, !NSApp.isActive, let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
               NSRunningApplication.current.activate(from: front, options: []) {
                hasAsked = true
                // Activating takes a moment.
                deadline = .now + 0.5
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        window.level = .normal
        // Not when it was closed meanwhile, nor over the app in front when CleanBar couldn't come back.
        if NSApp.isActive, window.isVisible {
            window.orderFront(nil)
        }
    }

    private static func post(
        _ type: CGEventType, at point: CGPoint, flags: CGEventFlags = [], button: CGMouseButton = .left, source: CGEventSource?
    ) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            return
        }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: eventMark)
        event.post(tap: .cghidEventTap)
    }

    private static func pause(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }
}

/// Hides and shows the pointer. macOS ignores an app hiding it from the background, unless the app asked to set the
/// pointer from the background, with a private Window Server connection property (seen on macOS 27.0.1).
private nonisolated enum Pointer {
    private static let setsPointerInBackground: Void = {
        typealias MainConnectionID = @convention(c) () -> Int32
        typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let coreGraphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
        guard let mainConnectionID = dlsym(coreGraphics, "CGSMainConnectionID"),
              let setConnectionProperty = dlsym(coreGraphics, "CGSSetConnectionProperty")
        else { return }
        let connection = unsafeBitCast(mainConnectionID, to: MainConnectionID.self)()
        _ = unsafeBitCast(setConnectionProperty, to: SetConnectionProperty.self)(
            connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue
        )
    }()

    static func hide() {
        _ = setsPointerInBackground
        CGDisplayHideCursor(CGMainDisplayID())
    }

    static func show() {
        CGDisplayShowCursor(CGMainDisplayID())
    }
}

/// The user's mouse input while CleanBar's events move the hidden pointer: their moves are added up, and their clicks
/// are dropped (a click's release goes with its press). An event tap on its own thread, like `ClockClickTap`, on only
/// while the input is set aside. Should CleanBar never take it back, clicks go through again after two seconds.
private nonisolated final class UserMouseInput: @unchecked Sendable {
    private struct State {
        /// How many of CleanBar's clicks and drags are under way.
        var holds = 0
        var since = Date.distantPast
        var moved = CGVector.zero
        /// Buttons whose press was dropped, so their release is dropped too.
        var droppedButtons: Set<Int64> = []

        var isHolding: Bool { holds > 0 && Date.now.timeIntervalSince(since) < 2 }
        var isDone: Bool { !isHolding && (droppedButtons.isEmpty || Date.now.timeIntervalSince(since) > 2) }
    }

    private static let moves: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
    private static let presses: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    private static let releases: [CGEventType] = [.leftMouseUp, .rightMouseUp, .otherMouseUp]

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Set once, before the tap's thread starts.
    private var port: CFMachPort?

    /// Starts adding up the user's moves and dropping their clicks.
    func setAside() {
        state.withLock { state in
            if state.holds == 0 {
                state.moved = .zero
                state.since = .now
            }
            state.holds += 1
        }
        if let port = startedPort() {
            CGEvent.tapEnable(tap: port, enable: true)
        }
    }

    /// Lets the user's clicks through again. Returns how far they moved the mouse meanwhile.
    func takeBack() -> CGVector {
        let (moved, isDone) = state.withLock { state in
            state.holds = max(0, state.holds - 1)
            return (state.moved, state.isDone)
        }
        if isDone, let port {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        return moved
    }

    /// The tap, made the first time. Nil when macOS refuses it, as without the Accessibility permission.
    private func startedPort() -> CFMachPort? {
        if let port { return port }
        let types = Self.moves + Self.presses + Self.releases
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }
        self.port = port
        let thread = Thread { [self] in
            guard let port = self.port else { return }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
            CFRunLoopRun()
        }
        thread.name = "CleanBar mouse input"
        thread.qualityOfService = .userInteractive
        thread.start()
        return port
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        return Unmanaged<UserMouseInput>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
    }

    /// Returns nil to drop the event.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port, !state.withLock({ $0.isDone }) {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != ItemMover.eventMark else {
            return Unmanaged.passUnretained(event)
        }
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        let delta = CGVector(dx: event.getDoubleValueField(.mouseEventDeltaX), dy: event.getDoubleValueField(.mouseEventDeltaY))
        let (keeps, isDone) = state.withLock { state in
            var keeps = true
            if Self.moves.contains(type) {
                if state.isHolding {
                    state.moved.dx += delta.dx
                    state.moved.dy += delta.dy
                }
            } else if Self.presses.contains(type) {
                if state.isHolding {
                    state.droppedButtons.insert(button)
                    keeps = false
                } else {
                    state.droppedButtons.remove(button)
                }
            } else if Self.releases.contains(type) {
                keeps = state.droppedButtons.remove(button) == nil
            }
            if state.isDone {
                state.droppedButtons.removeAll()
            }
            return (keeps, state.isDone)
        }
        if isDone, let port {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        return keeps ? Unmanaged.passUnretained(event) : nil
    }
}
