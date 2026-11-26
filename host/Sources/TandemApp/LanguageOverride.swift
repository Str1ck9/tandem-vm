import Foundation

/// A language for this run only, for self-tests and scripts: `TANDEM_LANG=es`. It acts like the
/// `-AppleLanguages "(es)"` command-line flag, in the argument domain, so nothing is saved.
/// `TANDEM_LANG_SHOW_MISSING=1` also writes every string that has no translation in capitals
/// (AppKit's `NSShowNonLocalizedStrings`), which shows what a language still lacks.
enum LanguageOverride {
    static func apply(environment: [String: String] = ProcessInfo.processInfo.environment, defaults: UserDefaults = .standard) {
        guard let language = environment["TANDEM_LANG"], !language.isEmpty else { return }
        var values: [String: Any] = ["AppleLanguages": [language], "AppleLocale": language]
        if environment["TANDEM_LANG_SHOW_MISSING"] != nil { values["NSShowNonLocalizedStrings"] = true }
        defaults.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
    }
}
