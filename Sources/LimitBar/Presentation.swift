import AppKit
import SwiftUI

// How services and times are shown: shared by the panel, the notifications and the iCloud copy.

extension ProviderID {
    var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        }
    }

    /// What the panel says under the name before the service has answered with its plan.
    var toolName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        case .opencode: return "OpenCode Go"
        }
    }

    /// The service's desktop app.
    var appBundleID: String {
        switch self {
        case .claude: return "com.anthropic.claudefordesktop"
        case .codex: return "com.openai.codex"
        case .opencode: return "ai.opencode.desktop"
        }
    }

    var appIsInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID) != nil }

    /// The glyph that stands for the service in the menu bar.
    var glyph: Logo {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .opencode: return .opencode
        }
    }

    /// Built once: each icon is read from its app and rasterized to find its visible shape,
    /// far too much work to repeat on every redraw of the panel.
    private static let logos: [ProviderID: NSImage] = [
        .claude: Icons.panelLogo(.claude),
        .codex: Icons.panelLogo(.codex),
        .opencode: Icons.panelLogo(.opencode),
    ]

    var logo: NSImage { Self.logos[self]! }

    /// The service's own usage page, opened by clicking its row in the panel.
    var usageURL: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/settings/usage")!
        case .codex: return URL(string: "https://chatgpt.com/settings/usage")!
        case .opencode: return URL(string: "https://opencode.ai/docs/go/")!
        }
    }

    /// The usage page inside the service's desktop app. Claude's app opens
    /// `claude://claude.ai/settings/…` in its own window. The Codex app has no link to its usage
    /// section (`codex://settings/usage` isn't one it accepts), so its Settings open instead.
    /// OpenCode's app opens itself; its Go limits are only in a web console that needs the account.
    var usageAppURL: URL? {
        switch self {
        case .claude: return URL(string: "claude://claude.ai/settings/usage")
        case .codex: return URL(string: "codex://settings")
        case .opencode: return URL(string: "opencode://")
        }
    }

    /// Opens the usage page in the desktop app if it's installed, otherwise in the browser.
    func openUsagePage() {
        if let appURL = usageAppURL, NSWorkspace.shared.urlForApplication(toOpen: appURL) != nil {
            NSWorkspace.shared.open(appURL)
        } else {
            NSWorkspace.shared.open(usageURL)
        }
    }

    /// What a click on the row opens, for its tooltip.
    var usageDestination: String {
        let inApp = usageAppURL.map { NSWorkspace.shared.urlForApplication(toOpen: $0) != nil } ?? false
        switch self {
        case .claude: return inApp ? L("Open usage in the Claude app") : L("Open usage on claude.ai")
        case .codex: return inApp ? L("Open the Codex app's settings") : L("Open usage on chatgpt.com")
        case .opencode: return inApp ? L("Open OpenCode") : L("Open the OpenCode Go page")
        }
    }

    var tint: Color {
        switch self {
        case .claude: return Color(nsColor: Icons.claudeOrange)
        case .codex: return Color(nsColor: Icons.codexViolet)
        case .opencode: return Color(nsColor: Icons.openCodePink)
        }
    }
}

enum Format {
    /// The language LimitBar shows with the Mac's region, so dates and numbers read like the
    /// text around them ("31 ott", "Oct 31"). Tests set it.
    static var locale: Locale = {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale(identifier: Locale.current.region.map { "\(language)_\($0.identifier)" } ?? language)
    }()

    /// Whether the text is Italian, for the one rule a translation can't carry (see percentWithArticle).
    static var isItalian: Bool { locale.language.languageCode?.identifier == "it" }

    /// A formatter for `template` ("EEEdMMM", "jjmm"), laid out as the language does it.
    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    private static var time: DateFormatter { formatter("jjmm") }
    private static var weekday: DateFormatter { formatter("EEE") }
    private static var date: DateFormatter { formatter("dMMM") }
    private static var weekdayDate: DateFormatter { formatter("EEEdMMM") }

    /// "in 1 h 20 min", "in 3 d 4 h": how long until a reset.
    static func countdown(_ date: Date?, now: Date) -> String? {
        guard let date, date > now else { return nil }
        let minutes = Int(date.timeIntervalSince(now) / 60)
        let days = minutes / 1440, hours = (minutes % 1440) / 60, rest = minutes % 60
        if days > 0 { return hours > 0 ? L("in %d d %d h", days, hours) : L("in %d d", days) }
        if hours > 0 { return rest > 0 ? L("in %d h %d min", hours, rest) : L("in %d h", hours) }
        return L("in %d min", max(rest, 1))
    }

    /// The time left in the menu bar, where there's little room: "42m", "1h05", "3d4h".
    static func shortCountdown(_ date: Date, now: Date) -> String? {
        guard date > now else { return nil }
        let minutes = Int(date.timeIntervalSince(now) / 60)
        let days = minutes / 1440, hours = (minutes % 1440) / 60, rest = minutes % 60
        if days > 0 { return hours > 0 ? L("%dd%dh", days, hours) : L("%dd", days) }
        if hours > 0 { return "\(hours)h" + String(format: "%02d", rest) }
        return "\(max(rest, 1))m"
    }

