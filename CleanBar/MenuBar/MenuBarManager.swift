import AppKit

/// Shows and hides other apps' menu bar icons, and macOS's own.
///
/// The icons the user picks (`AppSettings.hiddenIcons`) are hidden with macOS 27's menu bar allowlist (`IconHider`):
/// CleanBar lists every running app and every one of macOS's own icons except those, and macOS takes the other icons
/// out of the menu bar without leaving a gap. Clicking CleanBar's icon lifts the list, so the hidden icons come back
/// where they were, one after another, or, in the other style, shows them in the floating bar below CleanBar's icon while
/// they stay out of the menu bar. Hovering over or clicking empty space in the menu bar can do the same, which is how
/// they show when CleanBar's icon is hidden. An app missing from the list would be hidden too, so the list is rebuilt
/// whenever an app launches.
final class MenuBarManager: NSObject {
    let settings: AppSettings
    let layout = LayoutModel()

    private let icon = ControlItem(role: .icon)
    private let hider = IconHider()
    private let floatingBar = FloatingBar()
    /// Says to close Settings when the hidden icons are shown or hidden while the layout editor is open.
    private let editingNote = FloatingBar(title: String(localized: "Settings Open"))
    private var editingNoteTask: Task<Void, Never>?
    private let iconMemory = IconMemory()
    private lazy var settingsWindow = SettingsWindowController(manager: self)

    private static let clockIdentifier = SystemMenuItem.clock.identifier

    /// Set while the user has asked to see the hidden icons in the menu bar.
    private var isShowingHidden = false
    /// The style the menu bar was last set up for, to notice when it changes.
    private var hiddenIconsStyle: HiddenIconsStyle
    private var floatingBarTask: Task<Void, Never>?
    /// Where the floating bar is: below CleanBar's icon, below the pointer, or at the right end of the menu bar.
    private var floatingBarAnchor: NSRect?
    private var floatingBarScreen: NSScreen?
    /// Hidden icons let back into the menu bar from the floating bar, while their menu is open.
    private var revealedIcons = HiddenIcons()
    /// Set while an icon of an app macOS doesn't recognize is open from the floating bar. Its icons only come back
    /// with all the hidden ones.
    private var isRevealingAll = false
    private var revealTask: Task<Void, Never>?
    /// Changes whenever an icon is opened from the floating bar or has to hide again, so the one before hides.
    private var revealGeneration = 0
    /// Hidden icons let into the menu bar for a moment so CleanBar can picture them for the floating bar.
    private var iconsBeingPictured = HiddenIcons()
    /// Apps that opened with hidden icons CleanBar has never seen, in the order they opened.
    private var appsToPicture: [String] = []
    private var picturingTask: Task<Void, Never>?
    /// Set while the layout editor is open. It opens with every icon shown, so they can be seen and moved.
    private var isEditingLayout = false
    /// Set for the few hundredths of a second hiding pauses so Notification Center can open.
    private var isPausedForNotificationCenter = false
    private var notificationCenterTask: Task<Void, Never>?
    /// Takes clicks on the clock from the menu bar while icons are hidden, so CleanBar can open Notification Center.
    private lazy var clockTap = ClockClickTap { [weak self] in
        Task { @MainActor in self?.clockClicked() }
    }
    /// The list to hide with again once the clock is pressed, made ready before hiding pauses.
    private var listAfterNotificationCenter: IconHider.PreparedList?
    private var updateTask: Task<Void, Never>?
    /// Changes with every update asked for, so hidden icons coming or going one after another stop for a newer one.
    private var updateGeneration = 0
    /// Set while hidden icons come or go one after another.
    private var isSteppingIcons = false
    /// Where hidden icons showing in the menu bar unfold from and fold back into: the empty menu bar space that showed
    /// them. Nil when CleanBar's icon or the shortcut did.
    private var unfoldPoint: NSPoint?
    private var watchdogTask: Task<Void, Never>?
    private var autoHideTask: Task<Void, Never>?
    private var eventMonitors: [Any] = []
    /// Watch the pointer while hovering over empty menu bar space shows the hidden icons.
    private var pointerMonitors: [Any] = []
    private var hoverTask: Task<Void, Never>?
    /// Set while the hidden icons show because the pointer rested on empty menu bar space. They go again once it leaves.
    private var isShownByHover = false
    private var runningAppsObservation: NSKeyValueObservation?
    private var registeredHotKey: HotKeyCombo?
    /// Where macOS's clock is, to notice clicks on it while icons are hidden.
    private var clockFrame: CGRect?
    /// Apps known to have menu bar items. Checked on every scan; all apps are rescanned now and then.
    private var extrasPIDs: Set<pid_t> = []
    private var lastFullScan = Date.distantPast
    /// New apps whose icons still have to go where the "New icons appear here" marker is.
    private var unplacedApps: Set<String> = []
    private var placementTask: Task<Void, Never>?
    private var placementDeadline = Date.distantPast
    /// Set while CleanBar drags a new icon into place.
    private(set) var isPlacingNewIcons = false

    init(settings: AppSettings) {
        self.settings = settings
        hiddenIconsStyle = settings.hiddenIconsStyle
        super.init()
    }

