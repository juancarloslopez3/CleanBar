import AppKit
import SwiftUI

/// How an icon was clicked in the floating bar, so it can be clicked the same way in the menu bar.
nonisolated struct ItemClick: Sendable {
    var isRightClick = false
    var modifiers: NSEvent.ModifierFlags = []

    /// A left click without modifier keys, which an Accessibility press can stand in for.
    var isPlain: Bool {
        !isRightClick && modifiers.isDisjoint(with: .shortcutKeys)
    }

    var eventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        return flags
    }
}

/// A small bar below CleanBar's icon (or below the pointer, when empty menu bar space opened it) that shows the hidden
/// icons while they stay out of the menu bar, like a piece of the menu bar. Clicking an icon in it asks for that icon's
/// menu. It closes on a click anywhere else, when another app comes to the front, or when the Space or the screens
/// change. It can show a note with a button instead of icons.
///
/// It grows out of the menu bar below CleanBar's icon, a drop of glass that stretches into the bar with a spring while
/// the icons come out one after another, nearest first, and it shrinks back into the same spot as it closes. The icons
/// stay put meanwhile: the glass reveals them as it grows. With Reduce Motion on, it only fades.
///
/// It's never the key window and never makes CleanBar the active app, so the app in front keeps the keyboard and its
/// menus.
final class FloatingBar {
    /// Called with an icon clicked in the bar, once the bar has closed.
    var onClick: ((MenuBarItem, ItemClick) -> Void)?
    /// Called whenever the bar closes.
    var onClose: (() -> Void)?
    /// Whether a click outside the bar leaves it open, because it opens and closes the bar itself, like a click on
    /// CleanBar's icon. Takes the click's place on the screen.
    var ignoresClick: ((NSPoint) -> Bool)?

    private(set) var isOpen = false
    /// What VoiceOver calls the bar.
    private let title: String
    private var panel: NSPanel?
    private var glass: NSGlassEffectView?
    private var hostingView: NSHostingView<FloatingBarView>?
    /// Measures the icons. The view on screen can't: the glass it's in sets its size.
    private let measuringView = NSHostingView(rootView: FloatingBarView())
    private var session = 0
    private var monitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Where the bar is once it's open.
    private var openFrame = NSRect.zero
    /// Where across the screen the bar grows out of: below CleanBar's icon or the pointer, within `openFrame`.
    private var originX: CGFloat = 0
    private var motion: Motion?
    private lazy var ticker = FrameTicker { [weak self] now, time in self?.step(now: now, at: time) }

    /// Room around the icons. With the bar's ends fully rounded, it keeps an icon's highlight the same shape as the bar.
    private static let padding = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
    /// Space between the menu bar and the bar.
    private static let gap: CGFloat = 5
    private static let screenMargin: CGFloat = 8

    init(title: String = String(localized: "Hidden Icons")) {
        self.title = title
    }

    var containsMouse: Bool {
        guard isOpen, let panel else { return false }
        return NSMouseInRect(NSEvent.mouseLocation, panel.frame, false)
    }

    /// Shows the icons, in this order, centered below `anchor` (CleanBar's icon or the pointer, in screen coordinates).
    /// While the bar is open, it takes the new icons and slides to its new size.
    func show(_ items: [MenuBarItem], pictures: [String: ItemPicture], below anchor: NSRect?, on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let rowHeight = max(MenuBarStrip.height(of: screen), pictures.values.map(\.size.height).max() ?? 0)
        var row = FloatingBarView(items: items, pictures: pictures, rowHeight: rowHeight)
        row.onClick = { [weak self] item, click in self?.clicked(item, click) }
        show(row, below: anchor, on: screen)
    }

    /// Shows a note instead of icons, the same way. Its button closes the bar, then does what it's for.
    func show(_ note: FloatingBarNote, below anchor: NSRect?, on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        // At least as tall as the button needs, on menu bars thinner than those of MacBooks with a camera housing.
        var row = FloatingBarView(note: note, rowHeight: max(MenuBarStrip.height(of: screen), 28))
        row.onNoteButton = { [weak self] in
            self?.close()
            note.action()
        }
        show(row, below: anchor, on: screen)
    }