    /// "+40% vs September", "−12% vs September", "same as September", "×3.1 vs September" once
    /// it's at least double.
    static func change(_ comparison: MonthComparison) -> String {
        let month = self.month(comparison.previousMonth)
        let ratio = comparison.current / comparison.previous
        if ratio >= 2 { return L("%@ vs %@", multiple(ratio), month) }
        let percent = Int(((ratio - 1) * 100).rounded())
        if percent == 0 { return L("same as %@", month) }
        return L("%@ vs %@", percent > 0 ? "+\(percent)%" : "−\(-percent)%", month)
    }

    /// "September 1 to 22: €129. Estimates at API prices."
    static func comparisonNote(_ comparison: MonthComparison) -> String {
        let month = self.month(comparison.previousMonth)
        let days = comparison.throughDay == 1 ? L("%@ 1", month) : L("%@ 1 to %d", month, comparison.throughDay)
        return L("%@: %@. Estimates at API prices.", days, money(comparison.previous))
    }

    /// How long something took: "6 min", "1 h 12 min", "2 h".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(Int(seconds / 60), 1)
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return L("%d min", rest) }
        return rest > 0 ? L("%d h %d min", hours, rest) : L("%d h", hours)
    }

    /// "Sat, 24 Oct · 12:01", for the panel's header.
    static func stamp(_ date: Date) -> String {
        weekdayDate.string(from: date) + " · " + time.string(from: date)
    }

    /// "at 12:40" today, "tomorrow at 05:06", "Thu at 09:17" within the week, "Mon, 2 Nov at
    /// 18:00" further on, where a weekday alone would be ambiguous (monthly limits).
    static func at(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let clock = time.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return L("at %@", clock) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return L("tomorrow at %@", clock)
        }
        let day = date.timeIntervalSince(now) < 6 * 86400 ? weekday.string(from: date) : weekdayDate.string(from: date)
        return L("%@ at %@", day, clock)
    }

    /// "82%" in English; in Italian with its article, as a sentence needs it: "l'82%", "il 90%".
    static func percentWithArticle(_ value: Double) -> String {
        let number = Int(value.rounded())
        guard isItalian else { return "\(number)%" }
        // Read aloud, 1, 8, 11 and 80-89 start with a vowel: "l'uno", "l'ottanta", "l'undici".
        let vowel = number == 1 || number == 11 || String(number).hasPrefix("8")
        return (vowel ? "l'" : "il ") + "\(number)%"
    }

    /// "October", "ottobre"
    static func month(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = "LLLL"
        return f.string(from: date)
    }

    /// "8.42", "8,42" with `digits` decimals.
    private static func decimal(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).locale(locale))
    }

    /// `value` in `currency` with its symbol where the language puts it: "$8.42", "8,42 €".
    private static func amount(_ value: Double, _ currency: Currency, digits: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = locale
        f.currencyCode = currency.code
        // "$" rather than the "USD" or "US$" some languages and regions write.
        f.currencySymbol = currency.symbol
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: value)) ?? decimal(value, digits: digits) + " " + currency.symbol
    }

    /// API prices are in dollars: in the chosen currency (see Currency), euros at the ECB rate.
    static func convert(_ dollars: Double) -> Double {
        Currency.current == .euro ? ExchangeRate.shared.euros(fromDollars: dollars) : dollars
    }

    /// A value at API prices in the chosen currency: "€8.42" below 100, "€143" above, since
    /// it's an estimate and cents stop mattering.
    static func money(_ dollars: Double) -> String {
        let value = convert(dollars)
        return amount(value, Currency.current, digits: value < 100 ? 2 : 0)
    }

    /// Dollars as OpenCode Go counts them, whatever the chosen currency: "$2.40", "$143" from 100 up.
    static func dollars(_ value: Double) -> String {
        amount(value, .dollar, digits: value < 100 ? 2 : 0)
    }

    /// Whole amounts, for values that line up in a column: "€179", "€6", "< €1".
    static func wholeMoney(_ dollars: Double) -> String {
        let value = convert(dollars)
        if value > 0 && value < 0.5 { return "< " + amount(1, Currency.current, digits: 0) }
        return amount(value, Currency.current, digits: 0)
    }

    /// An axis label of the Spending chart, `value` already converted: "€50", or "€0.5" when the
    /// axis tops out under 10, where whole amounts would repeat.
    static func axisMoney(_ value: Double, top: Double) -> String {
        amount(value, Currency.current, digits: top < 10 ? 1 : 0)
    }

    /// "Nov 3", "3 nov", for a day in the Spending chart.
    static func day(_ day: Date) -> String { date.string(from: day) }

    /// "Oct 22", "22 ott": the date of the ECB rate in use.
    static func rateDate(_ day: String) -> String {
        isoDay.date(from: day).map(date.string) ?? day
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "×8.0", "×8,0"
    static func multiple(_ value: Double) -> String {
        "×" + decimal(value, digits: 1)
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return L("just now")
        case ..<3600: return L("%d min ago", Int(seconds / 60))
        case ..<86400: return L("%d h ago", Int(seconds / 3600))
        default: return L("%d d ago", Int(seconds / 86400))
        }
    }
}