    func start() {
        icon.onClick = { [weak self] event in self?.iconClicked(event: event) }
        floatingBar.onClick = { [weak self] item, click in self?.reveal(item, click: click) }
        floatingBar.onClose = { [weak self] in self?.floatingBarClosed() }
        floatingBar.ignoresClick = { [weak self] location in self?.togglesFloatingBar(at: location) ?? false }
        editingNote.ignoresClick = { [weak self] location in self?.togglesFloatingBar(at: location) ?? false }
        layout.manager = self
        applyIconSettings()
        installEventMonitors()
        startClockTap()
        updatePointerMonitors()
        observeSystem()
        registerHotKey()
        noteNewApps()
        if settings.hiddenIconsStyle == .floatingBar {
            // Until CleanBar hides them, the hidden icons are still in the menu bar: a last look at them for the
            // floating bar.
            updateTask = Task { [weak self] in await self?.rememberMenuBar() }
        }
        requestUpdate()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkHiding()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func showSettings(tab: SettingsTab) {
        settingsWindow.show(tab: tab)
    }

    // MARK: Hiding

    /// Hiding needs macOS's allowlist, and CleanBar running from /Applications: anywhere else macOS can't recognize
    /// CleanBar's own icon and would hide it too, leaving no way to show the others again.
    private static var canHide: Bool { IconHider.isAvailable && IconHider.isCleanBarRecognized }

    /// Whether the hidden icons should be out of the menu bar right now. CleanBar's icon hides them while the layout
    /// editor is open too.
    private var shouldHide: Bool {
        Self.canHide && !settings.hiddenIcons.isEmpty && !isShowingHidden && !isPausedForNotificationCenter && !isRevealingAll
    }

    /// The icons to keep out of the menu bar: the hidden ones, except one opened from the floating bar or being pictured.
    private var iconsToHide: HiddenIcons {
        settings.hiddenIcons.subtracting(revealedIcons).subtracting(iconsBeingPictured)
    }

    /// Brings the menu bar in line with the current state. Updates run one after another. `animated`: the hidden icons
    /// come or go one after another (`stepHiddenIcons`), as when CleanBar's icon shows or hides them.
    private func requestUpdate(force: Bool = false, animated: Bool = false) {
        updateGeneration += 1
        let generation = updateGeneration
        let previous = updateTask
        updateTask = Task { [weak self] in
            await previous?.value
            await self?.update(force: force, animated: animated, generation: generation)
        }
    }

    private func update(force: Bool, animated: Bool = false, generation: Int = 0) async {
        defer {
            updateIcon()
            updateClockTap()
        }
        guard shouldHide else {
            if animated, hider.isActive {
                await stepHiddenIcons(showing: true, generation: generation)
                // A newer update takes over from where this one got to.
                guard updateGeneration == generation else { return }
            }
            hider.lift()
            return
        }
        let hidden = iconsToHide
        let (allowed, systemItems) = allowList(hiding: hidden)
        // Apps that quit can stay in the list; only a missing app, a newly hidden one or a change to macOS's icons
        // needs a new list.
        if !force, let current = hider.allowedBundleIDs, current.isSuperset(of: allowed),
           current.isDisjoint(with: hidden.bundleIDs), hider.allowedSystemItems == systemItems {
            return
        }
        if animated {
            await stepHiddenIcons(showing: false, generation: generation)
            guard updateGeneration == generation else { return }
        }
        await hider.allow(only: allowed, systemItems: systemItems)
    }

    /// CleanBar's icon is filled while hidden icons are showing: back in the menu bar, or in the floating bar. Not for
    /// the moment they show so Notification Center can open.
    private func updateIcon() {
        let isShowingInMenuBar = !hider.isActive && !settings.hiddenIcons.isEmpty && !isPausedForNotificationCenter
        icon.setShowsHiddenIcons(floatingBar.isOpen || isShowingInMenuBar)
    }

    /// macOS's list for hiding `hidden`: the apps and macOS's own icons to allow.
    private func allowList(hiding hidden: HiddenIcons) -> (bundleIDs: Set<String>, systemItems: Set<SystemMenuItem>) {
        (allowedBundleIDs(hiding: hidden.bundleIDs), Set(SystemMenuItem.allCases).subtracting(hidden.systemItems))
    }

    /// Every running app except the hidden ones. Apps that start later are added when they launch.
    private func allowedBundleIDs(hiding hidden: Set<String>) -> Set<String> {
        var ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        ids.subtract(hidden)
        if let own = Bundle.main.bundleIdentifier {
            ids.insert(own)
        }
        return ids
    }

    /// Shows the hidden icons in place, or hides them again. `animated`: one after another, when the user asked for it.
    private func setShowingHidden(_ showing: Bool, animated: Bool = false) {
        isShowingHidden = showing
        if showing {
            scheduleAutoHide()
            placeNewIconsSoon()
        } else {
            autoHideTask?.cancel()
        }
        requestUpdate(animated: animated)
    }

    /// Apps CleanBar hasn't seen before are new, and their icons go where the layout editor's "New icons appear here"
    /// marker is. Hidden, they're left out of macOS's list from the start, so while CleanBar hides icons they don't
    /// show up first. macOS's own icons and CleanBar's are never new.
    private func noteNewApps() {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let new = settings.noteSeenApps(running)
            .filter { $0 != Bundle.main.bundleIdentifier && !MenuBarItem.systemBundleIDs.contains($0) }
        guard !new.isEmpty else { return }
        if settings.hidesNewIcons {
            settings.hiddenBundleIDs.formUnion(new)
        }
        if settings.newIconsPlace != nil {
            unplacedApps.formUnion(new)
            placeNewIconsSoon()
        }
    }

    /// macOS's own icons hide one by one. Other apps' icons hide per app, so this hides or shows all of the item's
    /// app's icons.
    func setHidden(_ hidden: Bool, item: MenuBarItem) {
        if let systemItem = item.systemItem {
            if hidden {
                settings.hiddenSystemItems.insert(systemItem)
            } else {
                settings.hiddenSystemItems.remove(systemItem)
            }
        } else if let bundleID = item.bundleID {
            if hidden {
                settings.hiddenBundleIDs.insert(bundleID)
            } else {
                settings.hiddenBundleIDs.remove(bundleID)
            }
        }
    }

    /// Runs every few seconds. Keeps the clock's position current, and puts the list back if macOS dropped it, which
    /// shows as hidden icons being drawn again (for example after the menu bar process restarted).
    private func checkHiding() async {
        guard Permissions.accessibilityGranted else { return }
        let clock = Self.clockIdentifier
        clockFrame = await Task.detached { MenuBarScanner.systemItemFrame(clock) }.value
        // The tap needs the Accessibility permission, which can come after CleanBar started.
        startClockTap()
        updateClockTap()

        // Icons going one after another are still on screen for a moment.
        guard hider.isActive, shouldHide, !isSteppingIcons else { return }
        let generation = updateGeneration
        let hidden = iconsToHide
        // macOS's own icons belong to its menu bar process.
        let targets = ScanTarget.runningApps.filter { target in
            guard let bundleID = target.bundleID else { return false }
            return hidden.bundleIDs.contains(bundleID)
                || (bundleID == MenuBarScanner.menuBarAgentBundleID && !hidden.systemItems.isEmpty)
        }
        guard !targets.isEmpty else { return }
        let scan = await scan(targets)
        // Not when the menu bar changed meanwhile.
        if updateGeneration == generation, !isSteppingIcons, scan.items.contains(where: { $0.isOnScreen && hidden.contains($0) }) {
            requestUpdate(force: true)
        }
    }

    /// Hidden icons that are showing go again after a while: out of the menu bar, or the floating bar closes. The
    /// layout editor keeps them showing until it closes, or until CleanBar's icon hides them.
    private func scheduleAutoHide(after delay: TimeInterval? = nil) {
        autoHideTask?.cancel()
        guard settings.autoHide, isShowingHidden || floatingBar.isOpen, !isEditingLayout else { return }
        let delay = delay ?? settings.autoHideDelay
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.isShowingHidden || self.floatingBar.isOpen, !self.isEditingLayout
            else { return }
            // The floating bar waits only while the pointer is over it: its icons aren't in the menu bar, and the pointer
            // often rests there after opening it, which would keep the bar open for good. Icons back in the menu bar
            // wait while the pointer is in the menu bar, one of them has a menu open, or a new icon is being moved into
            // place.
            let isInUse = self.floatingBar.isOpen
                ? self.floatingBar.containsMouse
                : self.isMouseInMenuBar || WindowInfo.isMenuOpen() || self.isPlacingNewIcons
            if isInUse {
                self.scheduleAutoHide(after: 1)
                return
            }
            if self.floatingBar.isOpen {
                self.floatingBar.close()
            } else {
                self.setShowingHidden(false, animated: true)
            }
        }
    }

    // MARK: One icon after another

    /// Shows the hidden icons in the menu bar one after another, nearest first, or hides them one after another,
    /// farthest first, so they unfold from CleanBar's icon (or the empty menu bar space that showed them) and fold back
    /// into it, instead of all coming or going at once. macOS animates each change: the icon fades in or out while the
    /// others slide over. Each step adds one app, or one of macOS's own icons, to macOS's list or takes it out, 60 ms
    /// apart, or less when there are more than six, so it's over within 0.4 s. A newer update stops it, and starts from
    /// where it got to. The caller makes the last change, which also brings or takes the icons CleanBar hasn't seen yet,
    /// and those of apps macOS doesn't recognize.
    private func stepHiddenIcons(showing: Bool, generation: Int) async {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let hidden = settings.hiddenIcons
        let listedApps = hider.allowedBundleIDs
        let listedSystemItems = hider.allowedSystemItems
        // Without a list, every icon is in the menu bar.
        let isShown = { (icons: HiddenIcons) -> Bool in
            guard let listedApps, let listedSystemItems else { return true }
            return icons.bundleIDs.isSubset(of: listedApps) && icons.systemItems.isSubset(of: listedSystemItems)
        }
        let known = iconMemory.items(of: ScanTarget.runningApps).filter { item in
            item.canBeHidden && item.isRecognizedByMacOS && hidden.contains(item) && !iconMemory.isTurnedOff(item)
        }
        let origin = unfoldPoint?.x ?? (icon.isVisible ? icon.frameOnScreen?.midX : nil) ?? NSEvent.mouseLocation.x
        let steps = Self.unfoldingSteps(of: known, from: origin, showing: showing, isShown: isShown)
        // A single one comes or goes with the caller's change.
        guard steps.count > 1 else { return }

        icon.setShowsHiddenIcons(showing)
        isSteppingIcons = true
        defer { isSteppingIcons = false }
        let apps = allowedBundleIDs(hiding: hidden.bundleIDs)
        let systemItems = Set(SystemMenuItem.allCases).subtracting(hidden.systemItems)
        var shown = known.map { HiddenIcons($0) }.filter(isShown).reduce(HiddenIcons()) { $0.union($1) }
        let pause = min(0.06, 0.4 / Double(steps.count))
        for icons in steps {
            guard updateGeneration == generation else { return }
            let start = Date.now
            shown = showing ? shown.union(icons) : shown.subtracting(icons)
            await hider.allow(only: apps.union(shown.bundleIDs), systemItems: systemItems.union(shown.systemItems))
            let rest = pause - Date.now.timeIntervalSince(start)
            if rest > 0 {
                try? await Task.sleep(for: .seconds(rest))
            }
        }
    }

