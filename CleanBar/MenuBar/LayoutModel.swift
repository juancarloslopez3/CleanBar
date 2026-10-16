import AppKit
import Observation

enum LayoutSection {
    case shown
    case hidden

    var title: String {
        switch self {
        case .shown: String(localized: "Shown")
        case .hidden: String(localized: "Hidden")
        }
    }

    var subtitle: String {
        switch self {
        case .shown: String(localized: "Always in the menu bar")
        case .hidden: String(localized: "Out of the menu bar until you show them")
        }
    }
}

/// Every menu bar item, split by whether it's hidden. Hidden icons are back in the menu bar while the editor is open, and
/// Apple's « is kept open, so they can be pictured and moved like the others.
struct LayoutSnapshot {
    let shown: [MenuBarItem]
    let hidden: [MenuBarItem]
    /// In the menu bar but not drawn right now: behind Apple's « because the menu bar is full.
    let notVisible: [MenuBarItem]
    /// Turned off under System Settings → Menu Bar.
    let turnedOff: [MenuBarItem]
    var pictures: [String: ItemPicture]
    let date = Date.now

    /// Everything drawn in the menu bar, in menu bar order.
    private let ordered: [MenuBarItem]
    private let hiddenIcons: HiddenIcons

    init(scan: MenuBarScan, hiddenIcons: HiddenIcons, pictures: [String: ItemPicture]) {
        let inMenuBar = scan.items.filter { !scan.isTurnedOff($0) }
        ordered = inMenuBar.filter(\.isOnScreen)
        self.hiddenIcons = hiddenIcons
        shown = ordered.filter { !hiddenIcons.contains($0) }
        hidden = ordered.filter { hiddenIcons.contains($0) }
        notVisible = inMenuBar.filter { !$0.isOnScreen }
        turnedOff = scan.items.filter(scan.isTurnedOff)
        self.pictures = pictures
    }

    func items(in section: LayoutSection) -> [MenuBarItem] {
        switch section {
        case .shown: shown
        case .hidden: hidden
        }
    }

    /// The section's items that aren't drawn right now (shown dimmed).
    func unavailableItems(in section: LayoutSection) -> [MenuBarItem] {
        notVisible.filter { (section == .hidden) == hiddenIcons.contains($0) }
    }

    func item(withID id: String) -> MenuBarItem? {
        ordered.first { $0.id == id } ?? notVisible.first { $0.id == id }
    }

    func section(of item: MenuBarItem) -> LayoutSection {
        hiddenIcons.contains(item) ? .hidden : .shown
    }

    func isPlaced(_ itemID: String, before anchorID: String) -> Bool {
        guard let index = ordered.firstIndex(where: { $0.id == itemID }), index + 1 < ordered.count else { return false }
        return ordered[index + 1].id == anchorID
    }

    /// Names of shown apps that macOS can't tell apart, so their icons go too whenever CleanBar hides icons.
    var unrecognizedAppNames: [String] {
        let names = (shown + unavailableItems(in: .shown))
            .filter { $0.canBeHidden && !$0.isRecognizedByMacOS }
            .map(\.appName)
        return Array(Set(names)).sorted()
    }
}

/// State behind the layout editor.
@Observable
final class LayoutModel {
    private(set) var snapshot: LayoutSnapshot?
    private(set) var isRefreshing = false
    private(set) var isMoving = false
    /// Why the last move didn't go through.
    private(set) var message: String?

    @ObservationIgnored private var isEditing = false
    @ObservationIgnored weak var manager: MenuBarManager?

    var isWorking: Bool { isRefreshing || isMoving }

    /// What the "New icons appear here" marker is dragged as.
    static let newIconsMarkerID = "CleanBar.NewIcons"

    /// The row with the "New icons appear here" marker, where icons of apps CleanBar hasn't seen before go.
    var newIconsSection: LayoutSection {
        manager?.settings.hidesNewIcons == true ? .hidden : .shown
    }

    /// Whether the marker was dropped somewhere, so new icons are moved there.
    var isNewIconsMarkerPlaced: Bool {
        manager?.settings.newIconsPlace != nil
    }

    /// The item the marker sits in front of in its row, or nil at the end. Until it's dropped somewhere, it sits at the
    /// start.
    func newIconsAnchor(in row: [MenuBarItem]) -> MenuBarItem? {
        guard let place = manager?.settings.newIconsPlace else { return row.first }
        return place.anchor(in: row)
    }

    func picture(for item: MenuBarItem) -> ItemPicture? {
        snapshot?.pictures[item.id]
    }

    /// CleanBar's own icon, with the symbol the user picked.
    var iconImage: NSImage {
        let settings = manager?.settings
        return (settings?.iconStyle ?? .circle).image(showingHiddenIcons: false, opensBelow: settings?.hiddenIconsStyle == .floatingBar)
    }

