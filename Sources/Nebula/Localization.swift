import Foundation

/// Localized text. Keys are the Italian strings; translations live in
/// Resources/Localization/<lang>.lproj/Localizable.strings (copied into the app),
/// so macOS picks the user's language automatically (English for anything else).
func tr(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

func tr(_ key: String, _ args: CVarArg...) -> String {
    String(format: tr(key), locale: Locale.current, arguments: args)
}
