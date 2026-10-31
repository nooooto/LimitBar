import Foundation

/// The stretches of time the Spesa window can show, each ending today.
enum SpendPeriod: String, CaseIterable, Identifiable {
    case today, week, thirtyDays, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Oggi"
        case .week: return "7 giorni"
        case .thirtyDays: return "30 giorni"
        case .month: return "Questo mese"
        }
    }

    /// The period's days as CostLedger keys them (yyyy-MM-dd, local), oldest first, today included.
    func days(now: Date) -> [String] { dates(now: now).map(\.key) }

    fileprivate func dates(now: Date) -> [(key: String, date: Date)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let count: Int
        switch self {
        case .today: count = 1
        case .week: count = 7
        case .thirtyDays: count = 30
        case .month: count = calendar.component(.day, from: today)
        }
        return (0..<count).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: today).map { (CostLedger.dayKey($0), $0) }
        }
    }
}

/// What the work of a period was worth at API prices, for the Spesa window: the total and the
/// projects from CostLedger's per-project costs (the same source as the panel, so this month adds
/// up the same), the tokens and the models from its per-model totals (which only reach back as
/// far as the logs do, 30 days for Claude Code).
struct SpendReport {
    struct Day: Identifiable {
        let day: String
        let date: Date
        /// Every service shown, 0 on a day without work.
        let costs: [ProviderID: Double]
        var id: String { day }
    }

    struct Model: Identifiable {
        let key: String
        let title: String
        let service: ProviderID
        let cost: Double
        /// Input and output (reasoning included), without the cache.
        let tokens: Int
        /// Of the period's total, 0 to 1 (the models may not cover all of it: see `modelsCost`).
        let share: Double
        var id: String { "\(service.rawValue)/\(key)" }
    }

    struct Project: Identifiable {
        let name: String
        let folder: String?
        let cost: Double
        /// Of the period's total, 0 to 1.
        let share: Double
        var id: String { name }
    }

    /// Dollars.
    let total: Double
    let input: Int, output: Int, cacheRead: Int, cacheWrite: Int
    let days: [Day]
    /// Highest value first.
    let models: [Model]
    /// What the models add up to: less than `total` when the logs no longer hold some of the
    /// period's days (the projects' archive keeps them).
    let modelsCost: Double
    /// Highest value first, ProjectFolder.other last.
    let projects: [Project]
    /// The day a service's record becomes complete, when the period starts before it.
    let incompleteBefore: String?

    static func make(summary: CostLedger.Summary, providers: [ProviderID], period: SpendPeriod, now: Date) -> SpendReport {
        let dates = period.dates(now: now)
        let keys = Set(dates.map(\.key))

        var days: [Day] = []
        var byProject: [String: Double] = [:]
        for (key, date) in dates {
            var costs: [ProviderID: Double] = [:]
            for id in providers {
                let projects = summary.projects[id.rawValue]?[key] ?? [:]
                costs[id] = projects.values.reduce(0, +)
                for (name, cost) in projects { byProject[name, default: 0] += cost }
            }
            days.append(Day(day: key, date: date, costs: costs))
        }
        let total = days.reduce(0) { $0 + $1.costs.values.reduce(0, +) }

        var input = 0, output = 0, cacheRead = 0, cacheWrite = 0
        var byModel: [String: (service: ProviderID, key: String, cost: Double, tokens: Int)] = [:]
        for id in providers {
            for (day, models) in summary.totals[id.rawValue] ?? [:] where keys.contains(day) {
                for (key, totals) in models {
                    input += totals.input
                    output += totals.output
                    cacheRead += totals.cacheRead
                    cacheWrite += totals.cacheWrite
                    var entry = byModel["\(id.rawValue)/\(key)"] ?? (id, key, 0, 0)
                    entry.cost += totals.cost
                    entry.tokens += totals.input + totals.output
                    byModel["\(id.rawValue)/\(key)"] = entry
                }
            }
        }
        let modelsCost = byModel.values.reduce(0) { $0 + $1.cost }
        let models = byModel.values
            .filter { $0.cost > 0 || $0.tokens > 0 }
            .map { Model(key: $0.key, title: modelTitle($0.key, service: $0.service), service: $0.service, cost: $0.cost,
                         tokens: $0.tokens, share: total > 0 ? $0.cost / total : 0) }
            .sorted { ($0.cost, $0.tokens) > ($1.cost, $1.tokens) }

        let projects = byProject
            .filter { $0.value > 0 }
            .map { Project(name: $0.key, folder: summary.projectFolders[$0.key], cost: $0.value, share: total > 0 ? $0.value / total : 0) }
            .sorted { a, b in
                let aOther = a.name == ProjectFolder.other, bOther = b.name == ProjectFolder.other
                return aOther != bOther ? bOther : a.cost > b.cost
            }

        let first = dates.first?.key ?? ""
        let incomplete = providers.compactMap { summary.completeSince[$0.rawValue] }.filter { first < $0 }.max()

        return SpendReport(total: total, input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite,
                           days: days, models: models, modelsCost: modelsCost, projects: projects, incompleteBefore: incomplete)
    }

    /// A model's name for people: "claude-haiku-4-5-20251001" → "Claude Haiku 4.5", OpenCode's
    /// from its own table; anything else as it is.
    static func modelTitle(_ key: String, service: ProviderID) -> String {
        switch service {
        case .opencode:
            return OpenCodeProvider.modelName(key) ?? key
        case .claude where key.hasPrefix("claude-"):
            var parts = key.split(separator: "-").map(String.init)
            if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
            // Runs of numbers become one version ("4", "5" → "4.5"); words get a capital.
            var words: [String] = []
            var number: [String] = []
            for part in parts {
                if part.allSatisfy(\.isNumber) {
                    number.append(part)
                } else {
                    if !number.isEmpty { words.append(number.joined(separator: ".")); number = [] }
                    words.append(part.prefix(1).uppercased() + part.dropFirst())
                }
            }
            if !number.isEmpty { words.append(number.joined(separator: ".")) }
            return words.joined(separator: " ")
        default:
            return key
        }
    }
}