    private func show(_ row: FloatingBarView, below anchor: NSRect?, on screen: NSScreen) {
        let menuBarHeight = MenuBarStrip.height(of: screen)
        let panel = self.panel ?? makePanel()
        guard let hostingView else { return }

        let isOpening = !isOpen
        if isOpening {
            // A new session, so no icon starts out highlighted from the last time, and they all come out again.
            session += 1
        }
        var row = row
        row.padding = Self.padding
        row.session = session
        measuringView.rootView = row
        let size = measuringView.fittingSize
        let width = min(size.width, screen.frame.width - 2 * Self.screenMargin)
        let midX = anchor?.midX ?? NSEvent.mouseLocation.x
        let x = min(max(midX - width / 2, screen.frame.minX + Self.screenMargin), screen.frame.maxX - Self.screenMargin - width)
        let y = screen.frame.maxY - menuBarHeight - Self.gap - size.height
        openFrame = NSRect(x: x.rounded(), y: y.rounded(), width: width, height: size.height)
        originX = min(max(midX, openFrame.minX), openFrame.maxX)
        row.origin = (originX - openFrame.minX) / max(openFrame.width, 1)
        hostingView.rootView = row
        hostingView.setFrameSize(NSSize(width: max(size.width, screen.frame.width), height: size.height))
        glass?.cornerRadius = size.height / 2

        if isOpening {
            isOpen = true
            installMonitors()
        }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.setFrame(Self.reducesMotion ? openFrame : collapsedFrame, display: false)
        }
        placeIcons(in: panel.frame)
        panel.orderFrontRegardless()
        animate(to: openFrame, alpha: 1)
    }

    /// Closes the bar: it shrinks back into the spot it grew out of as it fades out.
    func close() {
        guard isOpen else { return }
        isOpen = false
        removeMonitors()
        animate(to: collapsedFrame, alpha: 0)
        onClose?()
    }

    private func clicked(_ item: MenuBarItem, _ click: ItemClick) {
        close()
        onClick?(item, click)
    }

    // MARK: Closing on other clicks

    private func installMonitors() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let elsewhere = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDownOutside() }
        }
        // Clicks in CleanBar's own windows, like its settings.
        let inCleanBar = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel {
                    self.mouseDownOutside()
                }
            }
            return event
        }
        monitors = [elsewhere, inCleanBar].compactMap { $0 }

        let workspace = NSWorkspace.shared.notificationCenter
        let closingNotifications: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.didActivateApplicationNotification),
            (workspace, NSWorkspace.activeSpaceDidChangeNotification),
            (.default, NSApplication.didChangeScreenParametersNotification),
        ]
        observers = closingNotifications.map { center, name in
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
            return (center, observer)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        for (center, observer) in observers {
            center.removeObserver(observer)
        }
        observers = []
    }

    private func mouseDownOutside() {
        if ignoresClick?(NSEvent.mouseLocation) == true { return }
        close()
    }

    // MARK: Opening and closing

    /// A change of the bar's frame and opacity. It's played one screen refresh at a time, rather than by Core Animation,
    /// so the icons can stay put on the screen while the glass grows or shrinks around them.
    private struct Motion {
        let fromFrame: NSRect
        let toFrame: NSRect
        let fromAlpha: CGFloat
        let toAlpha: CGFloat
        /// The first screen refresh it showed on, so it starts smoothly even when opening keeps the app busy for a
        /// moment, as when the icons are first laid out.
        var start: CFTimeInterval?

        var isClosing: Bool { toAlpha == 0 }
    }

    /// Seconds for the bar to fade in as it opens, and to shrink away as it closes.
    private static let fadeInDuration = 0.15
    private static let closeDuration = 0.2
    /// Seconds for the opening spring to settle, within a thousandth of the way.
    private static let settleDuration = 0.5

    private static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The bar as a round drop of glass hanging from the menu bar where it grows out of, as it starts opening and
    /// finishes closing.
    private var collapsedFrame: NSRect {
        let width = min(openFrame.height, openFrame.width)
        let x = min(max(originX - width / 2, openFrame.minX), openFrame.maxX - width)
        return NSRect(x: x, y: openFrame.minY + Self.gap, width: width, height: openFrame.height)
    }

    /// Moves the bar from where it is now, so opening again while it closes turns it around smoothly. With Reduce Motion
    /// on, it only fades: it stays where it is as it closes, and takes its new place at once.
    private func animate(to frame: NSRect, alpha: CGFloat) {
        guard let panel else { return }
        var from = panel.frame
        var to = frame
        if Self.reducesMotion {
            if alpha == 0 {
                to = from
            } else {
                from = to
            }
        }
        motion = Motion(fromFrame: from, toFrame: to, fromAlpha: panel.alphaValue, toAlpha: alpha)
        ticker.start(on: panel.screen)
    }

    /// Shows the bar as it'll be at `time`, a screen refresh that started at `now`.
    private func step(now: CFTimeInterval, at time: CFTimeInterval) {
        guard let panel, let motion else {
            ticker.stop()
            return
        }
        let start = motion.start ?? now
        self.motion?.start = start
        let elapsed = max(time - start, 0)
        let move: Double
        let fade: Double
        let isDone: Bool
        if motion.isClosing {
            let progress = min(elapsed / Self.closeDuration, 1)
            move = progress * progress * (3 - 2 * progress)
            fade = 1 - (1 - progress) * (1 - progress)
            isDone = progress >= 1
        } else {
            move = Self.spring(elapsed)
            fade = 1 - pow(1 - min(elapsed / Self.fadeInDuration, 1), 3)
            isDone = elapsed >= Self.settleDuration
        }
        let frame = isDone ? motion.toFrame : motion.fromFrame.interpolated(to: motion.toFrame, by: move)
        panel.setFrame(frame.onWholePoints, display: true)
        // Windows go on whole points: the frame it got, rather than the one asked for.
        placeIcons(in: panel.frame)
        panel.alphaValue = isDone ? motion.toAlpha : motion.fromAlpha + (motion.toAlpha - motion.fromAlpha) * fade
        // The shadow follows what's drawn.
        panel.invalidateShadow()
        guard isDone else { return }
        self.motion = nil
        ticker.stop()
        if motion.isClosing {
            panel.orderOut(nil)
        } else {
            // The glass settles a moment after its last change.
            DispatchQueue.main.async { panel.invalidateShadow() }
        }
    }

    /// How far along the opening spring is after `time` seconds: slightly past the end for a moment, like SwiftUI's
    /// `.spring(response: 0.34, dampingFraction: 0.78)`.
    private static func spring(_ time: Double) -> Double {
        let response = 0.34
        let damping = 0.78
        let stiffness = 2 * Double.pi / response
        let decay = damping * stiffness
        let frequency = stiffness * (1 - damping * damping).squareRoot()
        return 1 - exp(-decay * time) * (cos(frequency * time) + decay / frequency * sin(frequency * time))
    }

    /// Keeps the icons where they are once the bar is open, centered in it, whatever the glass around them does. The
    /// icons are centered in a view wider than the bar, so they can slide when icons come or go while it's open.
    private func placeIcons(in frame: NSRect) {
        guard let hostingView else { return }
        let x = openFrame.midX - hostingView.frame.width / 2 - frame.minX
        let scale = panel?.screen?.backingScaleFactor ?? 2
        hostingView.setFrameOrigin(NSPoint(x: (x * scale).rounded() / scale, y: 0))
    }

    // MARK: The window

    private func makePanel() -> NSPanel {
        // Over other apps' windows, below the menu bar's own menus.
        let panel = NonactivatingPanel(title: title, level: .statusBar)
        let hostingView = NSHostingView(rootView: FloatingBarView())
        // The bar is sized and placed by hand, and the icons stay put while it opens and closes.
        hostingView.sizingOptions = []
        // The icons only show within the bar as it grows and shrinks.
        let clipView = NSView()
        clipView.clipsToBounds = true
        clipView.addSubview(hostingView)
        let glass = NSGlassEffectView()
        glass.contentView = clipView
        glass.effectIsInteractive = true
        panel.contentView = glass
        self.panel = panel
        self.glass = glass
        self.hostingView = hostingView
        return panel
    }
}

