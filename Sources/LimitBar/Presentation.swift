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
        case .claude: return inApp ? "Apri l'utilizzo nell'app Claude" : "Apri l'utilizzo su claude.ai"
        case .codex: return inApp ? "Apri le impostazioni dell'app Codex" : "Apri l'utilizzo su chatgpt.com"
        case .opencode: return inApp ? "Apri OpenCode" : "Apri la pagina di OpenCode Go"
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
    private static func formatter(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = pattern
        return f
    }

    private static let time = formatter("HH:mm")
    private static let weekday = formatter("EEE")
    private static let date = formatter("d MMM")
    private static let weekdayDate = formatter("EEE d MMM")

    /// "tra 1 h 20 min", "tra 3 g 4 h": how long until a reset.
    static func countdown(_ date: Date?, now: Date) -> String? {
        guard let date, date > now else { return nil }
        let minutes = Int(date.timeIntervalSince(now) / 60)
        let days = minutes / 1440, hours = (minutes % 1440) / 60, rest = minutes % 60
        if days > 0 { return hours > 0 ? "tra \(days) g \(hours) h" : "tra \(days) g" }
        if hours > 0 { return rest > 0 ? "tra \(hours) h \(rest) min" : "tra \(hours) h" }
        return "tra \(max(rest, 1)) min"
    }

    /// The time left in the menu bar, where there's little room: "42m", "1h05", "3g4h".
    static func shortCountdown(_ date: Date, now: Date) -> String? {
        guard date > now else { return nil }
        let minutes = Int(date.timeIntervalSince(now) / 60)
        let days = minutes / 1440, hours = (minutes % 1440) / 60, rest = minutes % 60
        if days > 0 { return hours > 0 ? "\(days)g\(hours)h" : "\(days)g" }
        if hours > 0 { return "\(hours)h" + String(format: "%02d", rest) }
        return "\(max(rest, 1))m"
    }

    /// "+40% su settembre", "−12% su settembre", "pari a settembre", "×3,1 su settembre" once
    /// it's at least double.
    static func change(_ comparison: MonthComparison) -> String {
        let month = self.month(comparison.previousMonth)
        let ratio = comparison.current / comparison.previous
        if ratio >= 2 { return "\(multiple(ratio)) su \(month)" }
        let percent = Int(((ratio - 1) * 100).rounded())
        if percent == 0 { return "pari a \(month)" }
        return (percent > 0 ? "+\(percent)%" : "−\(-percent)%") + " su \(month)"
    }

    /// "Dal 1° al 22 settembre: 129 €. Stime a prezzi API."
    static func comparisonNote(_ comparison: MonthComparison) -> String {
        let month = self.month(comparison.previousMonth)
        let days = comparison.throughDay == 1 ? "Il 1° \(month)" : "Dal 1° al \(comparison.throughDay) \(month)"
        return "\(days): \(euros(fromDollars: comparison.previous)). Stime a prezzi API."
    }

    /// How long something took: "6 min", "1 h 12 min", "2 h".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(Int(seconds / 60), 1)
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest > 0 ? "\(hours) h \(rest) min" : "\(hours) h"
    }

    /// "sab 24 ott · 12:01", for the panel's header.
    static func stamp(_ date: Date) -> String {
        weekdayDate.string(from: date) + " · " + time.string(from: date)
    }

    /// "alle 12:40" today, "domani alle 05:06", "gio alle 09:17" within the week, "lun 2 nov
    /// alle 18:00" further on, where a weekday alone would be ambiguous (monthly limits).
    static func at(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let clock = "alle " + time.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return clock }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "domani " + clock
        }
        if date.timeIntervalSince(now) < 6 * 86400 { return weekday.string(from: date) + " " + clock }
        return weekdayDate.string(from: date) + " " + clock
    }

    /// "l'82%", "il 90%": a percentage with its article, as a sentence needs it.
    static func percentWithArticle(_ value: Double) -> String {
        let number = Int(value.rounded())
        // Read aloud, 1, 8, 11 and 80-89 start with a vowel: "l'uno", "l'ottanta", "l'undici".
        let vowel = number == 1 || number == 11 || String(number).hasPrefix("8")
        return (vowel ? "l'" : "il ") + "\(number)%"
    }

    private static let monthName = formatter("LLLL")

    /// "ottobre"
    static func month(_ date: Date) -> String { monthName.string(from: date) }

    /// "8,42" with `digits` decimals.
    private static func decimal(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "it_IT")))
    }

    /// A dollar amount in euros at the ECB rate: "8,42 €" below 100 euros, "143 €" above,
    /// since it's an estimate and cents stop mattering.
    static func euros(fromDollars dollars: Double) -> String {
        let value = ExchangeRate.shared.euros(fromDollars: dollars)
        return decimal(value, digits: value < 100 ? 2 : 0) + " €"
    }

    /// Dollars as OpenCode Go counts them: "2,40 $", "143 $" from 100 up.
    static func dollars(_ value: Double) -> String {
        decimal(value, digits: value < 100 ? 2 : 0) + " $"
    }

    /// Whole euros, for amounts that line up in a column: "179 €", "6 €", "< 1 €".
    static func wholeEuros(fromDollars dollars: Double) -> String {
        let value = ExchangeRate.shared.euros(fromDollars: dollars)
        if value > 0 && value < 0.5 { return "< 1 €" }
        return decimal(value, digits: 0) + " €"
    }

    /// An axis label of the Spesa chart: "50 €", or "0,5 €" when the axis tops out under 10 €,
    /// where whole euros would repeat.
    static func axisEuros(_ value: Double, top: Double) -> String {
        decimal(value, digits: top < 10 ? 1 : 0) + " €"
    }

    /// "3 nov", for a day in the Spesa chart.
    static func day(_ day: Date) -> String { date.string(from: day) }

    /// "22 ott": the date of the ECB rate in use.
    static func rateDate(_ day: String) -> String {
        isoDay.date(from: day).map(date.string) ?? day
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "×8,0"
    static func multiple(_ value: Double) -> String {
        "×" + decimal(value, digits: 1)
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return "adesso"
        case ..<3600: return "\(Int(seconds / 60)) min fa"
        case ..<86400: return "\(Int(seconds / 3600)) h fa"
        default: return "\(Int(seconds / 86400)) g fa"
        }
    }
}
