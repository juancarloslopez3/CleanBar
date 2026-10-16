import AppKit
import Observation

struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    /// Raw value of the `NSEvent.ModifierFlags` (⌘ ⌥ ⌃ ⇧ only).
    var modifiers: UInt
    var keyLabel: String

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var displayString: String {
        let flags = modifierFlags
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        // "Space" is stored in English, and shown in CleanBar's language.
        return result + (keyLabel == "Space" ? String(localized: "Space") : keyLabel)
    }
}

/// The icons CleanBar hides: other apps' icons app by app, and macOS's own icons one by one.
nonisolated struct HiddenIcons: Sendable {
    var bundleIDs: Set<String> = []
    var systemItems: Set<SystemMenuItem> = []

    var isEmpty: Bool { bundleIDs.isEmpty && systemItems.isEmpty }

    /// The item's app, or the item alone when it's one of macOS's own.
    init(_ item: MenuBarItem) {
        if let systemItem = item.systemItem {
            systemItems = [systemItem]
        } else if let bundleID = item.bundleID {
            bundleIDs = [bundleID]
        }
    }

    init(bundleIDs: Set<String> = [], systemItems: Set<SystemMenuItem> = []) {
        self.bundleIDs = bundleIDs
        self.systemItems = systemItems
    }

    func contains(_ item: MenuBarItem) -> Bool {
        if let systemItem = item.systemItem {
            return systemItems.contains(systemItem)
        }
        return item.bundleID.map(bundleIDs.contains) ?? false
    }

    func subtracting(_ other: HiddenIcons) -> HiddenIcons {
        HiddenIcons(bundleIDs: bundleIDs.subtracting(other.bundleIDs), systemItems: systemItems.subtracting(other.systemItems))
    }

    func union(_ other: HiddenIcons) -> HiddenIcons {
        HiddenIcons(bundleIDs: bundleIDs.union(other.bundleIDs), systemItems: systemItems.union(other.systemItems))
    }
}

/// How CleanBar's icon and the shortcut show the hidden icons.
nonisolated enum HiddenIconsStyle: String, CaseIterable, Identifiable, Sendable {
    /// Back in the menu bar, where they were.
    case inMenuBar
    /// In a small bar that floats below CleanBar's icon, while they stay out of the menu bar. Clicking an icon there
    /// brings it back in the menu bar for as long as its menu is open.
    case floatingBar

    var id: Self { self }

    var title: String {
        switch self {
        case .inMenuBar: String(localized: "In the Menu Bar")
        case .floatingBar: String(localized: "In a Floating Bar")
        }
    }
}

/// What shows the hidden icons, besides the shortcut. CleanBar's icon shows them too, whichever is chosen, while it's in
/// the menu bar.
nonisolated enum ShowHiddenIconsTrigger: String, CaseIterable, Identifiable, Sendable {
    case iconClick
    /// The pointer resting on a part of the menu bar with no menu or icon. They go again once it leaves the menu bar.
    case emptySpaceHover
    /// A click on a part of the menu bar with no menu or icon. Another one hides them again.
    case emptySpaceClick

    var id: Self { self }

    var title: String {
        switch self {
        case .iconClick: String(localized: "Click the CleanBar icon")
        case .emptySpaceHover: String(localized: "Hover over an empty space in the menu bar")
        case .emptySpaceClick: String(localized: "Click an empty space in the menu bar")
        }
    }
}

/// The symbol CleanBar's icon shows in the menu bar. `ControlItem` draws them.
nonisolated enum MenuBarIconStyle: String, CaseIterable, Identifiable, Sendable {
    case circle
    case dots
    case dot
    case star
    case arrow

    var id: Self { self }

    var title: String {
        switch self {
        case .circle: String(localized: "Circle")
        case .dots: String(localized: "Three Dots")
        case .dot: String(localized: "Dot")
        case .star: String(localized: "Star")
        case .arrow: String(localized: "Arrow")
        }
    }
}