    /// The order hidden icons come in, one app or macOS icon per step: nearest `origin` first, an app going by its
    /// nearest icon. They go in the opposite order. Leaves out those already in the menu bar (`isShown`) when they come,
    /// and those already out when they go.
    private static func unfoldingSteps(
        of items: [MenuBarItem], from origin: CGFloat, showing: Bool, isShown: (HiddenIcons) -> Bool
    ) -> [HiddenIcons] {
        var nearest: [String: (icons: HiddenIcons, distance: CGFloat)] = [:]
        for item in items {
            let key = item.systemItem?.identifier ?? item.bundleID ?? item.id
            let distance = abs(item.frame.midX - origin)
            if distance < nearest[key]?.distance ?? .infinity {
                nearest[key] = (HiddenIcons(item), distance)
            }
        }
        let nearestFirst = nearest
            .filter { isShown($0.value.icons) != showing }
            // By name too, so icons as far away as each other keep an order.
            .sorted { ($0.value.distance, $0.key) < ($1.value.distance, $1.key) }
            .map(\.value.icons)
        return showing ? nearestFirst : nearestFirst.reversed()
    }

    // MARK: Reading the menu bar

    /// Reads the menu bar items of these apps, off the main thread.
    private func scan(_ targets: [ScanTarget]) async -> MenuBarScan {
        let strips = MenuBarStrip.all()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return await Task.detached { MenuBarScanner.scan(targets, strips: strips, ownPID: ownPID) }.value
    }

    private func scanItems(full: Bool = false) async -> MenuBarScan {
        guard Permissions.accessibilityGranted else { return MenuBarScan(items: [], overflowButton: nil) }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let isFull = full || extrasPIDs.isEmpty || Date.now.timeIntervalSince(lastFullScan) > 20
        var targets = ScanTarget.runningApps
        if !isFull {
            targets = targets.filter { extrasPIDs.contains($0.pid) }
        }
        let scan = await scan(targets)
        if isFull {
            extrasPIDs = Set(scan.items.map(\.pid))
            extrasPIDs.insert(ownPID)
            if let agent = NSRunningApplication.runningApplications(withBundleIdentifier: MenuBarScanner.menuBarAgentBundleID).first {
                extrasPIDs.insert(agent.processIdentifier)
            }
            lastFullScan = .now
        }
        return scan
    }

    func captureLayout(includePictures: Bool, reusing previousPictures: [String: ItemPicture]) async -> LayoutSnapshot {
        var scan = await scanItems(full: true)
        if await showIconsBehindOverflowButton(in: scan) {
            scan = await scanItems()
        }
        var pictures = previousPictures
        if includePictures {
            pictures.merge(await ItemImageCapture.pictures(for: scan.items)) { _, new in new }
        }
        iconMemory.remember(scan, pictures: pictures, isFullMenuBar: !hider.isActive)
        return LayoutSnapshot(scan: scan, hiddenIcons: settings.hiddenIcons, pictures: pictures)
    }

    /// Remembers every icon in the menu bar, with pictures, for the floating bar. Only while nothing is hidden.
    ///
    /// As CleanBar starts, its own icon comes into the menu bar a moment later and the icons left of it slide over, so
    /// this waits for it first. Icons that still moved while they were pictured (such as hidden icons still coming back
    /// when CleanBar was quit and opened again straight away) are read and pictured once more.
    private func rememberMenuBar() async {
        guard Permissions.accessibilityGranted, !hider.isActive else { return }
        await waitUntilIconIsInMenuBar()
        var scan = await scanItems(full: true)
        var pictures = await ItemImageCapture.pictures(for: scan.items)
        let missing = scan.items.filter { item in
            item.controlRole == nil && item.strip != nil && pictures[item.id] == nil && !scan.isBehindOverflowButton(item)
        }
        if !missing.isEmpty {
            let pids = Set(missing.map(\.pid))
            let again = await self.scan(ScanTarget.runningApps.filter { pids.contains($0.pid) })
            pictures.merge(await ItemImageCapture.pictures(for: again.items)) { _, new in new }
            scan.items = (scan.items.filter { !pids.contains($0.pid) } + again.items).sorted { $0.frame.minX < $1.frame.minX }
            scan.overflowButton = again.overflowButton ?? scan.overflowButton
        }
        iconMemory.remember(scan, pictures: pictures, isFullMenuBar: true)
    }

