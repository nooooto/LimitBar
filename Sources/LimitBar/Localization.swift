import Foundation

/// The text for `key`, an English phrase, in the language LimitBar shows: English, or another
/// language the app bundle has a translation for (it.lproj/Localizable.strings) when the Mac
/// prefers it. Outside the app bundle (tests, `swift run`) it's the English key itself.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// `key` translated, then filled in like `String(format:)`: "%d%% ahead", "in %d h %d min".
/// A translation may reorder the arguments with positional specifiers ("%2$d %1$@").
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), locale: Format.locale, arguments: arguments)
}

/// The currency the value at API prices is shown in: the API prices' own dollars, or euros at the
/// ECB's daily rate. Chosen in Settings; until then euros where the Mac's region uses them.
enum Currency: String, CaseIterable, Identifiable {
    case dollar, euro

    var id: String { rawValue }
    var code: String { self == .dollar ? "USD" : "EUR" }
    var symbol: String { self == .dollar ? "$" : "€" }
    var title: String { self == .dollar ? L("US dollars ($)") : L("Euros (€)") }

    static let defaultsKey = "settings.currency"

    static var current: Currency {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Currency.init(rawValue:))
            ?? (Locale.current.currency?.identifier == "EUR" ? .euro : .dollar)
    }
}

/// `text` translated where the same English needs different words in another language, told
/// apart by `context` ("Not started" for the week, and in the plural for the 5 hours).
func L(_ text: String, context: String) -> String {
    Bundle.main.localizedString(forKey: "\(text) [\(context)]", value: text, table: nil)
}