/// How CleanBar's windows, menus and floating bar look. Its icon always looks like the rest of the menu bar.
nonisolated enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    /// Light or dark like the Mac, switching when it does (System Settings → Appearance).
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: String(localized: "Automatic")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    /// The appearance for `NSApp.appearance`. Nil follows the Mac's.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// User preferences, stored in `UserDefaults`. Every change is also broadcast through `AppSettings.didChange`.
@Observable
final class AppSettings {
    static let shared = AppSettings()
    static let didChange = Notification.Name("CleanBarSettingsDidChange")

    private enum Key {
        static let hiddenBundleIDs = "hiddenBundleIDs"
        static let hiddenSystemItems = "hiddenSystemItems"
        static let hidesNewIcons = "hidesNewIcons"
        static let newIconsPlace = "newIconsPlace"
        static let knownBundleIDs = "knownBundleIDs"
        static let hiddenIconsStyle = "hiddenIconsStyle"
        static let showHiddenIconsTrigger = "showHiddenIconsTrigger"
        static let iconStyle = "iconStyle"
        static let hidesIcon = "hidesIcon"
        static let autoHide = "autoHide"
        static let autoHideDelay = "autoHideDelay"
        static let hotKey = "hotKey"
        static let appearance = "appearance"
        /// macOS's own key for the languages an app prefers.
        static let language = "AppleLanguages"
    }

    /// Apps whose menu bar icons CleanBar hides. Hiding works per app, so all of an app's icons go together.
    var hiddenBundleIDs: Set<String> {
        didSet { save(hiddenBundleIDs.sorted(), Key.hiddenBundleIDs) }
    }

    /// macOS's own icons CleanBar hides, stored by their Accessibility identifiers.
    var hiddenSystemItems: Set<SystemMenuItem> {
        didSet { save(hiddenSystemItems.map(\.identifier).sorted(), Key.hiddenSystemItems) }
    }

    var hiddenIcons: HiddenIcons { HiddenIcons(bundleIDs: hiddenBundleIDs, systemItems: hiddenSystemItems) }

    /// Hide the icons of apps CleanBar hasn't seen before, instead of showing them. It's where the layout editor's
    /// "New icons appear here" marker is.
    var hidesNewIcons: Bool {
        didSet { save(hidesNewIcons, Key.hidesNewIcons) }
    }

    /// Where in its row the marker is. New icons are moved there, like a person ⌘-drags them. Nil until the marker is
    /// dropped somewhere: new icons then stay where macOS puts them.
    var newIconsPlace: NewIconsPlace? {
        didSet { save(newIconsPlace?.propertyList, Key.newIconsPlace) }
    }

    /// Apps CleanBar has seen running, to tell which apps are new. Nil until CleanBar first looks.
    @ObservationIgnored private var knownBundleIDs: Set<String>?

    /// Where CleanBar's icon and the shortcut show the hidden icons.
    var hiddenIconsStyle: HiddenIconsStyle {
        didSet { save(hiddenIconsStyle.rawValue, Key.hiddenIconsStyle) }
    }

    /// What else shows the hidden icons, besides CleanBar's icon and the shortcut. Never `.iconClick` while the icon is
    /// hidden.
    var showHiddenIconsTrigger: ShowHiddenIconsTrigger {
        didSet { save(showHiddenIconsTrigger.rawValue, Key.showHiddenIconsTrigger) }
    }

    var iconStyle: MenuBarIconStyle {
        didSet { save(iconStyle.rawValue, Key.iconStyle) }
    }

    /// Keep CleanBar's icon out of the menu bar. Empty space in the menu bar shows the hidden icons then, since the icon
    /// can't, and opening CleanBar again shows its settings.
    var hidesIcon: Bool {
        didSet {
            if hidesIcon, showHiddenIconsTrigger == .iconClick {
                showHiddenIconsTrigger = .emptySpaceClick
            }
            save(hidesIcon, Key.hidesIcon)
        }
    }

    /// Hide shown icons again after `autoHideDelay` seconds.
    var autoHide: Bool {
        didSet { save(autoHide, Key.autoHide) }
    }

    /// Whole seconds in `autoHideDelays`.
    var autoHideDelay: Double {
        didSet { save(autoHideDelay, Key.autoHideDelay) }
    }