    /// Waits up to two seconds for CleanBar's icon to be drawn in the menu bar. It isn't when the user hid it, or when
    /// it's behind Apple's «.
    private func waitUntilIconIsInMenuBar() async {
        guard icon.isVisible else { return }
        let own = [ScanTarget(NSRunningApplication.current)]
        let start = Date.now
        while Date.now.timeIntervalSince(start) < 2 {
            if await scan(own).items.contains(where: { $0.controlRole == .icon && $0.isOnScreen }) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: Picturing new hidden icons

    /// The floating bar shows hidden icons from pictures taken while they were in the menu bar. An app that opens while
    /// CleanBar hides its icons never was, so the first time, its icons come into the menu bar for a moment to be
    /// pictured, and hide again. Not for apps CleanBar can't let in on their own (running from elsewhere than
    /// /Applications), nor in the other style, which doesn't show pictures.
    private func pictureIconsSoon(of bundleIDs: [String]) {
        guard settings.hiddenIconsStyle == .floatingBar, Self.canHide else { return }
        let running = NSWorkspace.shared.runningApplications
        let unseen = bundleIDs.filter { bundleID in
            settings.hiddenBundleIDs.contains(bundleID) && !appsToPicture.contains(bundleID)
                && !iconMemory.knowsIcons(ofApp: bundleID)
                && running.contains { $0.bundleIdentifier == bundleID && IconHider.isRecognized(appPath: $0.bundleURL?.path) }
        }
        appsToPicture += unseen
        guard !appsToPicture.isEmpty, picturingTask == nil else { return }
        picturingTask = Task { [weak self] in
            while let self, !self.appsToPicture.isEmpty {
                await self.pictureIcons(of: self.appsToPicture.removeFirst())
            }
            self?.picturingTask = nil
        }
    }

    /// Waits for the app to add its icons, if it has any: they turn up out of the menu bar, not drawn. Then lets them
    /// in until they're drawn and pictured. Icons macOS doesn't draw even then are turned off in System Settings, and are
    /// remembered that way, so the floating bar leaves them out. Icons behind Apple's « can't be pictured; they will be
    /// once opened from the floating bar.
    private func pictureIcons(of bundleID: String) async {
        let appTargets = { ScanTarget.runningApps.filter { $0.bundleID == bundleID } }
        var hasIcons = false
        let start = Date.now
        while !hasIcons, Date.now.timeIntervalSince(start) < 15 {
            try? await Task.sleep(for: .milliseconds(500))
            let targets = appTargets()
            // It quit.
            guard !targets.isEmpty else { return }
            hasIcons = !(await scan(targets).items.isEmpty)
        }
        // The user may have shown the app's icons meanwhile, or CleanBar may have seen them in the layout editor.
        guard hasIcons, await Task.detached(operation: { Permissions.screenRecordingGranted }).value,
              await waitUntilFreeToPicture(), settings.hiddenBundleIDs.contains(bundleID),
              !iconMemory.knowsIcons(ofApp: bundleID)
        else { return }

        iconsBeingPictured = HiddenIcons(bundleIDs: [bundleID])
        requestUpdate()
        await updateTask?.value
        let targets = appTargets() + ScanTarget.runningApps.filter { $0.bundleID == MenuBarScanner.menuBarAgentBundleID }
        let shownAt = Date.now
        var appItems: [MenuBarItem] = []
        // macOS draws them within a few tenths of a second, unless they don't fit.
        while Date.now.timeIntervalSince(shownAt) < 2, !isEditingLayout {
            try? await Task.sleep(for: .milliseconds(100))
            let latest = await scan(targets)
            appItems = latest.items.filter { $0.bundleID == bundleID }
            if appItems.contains(where: \.isOnScreen)
                || (Date.now.timeIntervalSince(shownAt) > 0.5 && appItems.contains(where: latest.isBehindOverflowButton)) {
                break
            }
        }
        let drawn = appItems.filter(\.isOnScreen)
        if !drawn.isEmpty {
            let pictures = await ItemImageCapture.pictures(for: drawn)
            iconMemory.remember(MenuBarScan(items: drawn, overflowButton: nil), pictures: pictures, isFullMenuBar: false)
        } else if !isEditingLayout {
            iconMemory.rememberTurnedOff(appItems.filter { $0.strip == nil })
        }
        iconsBeingPictured = HiddenIcons()
        requestUpdate()
        await updateTask?.value
    }

    /// Waits until nothing else is using the menu bar: an icon open from the floating bar, hidden icons coming or going,
    /// a new icon being moved into place, or Notification Center opening. False after half a minute, or when the layout
    /// editor opens: it shows every icon and pictures them itself.
    private func waitUntilFreeToPicture() async -> Bool {
        let start = Date.now
        while !isEditingLayout, Date.now.timeIntervalSince(start) < 30 {
            if !isRevealing, !isSteppingIcons, !isPlacingNewIcons, notificationCenterTask == nil { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    // MARK: Placing new icons

    private enum Side {
        case left, right
    }

    /// Keeps trying to move new apps' icons into place for a minute. An icon can only be moved while it's in the menu
    /// bar: after its app starts, or, for new icons that go to Hidden, while hidden icons are showing.
    private func placeNewIconsSoon() {
        guard !unplacedApps.isEmpty else { return }
        placementDeadline = .now + 60
        guard placementTask == nil else { return }
        placementTask = Task { [weak self] in
            while let self, !self.unplacedApps.isEmpty, Date.now < self.placementDeadline {
                try? await Task.sleep(for: .seconds(1))
                await self.placeNewIcons()
            }
            self?.placementTask = nil
        }
    }

    /// Moves new apps' icons in front of the item the marker is in front of, or after the last icon of the marker's
    /// row. That's a ⌘-drag (with the pointer hidden, see `ItemMover`), so it waits until the mouse and keyboard have been
    /// left alone for a moment.
    private func placeNewIcons() async {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        unplacedApps.formIntersection(running)
        guard let place = settings.newIconsPlace else {
            unplacedApps.removeAll()
            return
        }
        // Hidden icons can't be moved while they're out of the menu bar, nor while one is open from the floating bar or
        // being pictured.
        guard !unplacedApps.isEmpty, !(hider.isActive && settings.hidesNewIcons), Permissions.accessibilityGranted,
              Self.isUserIdle, !WindowInfo.isMenuOpen(), !isPlacingNewIcons, !layout.isWorking, !isRevealing,
              iconsBeingPictured.isEmpty
        else { return }

        // A quick look at the new apps first: most of them have no icon.
        let pending = unplacedApps
        let targets = ScanTarget.runningApps.filter { $0.bundleID.map(pending.contains) ?? false }
        let quickScan = await scan(targets)
        let ready = Set(quickScan.items.filter { $0.strip != nil }.compactMap(\.bundleID))
        guard !ready.isEmpty, !layout.isWorking, !isPlacingNewIcons else { return }

        isPlacingNewIcons = true
        for bundleID in ready.sorted() {
            if await placeIcons(of: bundleID, at: place) {
                unplacedApps.remove(bundleID)
            }
        }
        isPlacingNewIcons = false
        // Reading the menu bar would bring back icons hidden with CleanBar's icon.
        if isEditingLayout, isShowingHidden {
            await layout.refresh()
        }
    }

    /// Moves the app's icons into place, keeping their order. An icon behind Apple's « is dragged out of it: clicking «
    /// shows it in place of the app menus, and the drag closes « again. While the layout editor is open, « stays open
    /// until the editor closes. Returns false to try again later, when an icon isn't drawn yet.
    private func placeIcons(of bundleID: String, at place: NewIconsPlace) async -> Bool {
        var scan = await scanItems(full: true)
        let ids = scan.items.filter { $0.bundleID == bundleID && $0.strip != nil }.map(\.id)
        var previous: String?
        var isDone = true
        var didOpenOverflow = false
        icons: for id in ids {
            var drags = 0
            var openedOverflow = false
            while drags < 3 {
                guard let item = scan.items.first(where: { $0.id == id }), item.strip != nil,
                      let (neighbor, side) = neighbor(for: item, at: place, after: previous, in: scan)
                else { break }
                if Self.isPlaced(item, side, of: neighbor, in: scan) { break }
                if !item.isOnScreen {
                    guard scan.isBehindOverflowButton(item) else {
                        isDone = false
                        break icons
                    }
                    // Give up when « didn't bring it out, rather than clicking « over and over.
                    guard !openedOverflow, await clickOverflowButton() else { break icons }
                    openedOverflow = true
                    didOpenOverflow = true
                    try? await Task.sleep(for: .milliseconds(700))
                    scan = await scanItems()
                    continue
                }
                await ItemMover.drag(from: item.center, to: side == .left ? .leftOf(neighbor.frame) : .rightOf(neighbor.frame))
                drags += 1
                openedOverflow = false
                try? await Task.sleep(for: .milliseconds(400))
                scan = await scanItems()
            }
            previous = id
        }
        if didOpenOverflow, !isEditingLayout {
            await closeOverflow()
        }
        return isDone
    }

    /// Where the item goes: in front of the marker's item (the row's first, when the marker is at its start), or else
    /// after the app's icon placed before it, or after the last icon of the marker's row, which comes before the clock
    /// and Control Center: macOS keeps those at the end. Nil when the item is no longer in the marker's row, or the row
    /// is empty.
    private func neighbor(
        for item: MenuBarItem, at place: NewIconsPlace, after previousID: String?, in scan: MenuBarScan
    ) -> (MenuBarItem, Side)? {
        let hidden = settings.hiddenIcons
        let hidesNew = settings.hidesNewIcons
        guard hidden.contains(item) == hidesNew else { return nil }
        let row = scan.items.filter {
            $0.isOnScreen && $0.strip == item.strip && $0.bundleID != item.bundleID && hidden.contains($0) == hidesNew
        }
        if let anchor = place.anchor(in: row) {
            return (anchor, .left)
        }
        if let previous = scan.items.first(where: { $0.id == previousID && $0.isOnScreen }) {
            return (previous, .right)
        }
        return row.last { ![.clock, .controlCenter].contains($0.systemItem) }.map { ($0, .right) }
    }

    /// Whether the item is drawn right next to the neighbor, on that side of it.
    private static func isPlaced(_ item: MenuBarItem, _ side: Side, of neighbor: MenuBarItem, in scan: MenuBarScan) -> Bool {
        let drawn = scan.items.filter { $0.isOnScreen && $0.strip == item.strip }
        guard let index = drawn.firstIndex(where: { $0.id == item.id }),
              let neighborIndex = drawn.firstIndex(where: { $0.id == neighbor.id })
        else { return false }
        return side == .left ? index + 1 == neighborIndex : neighborIndex + 1 == index
    }

    /// Clicks Apple's «, read just before and hit-tested, so the click can't land on an icon that took its place.
    private func clickOverflowButton() async -> Bool {
        let scan = await scan(ScanTarget.runningApps.filter { $0.bundleID == MenuBarScanner.menuBarAgentBundleID })
        guard let button = scan.overflowButton, button.isOnScreen else { return false }
        await ItemMover.click(at: CGPoint(x: button.frame.midX, y: button.frame.midY))
        return true
    }

    /// Clicks « again if it's still showing the icons behind it.
    private func closeOverflow() async {
        if await scanItems().isOverflowOpen {
            _ = await clickOverflowButton()
        }
    }

    /// Whether the mouse, trackpad and keyboard have been left alone for a moment, so a drag doesn't get mixed up with
    /// what the user is doing.
    private static var isUserIdle: Bool {
        let anyInput = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput) > 1 && isNothingHeld
    }

    /// Whether no mouse button or modifier key is held, so a click can't get mixed up with a drag or ⌘-click of the
    /// user's.
    private static var isNothingHeld: Bool {
        NSEvent.pressedMouseButtons == 0 && NSEvent.modifierFlags.isDisjoint(with: .shortcutKeys)
    }

    /// Waits a moment for the user to let go of the mouse and modifier keys, before a click or drag of CleanBar's.
    /// Returns whether they did.
    private static func waitUntilNothingHeld(for seconds: TimeInterval) async -> Bool {
        let deadline = Date.now + seconds
        while !isNothingHeld, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return isNothingHeld
    }

    // MARK: Layout editor

    /// The editor shows every icon, so hidden ones can be seen and moved too. Clicking CleanBar's icon still hides them,
    /// to see the menu bar without them.
    func beginLayoutEditing() async {
        isEditingLayout = true
        isShowingHidden = true
        isShownByHover = false
        closeFloatingBar()
        endReveal()
        autoHideTask?.cancel()
        requestUpdate()
        await updateTask?.value
        placeNewIconsSoon()
    }

    /// The editor can only read and move icons that are in the menu bar, so icons hidden with CleanBar's icon while it's
    /// open come back first.
    func showHiddenIconsForEditing() async {
        guard isEditingLayout, !isShowingHidden else { return }
        await updateTask?.value
        let wasHiding = hider.isActive
        setShowingHidden(true)
        await updateTask?.value
        if wasHiding {
            // Give them a moment to come back before reading the menu bar.
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Closes « first if the editor left it open: the icons it shows would cover the next app's menus.
    func endLayoutEditing() {
        isEditingLayout = false
        isShowingHidden = false
        closeEditingNote()
        updateGeneration += 1
        let previous = updateTask
        updateTask = Task { [weak self] in
            await previous?.value
            await self?.closeOverflow()
            await self?.update(force: false)
        }
    }

    /// While the editor is open, icons that don't fit in the menu bar are brought out from behind Apple's «, so they
    /// can be pictured and moved like the others: clicking « shows them in place of the app menus. It's a click, so it
    /// waits for the user to let go of the mouse and modifier keys. Returns whether « was opened.
    private func showIconsBehindOverflowButton(in scan: MenuBarScan) async -> Bool {
        guard isEditingLayout, !isPlacingNewIcons, !scan.isOverflowOpen,
              scan.items.contains(where: { !$0.isOnScreen && scan.isBehindOverflowButton($0) })
        else { return false }
        let isNothingHeld = await Self.waitUntilNothingHeld(for: 2)
        guard isEditingLayout, isNothingHeld, await clickOverflowButton() else { return false }
        try? await Task.sleep(for: .milliseconds(700))
        return true
    }

    // MARK: Clicks

    private func iconClicked(event: NSEvent?) {
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            closeFloatingBar()
            icon.showMenu(makeContextMenu())
            return
        }
        // With nothing to hide there's nothing to show either, so offer the menu instead.
        guard Self.canHide, !settings.hiddenIcons.isEmpty else {
            icon.showMenu(makeContextMenu())
            return
        }
        toggleHiddenIcons()
    }

    /// Shows the hidden icons the way the user chose, or hides them again. While the layout editor is open they always
    /// come back in the menu bar, where the editor can read and move them, and a note says to close Settings. `pointer`:
    /// where empty menu bar space was clicked or hovered over, for the floating bar to open below it.
    private func toggleHiddenIcons(at pointer: NSPoint? = nil) {
        if settings.hiddenIconsStyle == .floatingBar, !isEditingLayout {
            toggleFloatingBar(at: pointer)
        } else {
            if !isShowingHidden {
                unfoldPoint = pointer
            }
            setShowingHidden(!isShowingHidden, animated: true)
            if isEditingLayout {
                showEditingNote(below: pointer)
            }
        }
    }

    /// Closes the floating bar, or hides the icons back in the menu bar.
    private func hideShownIcons() {
        if floatingBar.isOpen {
            closeFloatingBar()
        } else if isShowingHidden {
            setShowingHidden(false, animated: true)
        }
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let edit = menu.addItem(withTitle: String(localized: "Edit Menu Bar Layout"), action: #selector(openLayoutEditor), keyEquivalent: "")
        edit.target = self
        edit.image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: nil)
        let settings = menu.addItem(withTitle: String(localized: "Settings"), action: #selector(openGeneralSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: String(localized: "Quit CleanBar"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        return menu
    }

    @objc private func openLayoutEditor() {
        showSettings(tab: .layout)
    }

    @objc private func openGeneralSettings() {
        showSettings(tab: .general)
    }

    // MARK: While the layout editor is open

    /// The layout editor needs the hidden icons in the menu bar, so while it's open CleanBar's icon, the shortcut and
    /// empty menu bar space only show and hide them there: not in the floating bar, not by hovering, and they don't hide
    /// by themselves. Using them says so, in a note that grows out of the menu bar like the floating bar, below CleanBar's
    /// icon or the pointer, with a button that closes Settings. It goes after a few seconds, unless the pointer is on it.
    private func showEditingNote(below pointer: NSPoint?) {
        let (anchor, screen) = floatingBarPlace(below: pointer)
        let note = FloatingBarNote(
            symbol: SettingsTab.layout.symbol,
            tint: SettingsTab.layout.tint,
            text: String(localized: "Close Settings so CleanBar can work as expected"),
            detail: String(localized: "While Menu Bar Layout is open, hidden icons only show and hide in the menu bar, where it can read and move them, and they stay until you hide them."),
            buttonTitle: String(localized: "Close Settings")
        ) { [weak self] in
            self?.settingsWindow.close()
        }
        editingNote.show(note, below: anchor, on: screen)
        closeEditingNote(after: 5)
    }

    /// Closes the note now, or after `delay` seconds once the pointer isn't on it.
    private func closeEditingNote(after delay: TimeInterval? = nil) {
        editingNoteTask?.cancel()
        guard let delay else {
            editingNote.close()
            return
        }
        editingNoteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            if self.editingNote.containsMouse {
                self.closeEditingNote(after: 1)
            } else {
                self.editingNote.close()
            }
        }
    }

    /// Hovering over empty menu bar space doesn't show the hidden icons while the layout editor is open, but says why.
    private var canNoteEditingOnHover: Bool {
        isEditingLayout && Self.canHide && !settings.hiddenIcons.isEmpty && !editingNote.isOpen && !isPlacingNewIcons
            && NSEvent.pressedMouseButtons == 0 && !WindowInfo.isMenuOpen()
    }

    // MARK: Notification Center

    /// Notification Center doesn't open while icons are hidden, neither from the clock nor with the Show Notification
    /// Center shortcut. A click on the clock pauses hiding for a few hundredths of a second, presses the clock and hides
    /// again. Notification Center opens a tenth of a second later all the same and stays open. `clockTap` keeps the click
    /// itself from the menu bar; this is for when it can't run.
    private func handleMouseDown() {
        guard !clockTap.isRunning, hider.isActive, notificationCenterTask == nil, let clockFrame,
              clockFrame.contains(Self.mouseLocationInScreenPoints),
              // A click that closes Notification Center needs no help.
              !WindowInfo.isNotificationCenterOpen()
        else { return }
        startOpeningNotificationCenter()
    }

    /// A click on the clock that `clockTap` took from the menu bar.
    private func clockClicked() {
        // They close on clicks outside them, but this one never got to them.
        closeFloatingBar()
        closeEditingNote()
        guard notificationCenterTask == nil else { return }
        guard hider.isActive else {
            // Hiding stopped just before, so the clock works by itself again: the click goes to it.
            let clock = Self.clockIdentifier
            Task.detached { _ = MenuBarScanner.pressSystemItem(clock) }
            return
        }
        startOpeningNotificationCenter()
    }

    private func startOpeningNotificationCenter() {
        notificationCenterTask = Task { [weak self] in
            await self?.openNotificationCenter()
            self?.notificationCenterTask = nil
            self?.updateClockTap()
        }
        updateClockTap()
    }

    /// The tap takes clicks on the clock only while CleanBar hides icons and isn't already opening Notification Center.
    private func updateClockTap() {
        clockTap.setClockFrame(hider.isActive && notificationCenterTask == nil ? clockFrame : nil)
    }

    private func startClockTap() {
        guard !clockTap.isRunning, Permissions.accessibilityGranted else { return }
        clockTap.start()
        updateClockTap()
    }

    /// Pressed while Control Center hasn't heard yet that hiding paused, the clock still does nothing. Control Center hears
    /// it from macOS 10–30 ms after hiding pauses, and so does CleanBar (`IconHider.restrictions`), so the clock is
    /// pressed right then and hiding resumes right after: macOS takes the list back as soon as it has brought the hidden
    /// icons back, as they start sliding in, so they're gone again before they show much. A fixed pause was sometimes too
    /// short (2 of 4 tries on macOS 27.0.1, 20 ms after hiding paused), and then hiding paused a second time.
    ///
    /// When macOS doesn't say, a fixed pause instead. If Notification Center doesn't open, once more, waiting longer.
    private func openNotificationCenter() async {
        let clock = Self.clockIdentifier
        let restrictions = hider.restrictions
        // Milliseconds to wait after macOS says hiding paused, or after pausing when it doesn't say.
        for (afterWord, pause) in [(5, 20), (60, 80)] {
            let pressed = await Task.detached { [weak self] in
                // Found before hiding pauses, since that can take a while.
                guard let item = MenuBarScanner.systemItem(clock) else { return false }
                await self?.pauseHidingForNotificationCenter()
                // It normally comes within 30 ms.
                switch await restrictions.waitUntilLifted(timeout: 0.06) {
                case true?: try? await Task.sleep(for: .milliseconds(afterWord), tolerance: .zero)
                case false?: break
                case nil: try? await Task.sleep(for: .milliseconds(pause))
                }
                let pressed = AX.press(item)
                await self?.resumeHidingAfterNotificationCenter()
                return pressed
            }.value
            guard pressed else { return }
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(50))
                if WindowInfo.isNotificationCenterOpen() { return }
            }
        }
    }

    /// The list to hide with again is made first: building it takes a few milliseconds.
    private func pauseHidingForNotificationCenter() async {
        if shouldHide {
            let (allowed, systemItems) = allowList(hiding: iconsToHide)
            listAfterNotificationCenter = hider.prepare(only: allowed, systemItems: systemItems)
        }
        isPausedForNotificationCenter = true
        requestUpdate()
        await updateTask?.value
    }

    /// Hides again straight away, without waiting for updates in line. As soon as hiding pauses, macOS starts bringing
    /// the hidden icons back, which keeps it busy for a few hundredths of a second, and a list that comes in meanwhile
    /// waits until it's done (seen on macOS 27.0.1: 25–40 ms after hiding paused). The update after it only catches up
    /// with changes made meanwhile.
    private func resumeHidingAfterNotificationCenter() async {
        isPausedForNotificationCenter = false
        if let list = listAfterNotificationCenter, shouldHide {
            await hider.allow(list)
        }
        listAfterNotificationCenter = nil
        requestUpdate()
    }

    private var isMouseInMenuBar: Bool { Self.isInMenuBar(NSEvent.mouseLocation) }

    /// Whether a point on the screen (origin at the bottom left) is in a menu bar.
    private static func isInMenuBar(_ location: NSPoint) -> Bool {
        guard let screen = NSScreen.containing(location) else { return false }
        return location.y >= screen.frame.maxY - MenuBarStrip.height(of: screen)
    }

    /// The pointer location with the origin at the top-left of the primary screen, like Accessibility frames.
    private static var mouseLocationInScreenPoints: CGPoint {
        let location = NSEvent.mouseLocation
        return CGPoint(x: location.x, y: NSScreen.primaryHeight - location.y)
    }

    // MARK: Observing the system

    private func installEventMonitors() {
        let clicks = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            // Other apps' events have no window here: the location is on the screen.
            let location = event.locationInWindow
            let modifiers = event.modifierFlags
            MainActor.assumeIsolated {
                self?.handleMouseDown()
                self?.menuBarClicked(at: location, modifiers: modifiers)
            }
        }
        eventMonitors = [clicks].compactMap { $0 }
    }

    private func observeSystem() {
        // The launch notification skips apps without a Dock icon, which is most apps with menu bar icons.
        runningAppsObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { @Sendable [weak self] _, change in
            let launched = change.kind == .insertion ? (change.newValue ?? []).compactMap(\.bundleIdentifier) : []
            Task { @MainActor in self?.runningAppsChanged(launched: launched) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: AppSettings.didChange, object: nil)
    }

    /// A launching app isn't in the list yet, so its icon would be hidden: rebuild the list, unless the app is new and
    /// new icons go to Hidden. When the menu bar process itself restarted, the old list is gone, so give it a moment and
    /// apply the list again.
    private func runningAppsChanged(launched: [String]) {
        lastFullScan = .distantPast
        guard !launched.isEmpty else { return }
        noteNewApps()
        pictureIconsSoon(of: launched)
        guard launched.contains(MenuBarScanner.menuBarAgentBundleID) else {
            requestUpdate()
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.requestUpdate(force: true)
        }
    }

    /// The clock moves with the screen layout.
    @objc private func screensChanged() {
        Task { await checkHiding() }
    }

    @objc private func settingsChanged() {
        registerHotKey()
        applyIconSettings()
        updatePointerMonitors()
        if !settings.autoHide {
            autoHideTask?.cancel()
        }
        if settings.hiddenIconsStyle != hiddenIconsStyle {
            hiddenIconsStyle = settings.hiddenIconsStyle
            hiddenIconsStyleChanged()
        }
        requestUpdate()
    }

    /// Hidden icons showing the old way go away, so the next click shows them the new way.
    private func hiddenIconsStyleChanged() {
        closeFloatingBar()
        endReveal()
        if isShowingHidden, !isEditingLayout {
            setShowingHidden(false)
        }
    }

    /// CleanBar's icon as the user set it up: its symbol, and whether it's in the menu bar at all.
    private func applyIconSettings() {
        icon.style = settings.iconStyle
        icon.opensBelow = settings.hiddenIconsStyle == .floatingBar
        icon.isVisible = !settings.hidesIcon
    }

    private func registerHotKey() {
        guard settings.hotKey != registeredHotKey else { return }
        registeredHotKey = settings.hotKey
        HotKeyCenter.shared.register(settings.hotKey) { [weak self] in
            guard let self, Self.canHide, !self.settings.hiddenIcons.isEmpty else { return }
            self.toggleHiddenIcons()
        }
    }

    // MARK: Floating bar

    /// Opens the floating bar below CleanBar's icon, or below the pointer, or closes it. It opens with the icons CleanBar
    /// remembers, then asks the apps, which takes a moment, and takes in what changed: icons of new apps that were hidden
    /// from the start, or icons an app no longer has.
    private func toggleFloatingBar(at pointer: NSPoint?) {
        if floatingBar.isOpen {
            closeFloatingBar()
            return
        }
        endReveal()
        let shown = floatingBarItems(reported: nil)
        (floatingBarAnchor, floatingBarScreen) = floatingBarPlace(below: pointer)
        floatingBar.show(shown.items, pictures: shown.pictures, below: floatingBarAnchor, on: floatingBarScreen)
        updateIcon()
        scheduleAutoHide()

        guard Permissions.accessibilityGranted else { return }
        let hidden = settings.hiddenIcons
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // Apps keep their icons while they're out of the menu bar. macOS's own leave the Accessibility tree.
        let targets = ScanTarget.runningApps.filter { app in
            guard let bundleID = app.bundleID, app.pid != ownPID, !MenuBarItem.systemBundleIDs.contains(bundleID) else {
                return false
            }
            return hidden.bundleIDs.contains(bundleID) || !IconHider.isRecognized(appPath: app.path)
        }
        floatingBarTask = Task { [weak self] in
            guard let self else { return }
            let reported = await self.scan(targets).items
            guard !Task.isCancelled, self.floatingBar.isOpen else { return }
            let current = self.floatingBarItems(reported: reported)
            if current.items.map(\.id) != shown.items.map(\.id) {
                self.floatingBar.show(current.items, pictures: current.pictures, below: self.floatingBarAnchor, on: self.floatingBarScreen)
            }
        }
    }

    /// Where the floating bar opens: below the pointer when empty menu bar space opened it, else below CleanBar's icon,
    /// or, with the icon hidden, at the right end of the menu bar the pointer is in, below the other icons.
    private func floatingBarPlace(below pointer: NSPoint?) -> (anchor: NSRect?, screen: NSScreen?) {
        if let pointer {
            return (NSRect(origin: pointer, size: .zero), NSScreen.containing(pointer))
        }
        if icon.isVisible, let frame = icon.frameOnScreen {
            return (frame, icon.screen)
        }
        let screen = NSScreen.containing(NSEvent.mouseLocation) ?? NSScreen.main
        return (screen.map { NSRect(x: $0.frame.maxX, y: $0.frame.maxY, width: 0, height: 0) }, screen)
    }

    /// Clicks the floating bar (and the layout editor's note) leaves to CleanBar, as they open and close it: on CleanBar's
    /// icon, and anywhere in the menu bar when a click on empty space there shows the hidden icons (`menuBarClicked`
    /// closes the bar for the others).
    private func togglesFloatingBar(at location: NSPoint) -> Bool {
        isOnIcon(location) || (settings.showHiddenIconsTrigger == .emptySpaceClick && Self.isInMenuBar(location))
    }

    private func isOnIcon(_ location: NSPoint) -> Bool {
        guard icon.isVisible, let frame = icon.frameOnScreen else { return false }
        return NSMouseInRect(location, frame, false)
    }

    private func closeFloatingBar() {
        floatingBarTask?.cancel()
        floatingBarTask = nil
        floatingBar.close()
    }

    private func floatingBarClosed() {
        if !isShowingHidden {
            autoHideTask?.cancel()
        }
        updateIcon()
    }

    /// What the floating bar shows: the icons out of the menu bar while CleanBar hides icons, in menu bar order, with
    /// their pictures. Those are the hidden icons, and the icons of apps macOS doesn't recognize, which go too.
    ///
    /// `reported`: the icons apps reported when asked, nil before they're asked. An app that reports none gets the icons
    /// CleanBar remembers, as do macOS's own icons, which leave the Accessibility tree when they're hidden.
    private func floatingBarItems(reported: [MenuBarItem]?) -> (items: [MenuBarItem], pictures: [String: ItemPicture]) {
        let hidden = settings.hiddenIcons
        let reported = reported ?? []
        let reportingApps = Set(reported.compactMap(\.bundleID))
        let remembered = iconMemory.items(of: ScanTarget.runningApps).filter { !reportingApps.contains($0.bundleID ?? "") }
        let items = (reported + remembered)
            .filter { item in
                item.canBeHidden && !iconMemory.isTurnedOff(item) && (hidden.contains(item) || !item.isRecognizedByMacOS)
            }
            .sorted { iconMemory.place(of: $0) < iconMemory.place(of: $1) }
        let pictures = items.reduce(into: [String: ItemPicture]()) { pictures, item in
            pictures[item.id] = iconMemory.picture(for: item)
        }
        return (items, pictures)
    }

    // MARK: Empty menu bar space

    /// A plain click on empty space in the menu bar shows or hides the hidden icons, when the user chose that. The
    /// floating bar leaves every click in the menu bar to this then, so other clicks there close it.
    private func menuBarClicked(at location: NSPoint, modifiers: NSEvent.ModifierFlags) {
        guard settings.showHiddenIconsTrigger == .emptySpaceClick, Self.isInMenuBar(location), !isOnIcon(location) else {
            return
        }
        let isPlain = modifiers.isDisjoint(with: .shortcutKeys)
        Task {
            if isPlain, Self.canHide, !settings.hiddenIcons.isEmpty, !isPlacingNewIcons,
               await Self.isEmptyMenuBarSpace(at: location) {
                toggleHiddenIcons(at: location)
            } else {
                if floatingBar.isOpen {
                    closeFloatingBar()
                }
                closeEditingNote()
            }
        }
    }

    /// Whether that part of the menu bar is empty: no app menu, icon or Apple's « there, nor on either side, as in the gap
    /// between two icons, and it isn't the camera housing.
    private static func isEmptyMenuBarSpace(at location: NSPoint) async -> Bool {
        guard let screen = NSScreen.containing(location), isInMenuBar(location), !screen.isInCameraHousing(x: location.x),
              let owner = NSWorkspace.shared.menuBarOwningApplication?.processIdentifier
        else { return false }
        // Accessibility's points start at the top left of the main screen. Icons only span the menu bar's middle: at its
        // top edge, the menu bar itself is hit over them too.
        let point = CGPoint(x: location.x, y: NSScreen.primaryHeight - screen.frame.maxY + MenuBarStrip.height(of: screen) / 2)
        return await Task.detached { MenuBarScanner.isEmptySpace(around: point, menuBarOwner: owner) }.value
    }

    /// The pointer is only watched while hovering over empty menu bar space shows the hidden icons.
    private func updatePointerMonitors() {
        let isHoverOn = settings.showHiddenIconsTrigger == .emptySpaceHover
        guard isHoverOn == pointerMonitors.isEmpty else { return }
        if isHoverOn {
            let elsewhere = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerMoved() }
            }
            // Pointer moves go to CleanBar instead while it's the active app.
            let inCleanBar = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                MainActor.assumeIsolated { self?.pointerMoved() }
                return event
            }
            pointerMonitors = [elsewhere, inCleanBar].compactMap { $0 }
        } else {
            pointerMonitors.forEach(NSEvent.removeMonitor)
            pointerMonitors = []
            hoverTask?.cancel()
            hoverTask = nil
            isShownByHover = false
        }
    }

