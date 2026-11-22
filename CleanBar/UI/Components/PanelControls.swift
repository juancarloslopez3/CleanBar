import AppKit
import SwiftUI

/// A panel that floats over other apps' windows without taking the keyboard or making CleanBar the active app, so the app
/// in front keeps both: the floating bar, the sensors list and its flyout, and the panel that helps allow a permission.
final class NonactivatingPanel: NSPanel {
    init(title: String, level: NSWindow.Level) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        self.level = level
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle, .transient]
        allowsToolTipsWhenApplicationIsInactive = true
        setAccessibilityTitle(title)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Calls back once for every refresh of a screen while it runs, with the time the refresh started and the time it
/// shows up.
final class FrameTicker: NSObject {
    private let onFrame: (_ now: CFTimeInterval, _ target: CFTimeInterval) -> Void
    private var link: CADisplayLink?

    init(onFrame: @escaping (_ now: CFTimeInterval, _ target: CFTimeInterval) -> Void) {
        self.onFrame = onFrame
    }

    func start(on screen: NSScreen?) {
        guard link == nil, let screen = screen ?? NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(refresh))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func refresh(_ link: CADisplayLink) {
        onFrame(link.timestamp, link.targetTimestamp)
    }
}

/// Takes the clicks on an icon, or on a button in a panel that never makes CleanBar active (a note's button, the close
/// button of the panel that helps allow a permission). SwiftUI's buttons can't tell a right click, and in a window of an
/// app that's never active, only tracking areas that are always on notice the pointer.
struct ClickArea: NSViewRepresentable {
    let name: String
    @Binding var isHovered: Bool
    @Binding var isPressed: Bool
    let onClick: (ItemClick) -> Void

    func makeNSView(context: Context) -> ClickAreaView {
        ClickAreaView()
    }

    func updateNSView(_ view: ClickAreaView, context: Context) {
        view.toolTip = name
        view.setAccessibilityLabel(name)
        view.onHover = { isHovered = $0 }
        view.onPress = { isPressed = $0 }
        view.onClick = onClick
    }
}

final class ClickAreaView: NSView {
    var onHover: (Bool) -> Void = { _ in }
    var onPress: (Bool) -> Void = { _ in }
    var onClick: (ItemClick) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    // CleanBar is never the active app, so every click is a first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func mouseDown(with event: NSEvent) { onPress(true) }
    override func mouseDragged(with event: NSEvent) { onPress(contains(event)) }
    override func mouseUp(with event: NSEvent) { release(event, isRightClick: false) }

    override func rightMouseDown(with event: NSEvent) { onPress(true) }
    override func rightMouseDragged(with event: NSEvent) { onPress(contains(event)) }
    override func rightMouseUp(with event: NSEvent) { release(event, isRightClick: true) }

    override func accessibilityPerformPress() -> Bool {
        onClick(ItemClick())
        return true
    }

    /// The icon opens when the button is let go over it, so the menu doesn't open under a pressed button, which would
    /// choose whatever menu item the release lands on.
    private func release(_ event: NSEvent, isRightClick: Bool) {
        onPress(false)
        guard contains(event) else { return }
        onClick(ItemClick(isRightClick: isRightClick, modifiers: event.modifierFlags))
    }

    private func contains(_ event: NSEvent) -> Bool {
        bounds.contains(convert(event.locationInWindow, from: nil))
    }
}

/// Notices the pointer and clicks over a part of a panel. SwiftUI's own hover and buttons don't work in a window of an app
/// that's never active: only tracking areas that are always on notice the pointer, and every click is a first click.
struct PointerArea: NSViewRepresentable {
    var label: String?
    /// With whether the pointer is inside, and where the area is on the screen.
    var onHover: ((Bool, NSRect) -> Void)?
    /// Where the pointer is while it's inside, with the origin at the area's top left.
    var onMove: ((CGPoint) -> Void)?
    var onClick: ((NSRect) -> Void)?

    func makeNSView(context: Context) -> PointerAreaView {
        PointerAreaView()
    }

    func updateNSView(_ view: PointerAreaView, context: Context) {
        view.setAccessibilityElement(label != nil)
        view.setAccessibilityRole(onClick == nil ? .unknown : .button)
        view.setAccessibilityLabel(label)
        view.onHover = onHover
        view.onMove = onMove
        view.onClick = onClick
    }
}

final class PointerAreaView: NSView {
    var onHover: ((Bool, NSRect) -> Void)?
    var onMove: ((CGPoint) -> Void)?
    var onClick: ((NSRect) -> Void)?
    /// Follows the pointer while it's inside. Asking where it is works however the window stands, unlike being told when it
    /// moves.
    private var followTimer: Timer?
    private var lastPoint: CGPoint?

    private static let followInterval: TimeInterval = 1.0 / 30

    private var frameOnScreen: NSRect {
        window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
    }

    // As in SwiftUI, the origin is at the top left.
    override var isFlipped: Bool { true }

    // CleanBar is never the active app, so every click is a first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true, frameOnScreen)
        guard onMove != nil, followTimer == nil else { return }
        let timer = Timer(timeInterval: Self.followInterval, target: self, selector: #selector(follow), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
        follow()
    }

    override func mouseExited(with event: NSEvent) {
        stopFollowing()
        onHover?(false, frameOnScreen)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopFollowing()
        }
    }

    private func stopFollowing() {
        followTimer?.invalidate()
        followTimer = nil
        lastPoint = nil
    }

    @objc private func follow() {
        guard let window else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        if point != lastPoint {
            lastPoint = point
            onMove?(point)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Goes with `mouseUp`: without this, the click goes to what's behind.
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?(frameOnScreen)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?(frameOnScreen)
        return onClick != nil
    }
}