    // MARK: Editing session

    func beginEditing() async {
        guard !isEditing, let manager else { return }
        isEditing = true
        await manager.beginLayoutEditing()
        // Give the icons that were hidden a moment to come back before taking pictures.
        try? await Task.sleep(for: .milliseconds(500))
        await refresh()
    }

    func endEditing() {
        guard isEditing else { return }
        isEditing = false
        manager?.endLayoutEditing()
    }

    func refresh() async {
        guard let manager, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await manager.showHiddenIconsForEditing()
        snapshot = await manager.captureLayout(includePictures: true, reusing: snapshot?.pictures ?? [:])
    }

    // MARK: Moving items

    /// Moving an item to the other section hides or shows it (all of its app's icons, unless it's one of macOS's own).
    /// Dropping it on another item also puts it in front of that item in the menu bar.
    func requestMove(_ itemID: String, to section: LayoutSection, before targetID: String?) {
        if itemID == Self.newIconsMarkerID {
            moveNewIconsMarker(to: section, before: targetID)
            return
        }
        guard !isWorking else { return }
        guard manager?.isPlacingNewIcons != true else {
            message = String(localized: "CleanBar is moving a new icon into place. Try again in a moment.")
            return
        }
        Task { await move(itemID, to: section, before: targetID) }
    }

    private func move(_ itemID: String, to section: LayoutSection, before targetID: String?) async {
        guard let manager, var current = snapshot, let item = current.item(withID: itemID), itemID != targetID else { return }
        message = nil
        let changesSection = current.section(of: item) != section
        guard changesSection || targetID != nil else { return }
        if changesSection, !item.canBeHidden {
            message = Self.reasonAlwaysShown(item)
            return
        }
        // The menu bar is read and icons are moved in it, so icons hidden with CleanBar's icon come back first.
        await manager.showHiddenIconsForEditing()
        if changesSection {
            manager.setHidden(section == .hidden, item: item)
        }
        // Read the menu bar again: the rows changed, or « closed since the editor last looked and took back the icons
        // it was showing. Reading it opens « again.
        current = await manager.captureLayout(includePictures: false, reusing: current.pictures)
        snapshot = current
        guard let targetID else { return }

        // Put the real icon in front of the target, the way a person ⌘-drags it.
        guard current.item(withID: itemID)?.isOnScreen == true else {
            message = String(localized: "“\(item.displayName)” isn't in the menu bar right now, so it can't be moved.")
            return
        }
        isMoving = true
        defer { isMoving = false }
        for _ in 0..<3 {
            if current.isPlaced(itemID, before: targetID) { break }
            guard let moving = current.item(withID: itemID), moving.isOnScreen,
                  let target = current.item(withID: targetID), target.isOnScreen
            else { break }
            await ItemMover.drag(from: moving.center, to: .leftOf(target.frame))
            try? await Task.sleep(for: .milliseconds(400))
            current = await manager.captureLayout(includePictures: false, reusing: current.pictures)
            snapshot = current
        }
        let placed = current.isPlaced(itemID, before: targetID)
        snapshot = await manager.captureLayout(includePictures: true, reusing: current.pictures)
        if !placed {
            message = String(localized: "macOS didn't let CleanBar move “\(item.displayName)”. Some system items, like the clock and Control Center, can't be moved.")
        }
    }

    /// Dropped on an item, the marker goes in front of it, or at the row's start when that's the row's first item.
    /// Dropped elsewhere in a row, it goes at the row's end.
    private func moveNewIconsMarker(to section: LayoutSection, before targetID: String?) {
        guard let settings = manager?.settings else { return }
        var place = NewIconsPlace.end
        if let targetID, let snapshot {
            let row = snapshot.items(in: section) + snapshot.unavailableItems(in: section)
            if let index = row.firstIndex(where: { $0.id == targetID }) {
                place = index == 0 ? .start : .before(row[index...].map(\.placeKey))
            }
        }
        if settings.hidesNewIcons != (section == .hidden) {
            settings.hidesNewIcons = section == .hidden
        }
        if settings.newIconsPlace != place {
            settings.newIconsPlace = place
        }
    }

    private static func reasonAlwaysShown(_ item: MenuBarItem) -> String {
        if item.controlRole != nil {
            return String(localized: "CleanBar's icon always stays in the menu bar.")
        }
        if item.systemItem == .clock {
            return String(localized: "The clock always stays in the menu bar.")
        }
        if item.isSystemItem {
            return String(localized: "macOS doesn't let CleanBar hide “\(item.displayName)”. Of macOS's own icons, CleanBar can hide Wi-Fi, Bluetooth, Battery, Sound, Display, Keyboard Brightness, Screen Mirroring and Control Center.")
        }
        return String(localized: "CleanBar can't hide “\(item.displayName)”: macOS doesn't say which app it belongs to.")
    }
}