    private func pointerMoved() {
        guard hoverTask == nil, isMouseInMenuBar else { return }
        hoverTask = Task { [weak self] in
            await self?.followPointer()
            if !Task.isCancelled {
                self?.hoverTask = nil
            }
        }
    }

    /// Follows the pointer from when it comes into the menu bar. Once it has rested on empty space for a moment, the
    /// hidden icons show (while the layout editor is open, the note saying to close Settings does instead): passing over
    /// it on the way to an icon doesn't count. Once it has left the menu bar and the floating bar, with no menu open,
    /// they go again. Hidden some other way, like with a click, they only show again after the pointer has left the menu
    /// bar.
    private func followPointer() async {
        var emptySince: Date?
        var outsideSince: Date?
        var waitsForLeave = false
        var lastLocation: NSPoint?
        while !Task.isCancelled {
            if isShownByHover, isEditingLayout || (!isShowingHidden && !floatingBar.isOpen) {
                isShownByHover = false
                waitsForLeave = true
            }
            if isShownByHover {
                if isMouseInMenuBar || floatingBar.containsMouse || isRevealing || WindowInfo.isMenuOpen() {
                    outsideSince = nil
                } else if let outsideSince {
                    if Date.now.timeIntervalSince(outsideSince) > 0.6 {
                        isShownByHover = false
                        hideShownIcons()
                        return
                    }
                } else {
                    outsideSince = .now
                }
            } else {
                guard isMouseInMenuBar else { return }
                let location = NSEvent.mouseLocation
                let isResting = lastLocation.map { hypot(location.x - $0.x, location.y - $0.y) < 8 } ?? false
                lastLocation = location
                if !waitsForLeave, isResting, canShowOnHover || canNoteEditingOnHover,
                   await Self.isEmptyMenuBarSpace(at: location) {
                    let since = emptySince ?? .now
                    emptySince = since
                    if Date.now.timeIntervalSince(since) >= 0.3 {
                        if canShowOnHover {
                            emptySince = nil
                            outsideSince = nil
                            isShownByHover = true
                            toggleHiddenIcons(at: location)
                        } else if canNoteEditingOnHover {
                            // Once, until the pointer leaves the menu bar.
                            emptySince = nil
                            waitsForLeave = true
                            showEditingNote(below: location)
                        }
                    }
                } else {
                    emptySince = nil
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Hovering doesn't show the hidden icons while they're showing or in use (a menu is open, or one is open from the
    /// floating bar), while the layout editor shows them anyway, or while a mouse button is held, as in a drag.
    private var canShowOnHover: Bool {
        Self.canHide && !settings.hiddenIcons.isEmpty && !isEditingLayout && !isShowingHidden && !floatingBar.isOpen
            && !isRevealing && !isPlacingNewIcons && NSEvent.pressedMouseButtons == 0 && !WindowInfo.isMenuOpen()
    }

    // MARK: Opening hidden icons from the floating bar

    private var isRevealing: Bool { !revealedIcons.isEmpty || isRevealingAll }

    /// Opens a hidden icon from the floating bar: the icon comes back in the menu bar, left of all the other icons, and
    /// is clicked there the way it was clicked in the bar, so its menu opens below it as usual. It hides again once its
    /// menu has closed.
    private func reveal(_ item: MenuBarItem, click: ItemClick) {
        closeFloatingBar()
        revealGeneration += 1
        let generation = revealGeneration
        let previous = revealTask
        revealTask = Task { [weak self] in
            await previous?.value
            guard let self, self.revealGeneration == generation else { return }
            await self.open(item, click: click, generation: generation)
        }
    }

    /// Hides the icon opened from the floating bar again, if there's one.
    private func endReveal() {
        revealGeneration += 1
    }

    private func open(_ item: MenuBarItem, click: ItemClick, generation: Int) async {
        if item.isRecognizedByMacOS {
            revealedIcons = HiddenIcons(item)
        } else {
            // macOS can't tell this app's icons from the others', so they only come back all together.
            isRevealingAll = true
        }
        requestUpdate()
        await updateTask?.value

        let (drawn, openedOverflow) = await waitUntilDrawn(item, generation: generation)
        if let drawn {
            // Behind «, the icon is drawn in place of the app menus, not among the other icons.
            let opened = openedOverflow ? drawn : await moveToLeftEnd(drawn, generation: generation)
            let windowsBefore = WindowInfo.onScreenWindowIDs()
            await press(opened, click)
            await waitWhileInUse(since: windowsBefore, generation: generation)
            if revealGeneration == generation {
                await rememberIcons(like: opened)
            }
        } else if revealGeneration == generation {
            NSSound.beep()
        }
        if openedOverflow {
            await closeOverflow()
        }
        revealedIcons = HiddenIcons()
        isRevealingAll = false
        requestUpdate()
        await updateTask?.value
    }

    /// Waits for an icon let back into the menu bar to be drawn there, and returns it as it is now. An icon that doesn't
    /// fit is behind Apple's «, and clicking « brings it out; the caller closes « again. Gives up after two seconds, as
    /// when the icon is turned off in System Settings.
    private func waitUntilDrawn(_ item: MenuBarItem, generation: Int) async -> (item: MenuBarItem?, openedOverflow: Bool) {
        let targets = ScanTarget.runningApps.filter {
            $0.bundleID == item.bundleID || $0.bundleID == MenuBarScanner.menuBarAgentBundleID
        }
        let start = Date.now
        var openedOverflow = false
        while revealGeneration == generation, Date.now.timeIntervalSince(start) < 2 {
            let scan = await scan(targets)
            let appItems = scan.items.filter { $0.bundleID == item.bundleID }
            // The same icon of the app, or else the app's only one. macOS's own icons go by their identifier.
            let current = appItems.first { $0.placeKey == item.placeKey }
                ?? (item.isSystemItem || appItems.count != 1 ? nil : appItems.first)
            if let current {
                if current.isOnScreen {
                    return (current, openedOverflow)
                }
                // Right after the list changes, an icon can still report where it was.
                if !openedOverflow, Date.now.timeIntervalSince(start) > 0.3, scan.isBehindOverflowButton(current),
                   Self.isNothingHeld, await clickOverflowButton() {
                    openedOverflow = true
                    try? await Task.sleep(for: .milliseconds(700))
                    continue
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return (nil, openedOverflow)
    }

    /// Moves an icon opened from the floating bar to the left end of the icons in its menu bar, so no other icon moves
    /// while it's in the menu bar. It's a ⌘-drag, made with the pointer hidden (see `ItemMover`), so it waits for the
    /// user to let go of the mouse and modifier keys, and it's rarely needed: macOS keeps the icon there, so the next
    /// time it comes back there by itself. Returns the icon as it is now.
    private func moveToLeftEnd(_ item: MenuBarItem, generation: Int) async -> MenuBarItem {
        guard let owner = NSWorkspace.shared.menuBarOwningApplication?.processIdentifier else { return item }
        let running = ScanTarget.runningApps
        let ownApp = running.filter { $0.bundleID == item.bundleID }
        // Only the apps known to have icons, and macOS's menu bar process: asking every app takes seconds.
        let knownApps = Set(iconMemory.items(of: running).compactMap(\.bundleID))
            .union([item.bundleID, MenuBarScanner.menuBarAgentBundleID].compactMap { $0 })
        let targets = running.filter { extrasPIDs.contains($0.pid) || knownApps.contains($0.bundleID ?? "") }
        var current = item
        for attempt in 0..<3 {
            // Usually it's there already, which a few hit tests tell right away.
            let frame = current.frame
            let isThere = await Task.detached { MenuBarScanner.hasNothingLeft(of: frame, menuBarOwner: owner) }.value
            guard !isThere, revealGeneration == generation else { break }
            if attempt == 0 {
                // macOS is still sliding the other icons over to make room for it.
                try? await Task.sleep(for: .milliseconds(200))
            }
            let scan = await scan(targets)
            guard let latest = scan.items.first(where: { $0.id == item.id }), latest.isOnScreen else { break }
            current = latest
            // The hit tests also find app menus that reach this far.
            guard !scan.isOverflowOpen,
                  let leftmost = scan.items.first(where: { $0.isOnScreen && $0.strip == latest.strip && $0.id != latest.id }),
                  leftmost.frame.minX < latest.frame.minX,
                  await Self.waitUntilNothingHeld(for: 1), !isPlacingNewIcons, revealGeneration == generation
            else { break }
            await ItemMover.drag(from: latest.center, to: .leftOf(leftmost.frame))
            try? await Task.sleep(for: .milliseconds(400))
            current = await self.scan(ownApp).items.first { $0.id == item.id && $0.isOnScreen } ?? latest
        }
        return current
    }

    /// Clicks the icon in the menu bar the way it was clicked in the floating bar. A plain click is an Accessibility
    /// press. Right clicks and clicks with modifier keys are posted as mouse events at the icon, which has just been
    /// hit-tested, as is a plain click the icon can't take as a press, with the pointer hidden meanwhile. Never both: a
    /// click on top of a press that went through would close the menu it opened.
    private func press(_ item: MenuBarItem, _ click: ItemClick) async {
        if click.isPlain {
            let pressed = await Task.detached {
                if item.isSystemItem, let identifier = item.identifier {
                    return MenuBarScanner.pressSystemItem(identifier)
                }
                return item.supportsPress && MenuBarScanner.press(item)
            }.value
            if pressed { return }
        }
        await ItemMover.click(at: item.center, isRightClick: click.isRightClick, flags: click.eventFlags)
    }

    /// Waits while the icon is in use: while a menu, popover or panel that opened after the click is open, or while the
    /// pointer is in the menu bar. When nothing opens within a few seconds, the click did something else, like opening
    /// a window, and the icon can go.
    private func waitWhileInUse(since windowsBefore: Set<CGWindowID>, generation: Int) async {
        var hasOpened = false
        var lastUse = Date.now
        while revealGeneration == generation {
            try? await Task.sleep(for: .milliseconds(200))
            if WindowInfo.hasWindowOpened(since: windowsBefore) {
                hasOpened = true
                lastUse = .now
            } else if isMouseInMenuBar {
                lastUse = .now
            }
            if Date.now.timeIntervalSince(lastUse) > (hasOpened ? 0.4 : 3) { return }
        }
    }

    /// Takes new pictures of the app's icons, or of the macOS icon, while they're in the menu bar, for the next time the
    /// floating bar shows them. They've been in place since the click, so the picture is taken right away and the icon
    /// hides without lingering; one that moves meanwhile keeps its old picture.
    private func rememberIcons(like item: MenuBarItem) async {
        var scan = await scan(ScanTarget.runningApps.filter { $0.bundleID == item.bundleID })
        scan.items.removeAll { !$0.isOnScreen || (item.isSystemItem && $0.placeKey != item.placeKey) }
        let pictures = await ItemImageCapture.pictures(for: scan.items, settle: .zero)
        iconMemory.remember(scan, pictures: pictures, isFullMenuBar: !hider.isActive)
    }
}
