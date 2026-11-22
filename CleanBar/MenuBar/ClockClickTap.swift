import AppKit
import os

/// Keeps clicks on macOS's clock from reaching the menu bar while CleanBar hides icons, and hands them to CleanBar, which
/// opens Notification Center itself (`MenuBarManager.openNotificationCenter`): it pauses hiding and clicks the clock with
/// a click of its own, marked as CleanBar's, which goes through.
///
/// Notification Center only opens from the clock while hiding is paused, and macOS brings the hidden icons back for that
/// moment. It takes the list back as soon as they're all back, unless the menu bar is still handling a click, which it
/// does in several steps over a tenth of a second: then the icons stay long enough to be seen. So the user's click is
/// taken out of the event stream, from the button going down until it comes up, and only CleanBar's reaches the clock:
/// a click opens Notification Center or closes it, so two would undo each other.
///
/// The tap runs on its own thread, so a busy main thread never holds up clicks.
nonisolated final class ClockClickTap: @unchecked Sendable {
    private struct State {
        /// Where the clock is, with the origin at the top left of the main screen like Accessibility frames. Nil lets
        /// every click through.
        var clockFrame: CGRect?
        /// Set from a click taken on the clock until its button comes up.
        var isHolding = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onClick: @Sendable () -> Void
    /// Set once, before the tap's thread starts.
    private var port: CFMachPort?

    /// `onClick` is called on the tap's thread.
    init(onClick: @escaping @Sendable () -> Void) {
        self.onClick = onClick
    }

    var isRunning: Bool { port != nil }

    /// Clicks on the clock are taken while it has a frame here: set it while CleanBar hides icons, nil otherwise.
    func setClockFrame(_ frame: CGRect?) {
        state.withLock { $0.clockFrame = frame }
    }

    /// Starts taking clicks on the clock. Returns false when macOS refuses, as without the Accessibility permission.
    @discardableResult
    func start() -> Bool {
        guard port == nil else { return true }
        // Trackpads add pressure events to a click (`NSEvent.EventType.pressure`), which go to the menu bar too.
        let types = [CGEventType.leftMouseDown, .leftMouseUp, .leftMouseDragged, CGEventType(rawValue: 34)].compactMap { $0 }
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.port = port
        let thread = Thread { [self] in
            guard let port = self.port else { return }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
            CFRunLoopRun()
        }
        thread.name = "CleanBar clock clicks"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        return Unmanaged<ClockClickTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
    }

    /// Returns nil to take the event out of the stream.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        // CleanBar's own click on the clock goes through, and the user's click stays held until its button comes up.
        guard event.getIntegerValueField(.eventSourceUserData) != ItemMover.eventMark else {
            return Unmanaged.passUnretained(event)
        }
        switch type {
        case .leftMouseDown:
            let location = event.location
            let isOnClock = state.withLock { $0.clockFrame?.contains(location) ?? false }
            // A click that closes Notification Center goes through: it closes on clicks outside it.
            if isOnClock, !WindowInfo.isNotificationCenterOpen() {
                state.withLock { $0.isHolding = true }
                onClick()
                return nil
            }
        default:
            let isHolding = state.withLock { state in
                defer {
                    if type == .leftMouseUp {
                        state.isHolding = false
                    }
                }
                return state.isHolding
            }
            if isHolding {
                return nil
            }
        }
        return Unmanaged.passUnretained(event)
    }
}
