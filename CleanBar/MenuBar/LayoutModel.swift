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

/// Where an icon dropped in a row of the layout editor goes.
nonisolated enum RowPlace: Equatable, Sendable {
    case before(String)
    case after(String)
    /// In a row with no icons, so it stays where it is in the menu bar.
    case anywhere

    /// The place for the gap before the row's item at `gap`, or after its last item when there's none. Past the items
    /// macOS keeps at the right end, it's in front of them, since that's as far as an icon can go.
    init(gap: Int, in row: [MenuBarItem]) {
        let gap = min(gap, row.endOfMovableItems)
        if row.indices.contains(gap) {
            self = .before(row[gap].id)
        } else if let last = row.last {
            self = .after(last.id)
        } else {
            self = .anywhere
        }
    }
}

extension Array where Element == MenuBarItem {
    /// The row's first gap that has only items macOS keeps at the right end after it.
    nonisolated var endOfMovableItems: Int {
        (lastIndex(where: \.canMoveInMenuBar) ?? -1) + 1
    }
}

/// Every menu bar item, split by whether it's hidden. Hidden icons are back in the menu bar while the editor is open, and
/// Apple's « is kept open, so they can be pictured and moved like the others.
struct LayoutSnapshot {
    private(set) var shown: [MenuBarItem]
    private(set) var hidden: [MenuBarItem]
    /// In the menu bar but not drawn right now: behind Apple's « because the menu bar is full.
    let notVisible: [MenuBarItem]
    /// Turned off under System Settings → Menu Bar.
    let turnedOff: [MenuBarItem]
    var pictures: [String: ItemPicture]
    private(set) var date = Date.now

    /// Everything drawn in the menu bar, in menu bar order.
    private var ordered: [MenuBarItem]
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

    /// What's drawn in the menu bar, in order, to tell when it changed.
    var drawnIDs: [String] { ordered.map(\.id) }

    func item(withID id: String) -> MenuBarItem? {
        ordered.first { $0.id == id } ?? notVisible.first { $0.id == id }
    }

    func section(of item: MenuBarItem) -> LayoutSection {
        hiddenIcons.contains(item) ? .hidden : .shown
    }

    /// Whether the item is drawn right next to the place's item in the menu bar.
    func isPlaced(_ itemID: String, at place: RowPlace) -> Bool {
        guard let index = ordered.firstIndex(where: { $0.id == itemID }) else { return false }
        switch place {
        case .before(let id): return index + 1 < ordered.count && ordered[index + 1].id == id
        case .after(let id): return index > 0 && ordered[index - 1].id == id
        case .anywhere: return true
        }
    }

    /// Whether dropping the item there leaves it where it is in its row: on either side of itself.
    func isInPlace(_ item: MenuBarItem, in section: LayoutSection, at place: RowPlace) -> Bool {
        let row = items(in: section)
        guard let index = row.firstIndex(where: { $0.id == item.id }) else { return false }
        switch place {
        case .before(let id): return id == item.id || (index + 1 < row.count && row[index + 1].id == id)
        case .after(let id): return id == item.id || (index > 0 && row[index - 1].id == id)
        case .anywhere: return true
        }
    }

    /// The same with the item already where it was dropped, so it goes there right away while the real one gets there.
    func placing(_ itemID: String, in section: LayoutSection, at place: RowPlace) -> LayoutSnapshot {
        guard let item = item(withID: itemID), item.isOnScreen else { return self }
        var copy = self
        copy.shown.removeAll { $0.id == itemID }
        copy.hidden.removeAll { $0.id == itemID }
        copy.ordered.removeAll { $0.id == itemID }
        switch section {
        case .shown: Self.insert(item, into: &copy.shown, at: place)
        case .hidden: Self.insert(item, into: &copy.hidden, at: place)
        }
        Self.insert(item, into: &copy.ordered, at: place)
        copy.date = .now
        return copy
    }

    private static func insert(_ item: MenuBarItem, into list: inout [MenuBarItem], at place: RowPlace) {
        switch place {
        case .before(let id):
            list.insert(item, at: list.firstIndex { $0.id == id } ?? list.count)
        case .after(let id):
            list.insert(item, at: list.firstIndex { $0.id == id }.map { $0 + 1 } ?? list.count)
        case .anywhere:
            list.append(item)
        }
    }

    /// Names of shown apps that macOS can't tell apart, so their icons go too whenever CleanBar hides icons.
    var unrecognizedAppNames: [String] {
        let names = (shown + unavailableItems(in: .shown))
            .filter { $0.controlRole == nil && $0.canBeHidden && !$0.isRecognizedByMacOS }
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
        guard let manager, !isWorking else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await manager.showHiddenIconsForEditing()
        snapshot = await manager.captureLayout(includePictures: true, reusing: snapshot?.pictures ?? [:])
    }

