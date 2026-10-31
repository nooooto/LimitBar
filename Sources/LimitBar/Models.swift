import Foundation

enum ProviderID: String, Codable, CaseIterable, Identifiable {
    case claude, codex, opencode
    var id: String { rawValue }

    /// Services switched off for now, with all their code kept: Codex (no subscription at the
    /// moment). Leaving them out of `allCases` takes them out of the settings, the panel, the
    /// menu bar, the widget and the log reading; taking one out of here brings it all back.
    static let retired: Set<ProviderID> = [.codex]

    static var allCases: [ProviderID] { [.claude, .codex, .opencode].filter { !retired.contains($0) } }

    var isActive: Bool { !Self.retired.contains(self) }

    /// Whether CostLedger prices the service's work: from Claude Code's and Codex's logs, and from
    /// the costs OpenCode records for each reply.
    var isInCostLedger: Bool { self == .claude || self == .codex || self == .opencode }

    /// Read from this Mac alone (OpenCode's database), so it needs no connection.
    var isLocal: Bool { self == .opencode }
}

struct UsageWindow: Codable, Equatable {
    var usedPercent: Double
    var resetsAt: Date?
    var windowMinutes: Int?

    /// Treated as used up: the servers report whole percents and may stop just short of 100.
    static let exhausted: Double = 99.5

    /// Once the reset time has passed the window is empty again, even if we haven't re-fetched yet.
    func effectivePercent(at now: Date) -> Double {
        if let resetsAt, resetsAt <= now { return 0 }
        return min(max(usedPercent, 0), 100)
    }
}

extension UsageWindow {
    /// Usage only grows until a window resets, so of two readings of the same window
    /// the higher one is the more recent; a later reset time means a newer window. A reading
    /// whose window has already reset says nothing about the current one.
    /// The window's length is the same whichever reading wins, so a reading that lacks it (an
    /// older cache) takes it from the other.
    static func merged(_ a: UsageWindow?, _ b: UsageWindow?, now: Date = Date()) -> UsageWindow? {
        guard var merged = pick(a, b, now: now) else { return nil }
        merged.windowMinutes = merged.windowMinutes ?? a?.windowMinutes ?? b?.windowMinutes
        return merged
    }

    private static func pick(_ a: UsageWindow?, _ b: UsageWindow?, now: Date) -> UsageWindow? {
        func over(_ window: UsageWindow?) -> Bool { window?.resetsAt.map { $0 <= now } ?? false }
        if over(b) { return a ?? b }
        if over(a) { return b ?? a }
        guard let a else { return b }
        guard let b else { return a }
        switch (a.resetsAt, b.resetsAt) {
        case let (ra?, rb?) where abs(ra.timeIntervalSince(rb)) > 60:
            return ra > rb ? a : b
        default:
            return a.usedPercent >= b.usedPercent ? a : b
        }
    }
}

extension ProviderSnapshot {
    /// `self` with each window raised to `other`'s reading of it when that is higher.
    func merging(windowsOf other: ProviderSnapshot?) -> ProviderSnapshot {
        guard let other else { return self }
        var result = self
        result.fiveHour = UsageWindow.merged(fiveHour, other.fiveHour)
        result.week = UsageWindow.merged(week, other.week)
        return result
    }
}

struct ExtraLimit: Codable, Equatable, Identifiable {
    var label: String
    var window: UsageWindow
    var id: String { label }
}

struct ProviderSnapshot: Codable, Equatable {
    var plan: String?
    var fiveHour: UsageWindow?
    var week: UsageWindow?
    var extras: [ExtraLimit] = []
    var note: String?
    var updatedAt: Date
    var source: String
    /// For a service whose models each have their own limits (OpenCode Go), how each is doing.
    var models: [ModelUsage]? = nil

    /// Made up for a layout render (see OpenCodeProvider): not to be cached or recorded.
    var isSample: Bool { source == "sample" }

    /// OpenCode's monthly limit, kept among the extras as "Mese".
    var month: UsageWindow? { extras.first { $0.label == OpenCodeProvider.monthLabel }?.window }

    /// The windows that stop the whole service once used up: the 5 hours, the week and
    /// OpenCode's month. A model's own week on Claude (extras) stops only that model.
    var blockingWindows: [UsageWindow] { [fiveHour, week, month].compactMap { $0 } }
}

/// One model's part in OpenCode Go's shared limits, in dollars over the last 30 days.
struct ModelUsage: Codable, Equatable, Identifiable {
    var name: String
    var requests: Int
    var spent: Double
    /// Free models have no limits: their windows have no cap.
    var isFree: Bool
    var fiveHour: ModelWindow
    var week: ModelWindow
    var month: ModelWindow
    /// The model chosen in OpenCode right now (optional so older cached snapshots still load).
    var isCurrent: Bool? = nil

    var id: String { name }
    var inUse: Bool { isCurrent == true }
}

/// Dollars a model used in a window, and its cap there (`cap`, nil for a free model): what the
/// whole window would hold if only this model were used.
struct ModelWindow: Codable, Equatable {
    var used: Double
    var cap: Double?

    /// How much of the shared window this model used, in percent (the shares add up).
    var share: Double { cap.map { $0 > 0 ? used / $0 * 100 : 0 } ?? 0 }
}

struct ProviderState {
    var snapshot: ProviderSnapshot?
    var error: String?
    var needsSignIn = false
    /// Non-alarming status, e.g. updates paused by the server; the shown data is still valid.
    var notice: String?
}

enum ProviderError: LocalizedError {
    case notSignedIn(String)
    case expired(String)
    case http(Int)
    case rateLimited(retryAfter: TimeInterval?)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notSignedIn(let m), .expired(let m): return m
        case .rateLimited: return "Troppe richieste"
        case .http(let code): return "Errore del server (HTTP \(code))"
        case .badResponse: return "Risposta inattesa"
        }
    }
}

enum Parse {
    /// `Retry-After` as seconds from now; the header may hold seconds or an HTTP date.
    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        // Anthropic sends "0" while still limiting; treat non-positive values as "unknown".
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)) { return seconds > 0 ? seconds : nil }
        return httpDate.date(from: value).map { $0.timeIntervalSinceNow }.flatMap { $0 > 0 ? $0 : nil }
    }

    private static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Accepts ISO-8601 with or without (arbitrarily long) fractional seconds.
    static func isoDate(_ string: String) -> Date? {
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return isoPlain.date(from: trimmed)
    }

    static func capitalizedPlan(_ raw: String) -> String {
        raw.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

enum Cache {
    private static func key(_ id: ProviderID) -> String { "snapshot.\(id.rawValue)" }

    static func load(_ id: ProviderID) -> ProviderSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key(id)) else { return nil }
        return try? JSONDecoder().decode(ProviderSnapshot.self, from: data)
    }

    static func save(_ snapshot: ProviderSnapshot, for id: ProviderID) {
        guard !snapshot.isSample, let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key(id))
    }
}

extension ProviderID {
    var fetch: @Sendable () async throws -> ProviderSnapshot {
        switch self {
        case .claude: return { try await ClaudeProvider.fetch() }
        case .codex: return { try await CodexProvider.fetch() }
        case .opencode: return { try await OpenCodeProvider.fetch() }
        }
    }
}
