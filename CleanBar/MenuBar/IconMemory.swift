import AppKit

/// What CleanBar remembers of menu bar icons from when they were last in the menu bar: which app or macOS icon each one
/// is, its place and a picture of it. The floating bar shows hidden icons from this, since they're out of the menu bar
/// then and can't be pictured. Pictures are taken as CleanBar starts, in the layout editor, when an icon is opened from
/// the floating bar, and the first time an app whose icons are hidden opens. It's kept in CleanBar's caches folder, so
/// it's still there after a restart.
///
/// Icons go by their `placeKey`: macOS's own by their identifier, other apps' by app and position among the app's icons.
final class IconMemory {
    private var records: [String: Record] = [:]
    private var pictures: [String: ItemPicture] = [:]
    private var saveTask: Task<Void, Never>?

    init() {
        load()
    }

    /// Remembers the icons drawn in the menu bar, with their pictures (by item id). Only while every icon is in the menu
    /// bar do their places give the icons' order, and do icons that aren't drawn show which ones are turned off.
    func remember(_ scan: MenuBarScan, pictures newPictures: [String: ItemPicture], isFullMenuBar: Bool) {
        var changed = false
        for item in scan.items where item.controlRole == nil {
            let key = item.placeKey
            if item.isOnScreen {
                var record = Record(item)
                if !isFullMenuBar, let place = records[key]?.frame {
                    record.frame = place
                }
                // The layout editor hands in the pictures it has again and again: those are stored already.
                if let picture = newPictures[item.id], pictures[key].map({ !$0.isSame(as: picture) }) ?? true {
                    record.picture = StoredPicture(picture)
                    pictures[key] = picture
                } else {
                    record.picture = records[key]?.picture
                }
                if records[key] != record {
                    records[key] = record
                    changed = true
                }
            } else if isFullMenuBar, scan.isTurnedOff(item), records[key]?.isTurnedOff != true {
                var record = records[key] ?? Record(item)
                record.isTurnedOff = true
                records[key] = record
                changed = true
            }
        }
        if changed {
            scheduleSave()
        }
    }

    func picture(for item: MenuBarItem) -> ItemPicture? {
        pictures[item.placeKey]
    }

    /// Where the item was while every icon was in the menu bar, for putting icons in menu bar order.
    func place(of item: MenuBarItem) -> CGFloat {
        records[item.placeKey]?.frame.minX ?? item.frame.minX
    }

    /// Turned off under System Settings → Menu Bar when CleanBar last looked, so it isn't in the menu bar even when
    /// allowed.
    func isTurnedOff(_ item: MenuBarItem) -> Bool {
        records[item.placeKey]?.isTurnedOff == true
    }

    /// Remembers icons macOS didn't draw even while allowed: they're turned off under System Settings → Menu Bar. They
    /// count as on again once they're drawn.
    func rememberTurnedOff(_ items: [MenuBarItem]) {
        var changed = false
        for item in items where item.controlRole == nil && records[item.placeKey]?.isTurnedOff != true {
            var record = records[item.placeKey] ?? Record(item)
            record.isTurnedOff = true
            records[item.placeKey] = record
            changed = true
        }
        if changed {
            scheduleSave()
        }
    }

    /// Whether CleanBar has seen any of the app's icons: has a picture of one, or found it turned off.
    func knowsIcons(ofApp bundleID: String) -> Bool {
        records.contains { key, record in
            record.bundleID == bundleID && (record.isTurnedOff || pictures[key] != nil)
        }
    }

    /// The remembered icons of these apps, as items of the apps as they run now. macOS's own icons go with its menu bar
    /// process.
    func items(of apps: [ScanTarget]) -> [MenuBarItem] {
        let appsByBundleID = Dictionary(apps.compactMap { app in app.bundleID.map { ($0, app) } }) { first, _ in first }
        return records.values.compactMap { record in
            record.bundleID.flatMap { appsByBundleID[$0] }.map(record.item)
        }
    }

    // MARK: Keeping it

    private static var fileURL: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return caches.appending(path: Bundle.main.bundleIdentifier ?? "CleanBar").appending(path: "Icons.plist")
    }

    private func load() {
        guard let url = Self.fileURL, let data = try? Data(contentsOf: url),
              let saved = try? PropertyListDecoder().decode([String: Record].self, from: data)
        else { return }
        records = saved
        pictures = saved.compactMapValues { $0.picture?.itemPicture }
    }

    /// Saves a moment after the last change, since the layout editor reads the menu bar often.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, let url = Self.fileURL else { return }
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            guard let data = try? encoder.encode(self.records) else { return }
            await Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }.value
        }
    }
}

/// One remembered icon, as it's saved.
private nonisolated struct Record: Codable, Equatable {
    var itemID: String
    var axIndex: Int
    var bundleID: String?
    var identifier: String?
    var label: String?
    var frame: CGRect
    var supportsPress: Bool
    var isTurnedOff = false
    var picture: StoredPicture?

    init(_ item: MenuBarItem) {
        itemID = item.id
        axIndex = item.axIndex
        bundleID = item.bundleID
        identifier = item.identifier
        label = item.label
        frame = item.frame
        supportsPress = item.supportsPress
    }

    /// The icon as an item of its app as it runs now. It isn't in the menu bar.
    func item(of app: ScanTarget) -> MenuBarItem {
        MenuBarItem(
            id: itemID,
            pid: app.pid,
            axIndex: axIndex,
            bundleID: bundleID,
            appName: app.name,
            appPath: app.path,
            identifier: identifier,
            label: label,
            frame: frame,
            strip: nil,
            isOnScreen: false,
            controlRole: nil,
            supportsPress: supportsPress
        )
    }
}

/// An `ItemPicture` as PNGs.
private nonisolated struct StoredPicture: Codable, Equatable {
    var glyph: Data?
    var color: Data?
    var size: CGSize

    init(_ picture: ItemPicture) {
        glyph = picture.glyph.flatMap(Self.png)
        color = picture.color.flatMap(Self.png)
        size = picture.size
    }

    var itemPicture: ItemPicture? {
        let glyph = glyph.flatMap(NSImage.init(data:))
        let color = color.flatMap(NSImage.init(data:))
        guard glyph != nil || color != nil else { return nil }
        // PNGs load at one point per pixel.
        glyph?.size = size
        glyph?.isTemplate = true
        color?.size = size
        return ItemPicture(glyph: glyph, color: color, size: size)
    }

    private static func png(_ image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}

private extension ItemPicture {
    /// Whether it's the very same picture, not just one that looks the same.
    func isSame(as other: ItemPicture) -> Bool {
        glyph === other.glyph && color === other.color
    }
}