    // MARK: Moving items

    /// Moving an item to the other section hides or shows it (all of its app's icons, unless it's one of macOS's own), and
    /// it also goes where it was dropped in the menu bar. A drop while the menu bar is being read waits for that to end.
    func requestMove(_ itemID: String, to section: LayoutSection, at place: RowPlace) {
        if itemID == Self.newIconsMarkerID {
            moveNewIconsMarker(to: section, at: place)
            return
        }
        guard !isMoving else { return }
        guard manager?.isPlacingNewIcons != true else {
            message = String(localized: "CleanBar is moving a new icon into place. Try again in a moment.")
            return
        }
        isMoving = true
        Task {
            while isRefreshing {
                try? await Task.sleep(for: .milliseconds(50))
            }
            await move(itemID, to: section, at: place)
            isMoving = false
        }
    }

    private func move(_ itemID: String, to section: LayoutSection, at place: RowPlace) async {
        guard let manager, var current = snapshot, let item = current.item(withID: itemID) else { return }
        message = nil
        let changesSection = current.section(of: item) != section
        if changesSection, !item.canBeHidden {
            message = Self.reasonAlwaysShown(item)
            return
        }
        if !changesSection {
            guard !current.isInPlace(item, in: section, at: place) else { return }
            guard item.canMoveInMenuBar else {
                message = Self.reasonNotMoved(item)
                return
            }
        }
        snapshot = current.placing(itemID, in: section, at: place)
        // The menu bar is read and icons are moved in it, so icons hidden with CleanBar's icon come back first.
        await manager.showHiddenIconsForEditing()
        if changesSection {
            manager.setHidden(section == .hidden, item: item)
        }
        // Read the menu bar again: the rows changed, or « closed since the editor last looked and took back the icons
        // it was showing. Reading it opens « again.
        current = await manager.captureLayout(includePictures: false, reusing: current.pictures, isQuick: true)

        // Put the real icon there, the way a person ⌘-drags it. The clock and Control Center only change rows.
        if place != .anywhere, item.canMoveInMenuBar {
            guard current.item(withID: itemID)?.isOnScreen == true else {
                snapshot = current
                message = String(localized: "“\(item.displayName)” isn't in the menu bar right now, so it can't be moved.")
                return
            }
            for _ in 0..<3 {
                if current.isPlaced(itemID, at: place) { break }
                snapshot = current.placing(itemID, in: section, at: place)
                guard let moving = current.item(withID: itemID), moving.isOnScreen,
                      let destination = Self.destination(of: place, in: current)
                else { break }
                await ItemMover.drag(from: moving.center, to: destination)
                try? await Task.sleep(for: .milliseconds(400))
                current = await manager.captureLayout(includePictures: false, reusing: current.pictures, isQuick: true)
            }
            if !current.isPlaced(itemID, at: place) {
                message = Self.reasonNotMoved(item)
            }
        }
        snapshot = await manager.captureLayout(includePictures: true, reusing: current.pictures, isQuick: true)
    }

    /// Where to drag an icon to reach the place. Nil when the item next to it isn't drawn.
    private static func destination(of place: RowPlace, in snapshot: LayoutSnapshot) -> ItemMover.Destination? {
        switch place {
        case .before(let id): snapshot.item(withID: id).flatMap { $0.isOnScreen ? .leftOf($0.frame) : nil }
        case .after(let id): snapshot.item(withID: id).flatMap { $0.isOnScreen ? .rightOf($0.frame) : nil }
        case .anywhere: nil
        }
    }

    /// Dropped in front of a row's first item, the marker goes at the row's start. After its last item, or in an empty
    /// row, it goes at the end. Elsewhere it goes in front of the item.
    private func moveNewIconsMarker(to section: LayoutSection, at place: RowPlace) {
        guard let settings = manager?.settings else { return }
        var newPlace = NewIconsPlace.end
        if case .before(let targetID) = place, let snapshot {
            let row = snapshot.items(in: section) + snapshot.unavailableItems(in: section)
            if let index = row.firstIndex(where: { $0.id == targetID }) {
                newPlace = index == 0 ? .start : .before(row[index...].map(\.placeKey))
            }
        }
        if settings.hidesNewIcons != (section == .hidden) {
            settings.hidesNewIcons = section == .hidden
        }
        if settings.newIconsPlace != newPlace {
            settings.newIconsPlace = newPlace
        }
    }

    private static func reasonNotMoved(_ item: MenuBarItem) -> String {
        String(localized: "macOS didn't let CleanBar move “\(item.displayName)”. Some system items, like the clock and Control Center, can't be moved.")
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
