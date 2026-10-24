import Foundation

/// Dollars to euros at the European Central Bank's daily reference rate, for showing API prices
/// (published in dollars) in euros. Fetched at most twice a day and remembered, so it also works
/// offline; before the first fetch it uses the rate of 22 Oct 2026.
final class ExchangeRate {
    static let shared = ExchangeRate()

    private static let source = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!
    private static let fallbackDollarsPerEuro = 1.1205
    private static let fallbackDate = "2026-10-22"
    private static let refreshAfter: TimeInterval = 12 * 3600

    private let defaults = UserDefaults.standard
    private let lock = NSLock()

    /// How many dollars one euro buys, as the ECB publishes it.
    var dollarsPerEuro: Double {
        lock.withLock { defaults.object(forKey: "fx.usdPerEur") as? Double ?? Self.fallbackDollarsPerEuro }
    }

    /// The ECB's date for the rate in use (yyyy-MM-dd).
    var rateDate: String {
        lock.withLock { defaults.string(forKey: "fx.date") ?? Self.fallbackDate }
    }

    func euros(fromDollars dollars: Double) -> Double { dollars / dollarsPerEuro }

    /// Fetches today's rate unless a recent one is known; calls `changed` on main if it moved.
    func refreshIfNeeded(_ changed: @escaping () -> Void) {
        if let fetched = defaults.object(forKey: "fx.fetchedAt") as? Date,
           Date().timeIntervalSince(fetched) < Self.refreshAfter { return }
        URLSession.shared.dataTask(with: Self.source) { [self] data, _, _ in
            guard let data, let xml = String(data: data, encoding: .utf8),
                  let rate = Self.capture(#"currency='USD' rate='([0-9.]+)'"#, in: xml).flatMap(Double.init),
                  rate > 0 else { return }
            let date = Self.capture(#"time='(\d{4}-\d{2}-\d{2})'"#, in: xml)
            let moved = lock.withLock { () -> Bool in
                let old = defaults.object(forKey: "fx.usdPerEur") as? Double
                defaults.set(rate, forKey: "fx.usdPerEur")
                defaults.set(date, forKey: "fx.date")
                defaults.set(Date(), forKey: "fx.fetchedAt")
                return old != rate
            }
            if moved { DispatchQueue.main.async(execute: changed) }
        }.resume()
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