/// A panel that floats over other apps' windows without taking the keyboard or making CleanBar the active app, so the app
/// in front keeps both: the floating bar, and the panel that helps allow a permission.
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

private extension NSRect {
    /// Part of the way to `other`, or past it when `progress` is over 1.
    func interpolated(to other: NSRect, by progress: Double) -> NSRect {
        let t = CGFloat(progress)
        return NSRect(
            x: minX + (other.minX - minX) * t,
            y: minY + (other.minY - minY) * t,
            width: width + (other.width - width) * t,
            height: height + (other.height - height) * t
        )
    }

    /// With its edges on whole points, where windows go. The height stays as it is, which keeps the ends round.
    var onWholePoints: NSRect {
        let left = minX.rounded()
        return NSRect(x: left, y: minY.rounded(), width: maxX.rounded() - left, height: height)
    }
}

/// A note the floating bar can show instead of icons, with a button.
struct FloatingBarNote {
    /// Its badge: a white symbol on a square of `tint`, like the panes of CleanBar's settings.
    let symbol: String
    let tint: Color
    let text: String
    /// Says more when the pointer rests on the note.
    let detail: String
    let buttonTitle: String
    /// What the button does, once the bar has closed.
    let action: () -> Void
}

/// The icons in a row, as the menu bar shows them, or a note.
private struct FloatingBarView: View {
    var items: [MenuBarItem] = []
    var pictures: [String: ItemPicture] = [:]
    var note: FloatingBarNote?
    var rowHeight: CGFloat = 24
    var padding = NSEdgeInsets()
    var session = 0
    /// Where across the bar it grows out of, from 0 at its left end to 1 at its right end.
    var origin: CGFloat = 0.5
    var onClick: (MenuBarItem, ItemClick) -> Void = { _, _ in }
    var onNoteButton: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            if let note {
                FloatingBarNoteRow(note: note, rowHeight: rowHeight, onButton: onNoteButton)
                    .modifier(ComingOut(delay: 0.05))
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    FloatingBarIcon(item: item, picture: pictures[item.id], rowHeight: rowHeight) { click in
                        onClick(item, click)
                    }
                    .modifier(ComingOut(delay: delay(forIconAt: index)))
                }
                if items.isEmpty {
                    Text("No hidden icons right now")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .modifier(ComingOut(delay: 0.05))
                }
            }
        }
        .frame(height: rowHeight)
        .padding(EdgeInsets(top: padding.top, leading: padding.left, bottom: padding.bottom, trailing: padding.right))
        .fixedSize()
        // Centered in the view it's in, which is wider than the bar. Icons that come or go while the bar is open make
        // the others slide over, along with the bar's ends.
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.78), value: items.map(\.id))
        .id(session)
    }

    /// The icons come out a moment apart, from the one nearest where the bar grows out of to those at its ends, about
    /// as the glass reaches them.
    private func delay(forIconAt index: Int) -> Double {
        let iconsAway = abs(Double(index) + 0.5 - Double(origin) * Double(items.count))
        return 0.015 + 0.03 * iconsAway
    }
}

