import Foundation

enum WindowKind: String, CaseIterable {
    case fiveHour, week

    func window(in snapshot: ProviderSnapshot) -> UsageWindow? {
        switch self {
        case .fiveHour: return snapshot.fiveHour
        case .week: return snapshot.week
        }
    }

    /// Whether the week slot holds a monthly window instead (Codex's 30 days on the Free plan).
    func isMonthly(_ window: UsageWindow) -> Bool {
        self == .week && (28...31).contains((window.windowMinutes ?? 0) / (24 * 60))
    }
}

/// One reading of a service's usage, as percentages of each window.
struct UsageSample: Codable, Equatable {
    let date: Date
    let fiveHour: Double?
    let week: Double?

    func value(_ kind: WindowKind) -> Double? {
        switch kind {
        case .fiveHour: return fiveHour
        case .week: return week
        }
    }
}

enum UsageHistory {
    private static let keep: TimeInterval = 7 * 86400
    /// Readings closer than this replace each other, so a week stays a few thousand points.
    private static let minimumGap: TimeInterval = 120

    private static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LimitBar/history.json")

    static func load() -> [ProviderID: [UsageSample]] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let raw = (try? decoder.decode([String: [UsageSample]].self, from: data)) ?? [:]
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            ProviderID(rawValue: key).map { ($0, value) }
        })
    }

    static func save(_ history: [ProviderID: [UsageSample]]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let raw = Dictionary(uniqueKeysWithValues: history.map { ($0.key.rawValue, $0.value) })
        guard let data = try? encoder.encode(raw) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Adds the snapshot's reading; returns false when it brought nothing new.
    static func record(_ snapshot: ProviderSnapshot, into samples: inout [UsageSample]) -> Bool {
        // A window already reset at the reading's time was empty then.
        let sample = UsageSample(date: snapshot.updatedAt, fiveHour: snapshot.fiveHour?.effectivePercent(at: snapshot.updatedAt),
                                 week: snapshot.week?.effectivePercent(at: snapshot.updatedAt))
        if let last = samples.last {
            guard sample.date > last.date else { return false }
            if sample.date.timeIntervalSince(last.date) < minimumGap {
                guard sample.fiveHour != last.fiveHour || sample.week != last.week else { return false }
                samples.removeLast()
            }
        }
        samples.append(sample)
        let cutoff = Date().addingTimeInterval(-keep)
        samples.removeAll { $0.date < cutoff }
        return true
    }

    /// When the window runs out at the pace of the current run, if that's before it resets.
    /// The pace comes from readings since the window's last reset, looking back 90 minutes for
    /// the 5-hour window and a day for the weekly one, and needs at least 10 minutes of them.
    static func forecast(_ kind: WindowKind, window: UsageWindow?, samples: [UsageSample], now: Date) -> Date? {
        guard let window, let resetsAt = window.resetsAt, resetsAt > now else { return nil }
        let current = window.effectivePercent(at: now)
        guard current > 0, current < 100 else { return nil }

        let lookback: TimeInterval = kind == .fiveHour ? 90 * 60 : 86400
        var run: [(date: Date, value: Double)] = []
        for sample in samples where sample.date >= now.addingTimeInterval(-lookback) {
            guard let value = sample.value(kind) else { continue }
            if let last = run.last, value < last.value - 0.5 { run.removeAll() }  // a reset happened
            run.append((sample.date, value))
        }
        guard let first = run.first, let last = run.last else { return nil }
        let span = last.date.timeIntervalSince(first.date)
        guard span >= 10 * 60, last.value > first.value else { return nil }

        let perSecond = (last.value - first.value) / span
        let runsOut = now.addingTimeInterval((100 - current) / perSecond)
        return runsOut < resetsAt ? runsOut : nil
    }
}