    static let autoHideDelays: ClosedRange<Double> = 1...60

    /// The nearest delay CleanBar allows.
    static func autoHideDelay(_ seconds: Double) -> Double {
        min(max(seconds.rounded(), autoHideDelays.lowerBound), autoHideDelays.upperBound)
    }

    var hotKey: HotKeyCombo? {
        didSet { save(hotKey.flatMap { try? JSONEncoder().encode($0) }, Key.hotKey) }
    }

    /// Light or dark for CleanBar's windows, or `.system` to look like the Mac. It takes effect right away.
    var appearance: AppAppearance {
        // Nothing in the menu bar changes with it, so there's nothing to broadcast.
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            NSApp.appearance = appearance.nsAppearance
        }
    }

    /// The language CleanBar shows itself in, one of `AppLanguage.available`, or nil for the Mac's language. It's the
    /// language macOS keeps for CleanBar (System Settings → General → Language & Region → Applications sets it too), and
    /// macOS applies it when CleanBar starts.
    var language: String? {
        // Nothing running changes with it, so there's nothing to broadcast.
        didSet { defaults.set(language.map { [$0] }, forKey: Key.language) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.autoHide: true,
            Key.autoHideDelay: 8.0,
        ])
        hiddenBundleIDs = Set(defaults.stringArray(forKey: Key.hiddenBundleIDs) ?? [])
        hiddenSystemItems = Set((defaults.stringArray(forKey: Key.hiddenSystemItems) ?? [])
            .compactMap(SystemMenuItem.init(identifier:))
            .filter(\.canBeHidden))
        hidesNewIcons = defaults.bool(forKey: Key.hidesNewIcons)
        newIconsPlace = defaults.object(forKey: Key.newIconsPlace).flatMap(NewIconsPlace.init(propertyList:))
        knownBundleIDs = defaults.stringArray(forKey: Key.knownBundleIDs).map(Set.init)
        hiddenIconsStyle = defaults.string(forKey: Key.hiddenIconsStyle).flatMap(HiddenIconsStyle.init(rawValue:)) ?? .inMenuBar
        iconStyle = defaults.string(forKey: Key.iconStyle).flatMap(MenuBarIconStyle.init(rawValue:)) ?? .circle
        let hidesIcon = defaults.bool(forKey: Key.hidesIcon)
        self.hidesIcon = hidesIcon
        let trigger = defaults.string(forKey: Key.showHiddenIconsTrigger).flatMap(ShowHiddenIconsTrigger.init(rawValue:)) ?? .iconClick
        showHiddenIconsTrigger = hidesIcon && trigger == .iconClick ? .emptySpaceClick : trigger
        autoHide = defaults.bool(forKey: Key.autoHide)
        autoHideDelay = Self.autoHideDelay(defaults.double(forKey: Key.autoHideDelay))
        hotKey = defaults.data(forKey: Key.hotKey).flatMap { try? JSONDecoder().decode(HotKeyCombo.self, from: $0) }
        appearance = defaults.string(forKey: Key.appearance).flatMap(AppAppearance.init(rawValue:)) ?? .system
        // CleanBar's own languages only: `stringArray(forKey:)` would fall back to the Mac's.
        let languages = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[Key.language] as? [String]
        language = languages.flatMap { Bundle.preferredLocalizations(from: AppLanguage.available, forPreferences: $0).first }
    }

    /// Remembers the apps as seen and returns those never seen before. The first time, every app counts as seen, so
    /// nothing already in the menu bar is taken for new.
    func noteSeenApps(_ bundleIDs: some Sequence<String>) -> Set<String> {
        let seen = Set(bundleIDs)
        let new = knownBundleIDs.map(seen.subtracting) ?? []
        guard knownBundleIDs == nil || !new.isEmpty else { return [] }
        let known = (knownBundleIDs ?? []).union(seen)
        knownBundleIDs = known
        // Not a preference, so there's nothing to broadcast.
        defaults.set(known.sorted(), forKey: Key.knownBundleIDs)
        return new
    }

    private func save(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
