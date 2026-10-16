import AppKit

/// The languages CleanBar comes in, and the one it shows itself in. macOS picks that one as CleanBar starts: the language
/// its settings name (`AppSettings.language`), or else the first of the Mac's languages (System Settings → General →
/// Language & Region) that CleanBar comes in, or else English. Switching takes a restart.
enum AppLanguage {
    /// Codes of the languages CleanBar comes in ("en", "es"), by name.
    static let available: [String] = {
        let codes = Set(Bundle.main.localizations + [Bundle.main.developmentLocalization ?? "en"]).subtracting(["Base"])
        return codes.sorted { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending }
    }()

    /// The language CleanBar shows itself in, picked when it started.
    static let current = Bundle.main.preferredLocalizations.first ?? "en"

    /// The language CleanBar picks when its settings don't name one.
    static var systemDefault: String {
        // The Mac's languages, without CleanBar's own choice, which comes first in `Locale.preferredLanguages`.
        let languages = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        return Bundle.preferredLocalizations(from: available, forPreferences: languages ?? Locale.preferredLanguages).first ?? "en"
    }

    /// The language's name in that language, as menus of languages list them ("English", "Español").
    static func name(of code: String) -> String {
        let locale = Locale(identifier: code)
        guard let name = locale.localizedString(forLanguageCode: code) else { return code }
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// `text` in the language `code`, to say something in it while CleanBar shows another. English has no translations
    /// to look up, as CleanBar's text is written in it, so looking in a language's own `.lproj` wouldn't do.
    static func string(_ text: LocalizedStringResource, in code: String) -> String {
        var text = text
        text.locale = Locale(identifier: code)
        return String(localized: text)
    }

    // MARK: Restarting

    private static let restartKey = "restartedForLanguage"

    /// Quits CleanBar and opens it again in the language its settings name now, with its settings open at General.
    static func restart() {
        UserDefaults.standard.set(true, forKey: restartKey)
        NSApp.relaunch()
    }

    /// Whether CleanBar has just restarted to switch languages. Called once, at launch.
    static func didRestart() -> Bool {
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: restartKey) }
        return defaults.bool(forKey: restartKey)
    }
}