/// Brings an icon out as the bar opens, `delay` seconds in: it fades in, grows to its size and comes into focus. Icons
/// that turn up while the bar is open come out the same way.
private struct ComingOut: ViewModifier {
    let delay: Double
    @State private var isOut = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isOut ? 1 : 0)
            .scaleEffect(isOut || reduceMotion ? 1 : 0.6)
            .blur(radius: isOut || reduceMotion ? 0 : 3)
            .onAppear {
                let animation: Animation = reduceMotion
                    ? .easeOut(duration: 0.15)
                    : .spring(response: 0.32, dampingFraction: 0.72).delay(delay)
                withAnimation(animation) {
                    isOut = true
                }
            }
    }
}

private struct FloatingBarIcon: View {
    let item: MenuBarItem
    let picture: ItemPicture?
    let rowHeight: CGFloat
    let onClick: (ItemClick) -> Void
    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        MenuBarItemImage(item: item, picture: picture, isTrimmed: true)
            .padding(.horizontal, IconTile.padding)
            .frame(height: rowHeight)
            .background {
                HoverHighlight(isOn: isHovered, isPressed: isPressed)
                    .padding(.vertical, 4)
            }
            .overlay {
                ClickArea(name: item.displayName, isHovered: $isHovered, isPressed: $isPressed, onClick: onClick)
            }
    }
}

/// A note's badge, text and button, in a row as tall as the menu bar. The badge is as far from the bar's left end as
/// from its top and bottom, and the button's ends are concentric with the bar's right end, like the icons' highlights.
private struct FloatingBarNoteRow: View {
    let note: FloatingBarNote
    let rowHeight: CGFloat
    let onButton: () -> Void
    @State private var isHovered = false
    @State private var isPressed = false

    private static let badgeSize: CGFloat = 20

    var body: some View {
        HStack(spacing: 8) {
            SymbolBadge(symbol: note.symbol, tint: note.tint, size: Self.badgeSize)
            Text(note.text)
                .fixedSize()
                .help(note.detail)
            Text(note.buttonTitle)
                .padding(.horizontal, 10)
                .frame(height: rowHeight - 8)
                .background {
                    Capsule()
                        .fill(isPressed ? .secondary : isHovered ? .tertiary : .quaternary)
                        .animation(.easeOut(duration: 0.12), value: isHovered)
                }
                .overlay {
                    ClickArea(name: note.buttonTitle, isHovered: $isHovered, isPressed: $isPressed) { click in
                        if !click.isRightClick {
                            onButton()
                        }
                    }
                }
                .padding(.leading, 2)
        }
        .font(.callout)
        // The bar's padding is 4 points wider at its ends than at its top and bottom.
        .padding(.leading, (rowHeight - Self.badgeSize) / 2 - 4)
        .frame(height: rowHeight)
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
