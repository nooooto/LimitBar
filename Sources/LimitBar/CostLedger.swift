import Foundation

/// What the work done with Claude Code and Codex would have cost at API prices, read from their
/// local session logs (token counts per reply and the model that wrote it). It's an estimate:
/// Claude Code's own background calls (e.g. Haiku summarising web searches) and replies cut off
/// mid-stream aren't in the logs, which puts it within a few percent of Claude Code's own total.
///
/// The logs are read incrementally: each file's read position is remembered, so after the first
/// pass only new lines are parsed. Totals are kept per service, day and model, and the cost also
/// per working folder, named by project (see ProjectFolder) when handed out; all of it is saved
/// with the read positions in ~/Library/Application Support/LimitBar/cost-ledger.json.
///
/// The cost per project and day is also kept in cost-archive.json, which reading the logs again
/// never empties: Claude Code deletes conversations after 30 days, so without it a fresh read
/// (after a format or price change) would lose the older months.
final class CostLedger {
    /// Bump when State changes shape, so the logs are read again from the start.
    private static let version = 5

    /// What `update` hands back: service → day (yyyy-MM-dd, local) → model, from the logs, or
    /// project, from the archive.
    struct Summary {
        var totals: [String: [String: [String: Totals]]] = [:]
        var projects: [String: [String: [String: Double]]] = [:]
        /// service → the first day (yyyy-MM-dd) whose work is all in `projects`.
        var completeSince: [String: String] = [:]
        /// project → the folder it lives in, for the projects whose folder still exists.
        var projectFolders: [String: String] = [:]
    }

    /// Token counts and their price for one service, day and model.
    struct Totals: Codable {
        var cost = 0.0
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        /// Replies from models without a published price; counted, not priced.
        var unpricedReplies = 0
    }

    private struct FileCursor: Codable {
        var offset: UInt64 = 0
        /// Codex: the model and working folder of the latest turn, and the running token total of the session.
        var model: String?
        var folder: String?
        var total = 0
    }

    private struct State: Codable {
        var version = CostLedger.version
        var pricesVersion = Prices.version
        var files: [String: FileCursor] = [:]
        /// Claude replies already counted (message id + request id → their day). Claude Code
        /// writes a reply once per content block, and a forked or resumed session copies its
        /// parent's replies into its own log, so the same reply turns up many times across files.
        /// Only replies the logs may still hold need remembering: see forgetOldReplies().
        var countedClaude: [String: String] = [:]
        /// The day forgetOldReplies() last ran.
        var forgottenOn: String?
        /// OpenCode: the last write (ms) of the newest reply counted, and the replies counted
        /// (id → day), in case one is written again after it finished.
        var openCodeCursor: Int64 = 0
        var countedOpenCode: [String: String] = [:]
        /// service → day (yyyy-MM-dd, local) → model → totals
        var totals: [String: [String: [String: Totals]]] = [:]
        /// service → day → working folder → cost in dollars
        var folders: [String: [String: [String: Double]]] = [:]
    }

    private struct Archive: Codable {
        var pricesVersion = Prices.version
        /// service → the first day whose work is all here. When the archive starts, Claude Code
        /// has already deleted the conversations older than its retention; Codex keeps its logs.
        var completeSince: [String: String] = [:]
        /// service → day → project → cost in dollars
        var days: [String: [String: [String: Double]]] = [:]

        init() {}

        /// Field by field, so a file written before a field existed still loads instead of
        /// being replaced by an empty archive.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pricesVersion = try c.decodeIfPresent(Int.self, forKey: .pricesVersion) ?? Prices.version
            completeSince = try c.decodeIfPresent([String: String].self, forKey: .completeSince) ?? [:]
            days = try c.decodeIfPresent([String: [String: [String: Double]]].self, forKey: .days) ?? [:]
        }
    }

    /// How many days Claude Code keeps conversations: its `cleanupPeriodDays` setting, 30 unless set.
    private static var claudeRetentionDays: Int {
        let settings = (try? Data(contentsOf: home.appendingPathComponent(".claude/settings.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return (settings?["cleanupPeriodDays"] as? NSNumber)?.intValue ?? 30
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let claudeLogs = home.appendingPathComponent(".claude/projects")
    private static let codexLogs = home.appendingPathComponent(".codex/sessions")
    private static let stateFile = home.appendingPathComponent("Library/Application Support/LimitBar/cost-ledger.json")
    private static let archiveFile = home.appendingPathComponent("Library/Application Support/LimitBar/cost-archive.json")

    private let queue = DispatchQueue(label: "LimitBar.CostLedger", qos: .utility)
    private var state: State
    /// Whether `state` has changed since it was last written: most updates find nothing new.
    private var unsaved = false
    private var archive: Archive
    /// The projects of the folders in `state.folders`, worked out again when a new folder turns up.
    private var projects: [String: ProjectFolder.Project] = [:]

    init() {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: Self.stateFile),
           let saved = try? decoder.decode(State.self, from: data),
           saved.version == Self.version, saved.pricesVersion == Prices.version {
            state = saved
        } else {
            // First run, or the price table or the saved format changed: read every log again.
            state = State()
            unsaved = true
        }
        archive = (try? Data(contentsOf: Self.archiveFile)).flatMap { try? decoder.decode(Archive.self, from: $0) } ?? Archive()
    }

    /// Reads what's new in the logs on a background queue, then hands the totals to `done` on main.
    func update(_ done: @escaping (Summary) -> Void) {
        queue.async { [self] in
            scan(Self.claudeLogs, kind: .claude)
            if ProviderID.codex.isActive { scan(Self.codexLogs, kind: .codex) }
            if ProviderID.opencode.isActive { readOpenCode() }
            forgetOldReplies()
            if unsaved { save() }
            let summary = Summary(totals: state.totals, projects: archived(projectTotals()),
                                  completeSince: archive.completeSince, projectFolders: projectFolders())
            DispatchQueue.main.async { done(summary) }
        }
    }

    // MARK: Reading

    private func scan(_ root: URL, kind: ProviderID) {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        for case let url as URL in files where url.pathExtension == "jsonl" {
            let path = url.path
            var cursor = state.files[path] ?? FileCursor()
            let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            // A log that shrank was rewritten; its old lines were already counted, so start after them.
            if size < cursor.offset { cursor = FileCursor(offset: size) }
            guard size > cursor.offset, let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            try? handle.seek(toOffset: cursor.offset)
            guard let data = try? handle.readToEnd(), let lastBreak = data.lastIndex(of: UInt8(ascii: "\n")) else { continue }
            // Only whole lines: a line still being written is read next time.
            let complete = data[data.startIndex...lastBreak]
            for line in complete.split(separator: UInt8(ascii: "\n")) {
                switch kind {
                case .claude: readClaude(line, cursor: &cursor)
                case .codex: readCodex(line, cursor: &cursor)
                case .opencode: break  // no logs: its database is read by readOpenCode()
                }
            }
            cursor.offset += UInt64(complete.count)
            state.files[path] = cursor
            unsaved = true
        }
    }

    private func readClaude(_ line: Data.SubSequence, cursor: inout FileCursor) {
        // Cheap filter first: only assistant replies carry usage.
        guard line.range(of: Data(#""type":"assistant""#.utf8)) != nil,
              let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String, model != "<synthetic>",
              let day = Self.day(json["timestamp"]) else { return }

        let key = "\(message["id"] as? String ?? "")|\(json["requestId"] as? String ?? "")"
        guard state.countedClaude[key] == nil else { return }
        state.countedClaude[key] = day

        func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
        let input = int(usage["input_tokens"]), output = int(usage["output_tokens"])
        let cacheRead = int(usage["cache_read_input_tokens"])
        let split = usage["cache_creation"] as? [String: Any]
        let write1h = int(split?["ephemeral_1h_input_tokens"])
        let write5m = split == nil ? int(usage["cache_creation_input_tokens"]) : int(split?["ephemeral_5m_input_tokens"])

        var totals = Totals(input: input, output: output, cacheRead: cacheRead, cacheWrite: write5m + write1h)
        if let price = Prices.claude(model, promptTokens: input + cacheRead + write5m + write1h) {
            totals.cost = (Double(input) * price.input + Double(output) * price.output + Double(cacheRead) * price.cacheRead
                + Double(write5m) * price.cacheWrite5m + Double(write1h) * price.cacheWrite1h) / 1_000_000
        } else {
            totals.unpricedReplies = 1
        }
        add(totals, service: .claude, day: day, model: model, folder: json["cwd"] as? String)
    }

    private func readCodex(_ line: Data.SubSequence, cursor: inout FileCursor) {
        let isContext = line.range(of: Data(#""type":"turn_context""#.utf8)) != nil
        let isTokens = line.range(of: Data(#""type":"token_count""#.utf8)) != nil
        guard isContext || isTokens,
              let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let payload = json["payload"] as? [String: Any] else { return }

        if isContext {
            cursor.model = payload["model"] as? String
            cursor.folder = payload["cwd"] as? String
            return
        }
        // The same count is repeated (e.g. with each rate-limit update); a new reply raises the total.
        guard let info = payload["info"] as? [String: Any],
              let total = (info["total_token_usage"] as? [String: Any])?["total_tokens"] as? NSNumber,
              total.intValue > cursor.total,
              let last = info["last_token_usage"] as? [String: Any],
              let day = Self.day(json["timestamp"]) else { return }
        cursor.total = total.intValue

        func int(_ key: String) -> Int { (last[key] as? NSNumber)?.intValue ?? 0 }
        let input = int("input_tokens"), cached = int("cached_input_tokens")
        let written = int("cache_write_input_tokens"), output = int("output_tokens")
        let model = cursor.model ?? "?"
        var totals = Totals(input: max(input - cached - written, 0), output: output, cacheRead: cached, cacheWrite: written)
        // OpenAI counts cached and freshly cached tokens inside input_tokens, and reasoning inside output.
        if let price = Prices.openAI(model, inputTokens: input) {
            totals.cost = (Double(totals.input) * price.input + Double(cached) * price.cacheRead
                + Double(written) * price.cacheWrite5m + Double(output) * price.output) / 1_000_000
        } else {
            totals.unpricedReplies = 1
        }
        add(totals, service: .codex, day: day, model: model, folder: cursor.folder)
    }

    /// The folder costs summed by project.
    private func projectTotals() -> [String: [String: [String: Double]]] {
        let folders = Set(state.folders.values.flatMap { $0.values.flatMap(\.keys) })
        if folders != Set(projects.keys) { projects = ProjectFolder.projects(for: folders) }
        return state.folders.mapValues { days in
            days.mapValues { costs in
                costs.reduce(into: [String: Double]()) { $0[projects[$1.key]?.name ?? ProjectFolder.other, default: 0] += $1.value }
            }
        }
    }

    /// Where each project lives. A project can have several folders (a copy in a scratch chat, a
    /// folder renamed since): the one with the most work in it wins.
    private func projectFolders() -> [String: String] {
        var work: [String: [String: Double]] = [:]  // project → its folder → cost
        for days in state.folders.values {
            for costs in days.values {
                for (folder, cost) in costs {
                    guard let project = projects[folder], let root = project.folder else { continue }
                    work[project.name, default: [:]][root, default: 0] += cost
                }
            }
        }
        return work.compactMapValues { folders in folders.max { $0.value < $1.value }?.key }
    }

    /// Files the logs' figures in the archive and returns all of it. A day keeps the archive's
    /// figures when they're higher, which means some of its logs have been deleted since; after a
    /// price change the logs' figures win wherever the logs are still there.
    private func archived(_ live: [String: [String: [String: Double]]]) -> [String: [String: [String: Double]]] {
        let repriced = archive.pricesVersion != Prices.version
        var changed = repriced
        for id in ProviderID.allCases where archive.completeSince[id.rawValue] == nil {
            let start = id == .claude ? Date().addingTimeInterval(-Double(Self.claudeRetentionDays) * 86400) : .distantPast
            archive.completeSince[id.rawValue] = Self.dayKey(start)
            changed = true
        }
        for (service, days) in live {
            for (day, projects) in days {
                let kept = archive.days[service]?[day]
                guard kept != projects else { continue }
                let keptTotal = kept?.values.reduce(0, +) ?? 0
                guard repriced || projects.values.reduce(0, +) >= keptTotal - 1e-9 else { continue }
                archive.days[service, default: [:]][day] = projects
                changed = true
            }
        }
        archive.pricesVersion = Prices.version
        if changed, let data = try? JSONEncoder().encode(archive) {
            try? data.write(to: Self.archiveFile, options: .atomic)
        }
        return archive.days
    }

    /// OpenCode keeps its replies, already priced, in a database rather than logs: each one it has
    /// finished since the last read, with the folder of its session.
    private func readOpenCode() {
        guard FileManager.default.fileExists(atPath: OpenCodeProvider.database.path),
              let replies = OpenCodeDatabase.finishedReplies(updatedAfter: state.openCodeCursor) else { return }
        for reply in replies {
            state.openCodeCursor = max(state.openCodeCursor, reply.updated)
            guard state.countedOpenCode[reply.id] == nil else { continue }
            let day = Self.dayKey(reply.created)
            state.countedOpenCode[reply.id] = day
            var totals = Totals(input: reply.input, output: reply.output, cacheRead: reply.cacheRead, cacheWrite: reply.cacheWrite)
            totals.cost = reply.cost
            add(totals, service: .opencode, day: day, model: reply.model, folder: reply.folder)
        }
        if !replies.isEmpty { unsaved = true }
    }

    private func add(_ totals: Totals, service: ProviderID, day: String, model: String, folder: String?) {
        var current = state.totals[service.rawValue, default: [:]][day, default: [:]][model, default: Totals()]
        current.cost += totals.cost
        current.input += totals.input
        current.output += totals.output
        current.cacheRead += totals.cacheRead
        current.cacheWrite += totals.cacheWrite
        current.unpricedReplies += totals.unpricedReplies
        state.totals[service.rawValue, default: [:]][day, default: [:]][model] = current
        state.folders[service.rawValue, default: [:]][day, default: [:]][folder ?? "", default: 0] += totals.cost
    }

    /// Once a day, drops the replies older than the logs can still hold (Claude Code deletes
    /// conversations after its retention, 30 days by default), plus a few days' margin: no log
    /// can copy them any more, and without this the list would grow by thousands a month.
    private func forgetOldReplies() {
        let today = Self.dayKey(Date())
        guard state.forgottenOn != today else { return }
        let keep = max(35, Self.claudeRetentionDays + 5)
        let cutoff = Self.dayKey(Date().addingTimeInterval(-Double(keep) * 86400))
        state.countedClaude = state.countedClaude.filter { $0.value >= cutoff }
        state.countedOpenCode = state.countedOpenCode.filter { $0.value >= cutoff }
        state.forgottenOn = today
        unsaved = true
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: Self.stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? data.write(to: Self.stateFile, options: .atomic)) != nil { unsaved = false }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// The services' work at API prices on the days that pass `days`, from Summary.projects.
    static func cost(of services: [ProviderID], in projects: [String: [String: [String: Double]]],
                     days: (String) -> Bool) -> Double {
        var cost = 0.0
        for id in services {
            for (day, costs) in projects[id.rawValue] ?? [:] where days(day) {
                for value in costs.values { cost += value }
            }
        }
        return cost
    }

    private static func day(_ timestamp: Any?) -> String? {
        (timestamp as? String).flatMap(Parse.isoDate).map(dayKey)
    }
}

/// A month of work with one service at API prices, and what its plan costs.
struct ServiceValue {
    var cost: Double
    /// Monthly price of the plan in dollars; nil when the plan isn't known.
    let subscription: Double?

    /// How many times the plan's price the work was worth, for paid plans.
    var multiple: Double? {
        guard let subscription, subscription > 0 else { return nil }
        return cost / subscription
    }
}

/// This month's work so far and last month's up to the same day, at API prices in dollars.
struct MonthComparison {
    let current: Double
    let previous: Double
    /// A date in last month, for its name.
    let previousMonth: Date
    /// The last day of last month counted: today's day of the month, or its last day if shorter.
    let throughDay: Int

    /// Nil when last month had no work to compare with, or isn't all known for every service:
    /// the archive only holds what the logs still had when it started.
    init?(costs: [String: [String: [String: Double]]], completeSince: [String: String],
          providers: [ProviderID], now: Date) {
        let calendar = Calendar.current
        guard let lastMonth = calendar.date(byAdding: .month, value: -1, to: now),
              let lastMonthDays = calendar.range(of: .day, in: .month, for: lastMonth)?.count else { return nil }
        let throughDay = min(calendar.component(.day, from: now), lastMonthDays)
        let month = String(CostLedger.dayKey(now).prefix(7)), previousMonth = String(CostLedger.dayKey(lastMonth).prefix(7))
        guard providers.allSatisfy({ completeSince[$0.rawValue].map { $0 <= previousMonth + "-01" } ?? false }) else { return nil }
        let previous = CostLedger.cost(of: providers, in: costs) {
            $0.hasPrefix(previousMonth) && Int($0.suffix(2)) ?? 99 <= throughDay
        }
        guard previous > 0 else { return nil }
        self.current = CostLedger.cost(of: providers, in: costs) { $0.hasPrefix(month) }
        self.previous = previous
        self.previousMonth = lastMonth
        self.throughDay = throughDay
    }
}

/// A month of work in one project at API prices, per service.
struct ProjectValue: Identifiable {
    let name: String
    /// Where the project lives, when its folder still exists.
    var folder: String? = nil
    var costs: [ProviderID: Double] = [:]
    /// For the `ProjectFolder.other` entry: the smaller projects counted in it.
    var folded: [String] = []

    var id: String { name }
    var total: Double { costs.values.reduce(0, +) }
}

/// API prices in dollars per million tokens, standard tier.
///
/// Claude: platform.claude.com pricing (Anthropic's Claude API docs, Oct 2026), checked against
/// Claude Code's own `cost-state` totals. Cache writes cost 1.25x input for 5 minutes and 2x for
/// one hour. OpenAI: developers.openai.com/api/docs/pricing (Oct 2026); prompts over 272K input
/// tokens are billed at the long-context rates. Bump `version` after editing so totals are rebuilt.
enum Prices {
    static let version = 2

    struct Price {
        let input: Double, output: Double, cacheRead: Double, cacheWrite5m: Double, cacheWrite1h: Double

        init(input: Double, output: Double, cacheRead: Double) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            cacheWrite5m = input * 1.25
            cacheWrite1h = input * 2
        }
    }

    private static let claudeTable: [(prefix: String, price: Price)] = [
        ("claude-fable-5-1", Price(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", Price(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable-5", Price(input: 10, output: 50, cacheRead: 1)),
        ("claude-mythos-5", Price(input: 10, output: 50, cacheRead: 1)),
        ("claude-opus-5-5", Price(input: 4, output: 20, cacheRead: 0.20)),
        ("claude-opus-5", Price(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-8", Price(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-7", Price(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-6", Price(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4-5", Price(input: 5, output: 25, cacheRead: 0.50)),
        ("claude-opus-4", Price(input: 15, output: 75, cacheRead: 1.50)),
        ("claude-sonnet-5-5", Price(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet-5", Price(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet-4", Price(input: 3, output: 15, cacheRead: 0.30)),
        ("claude-haiku-4-5", Price(input: 1, output: 5, cacheRead: 0.10)),
    ]

    /// Longest prefix first, so "claude-opus-4-5" doesn't match "claude-opus-4".
    private static let claudeByPrefix = claudeTable.sorted { $0.prefix.count > $1.prefix.count }

    /// Claude Haiku 5.5 has two rates, split at a 100K-token prompt.
    private static let haiku55 = Price(input: 0.10, output: 0.50, cacheRead: 0.01)
    private static let haiku55Long = Price(input: 0.50, output: 2.50, cacheRead: 0.05)

    static func claude(_ model: String, promptTokens: Int) -> Price? {
        if model.hasPrefix("claude-haiku-5-5") { return promptTokens > 100_000 ? haiku55Long : haiku55 }
        return claudeByPrefix.first { model.hasPrefix($0.prefix) }?.price
    }

    private static let openAITable: [String: (short: Price, long: Price)] = [
        "gpt-5.6-sol": (Price(input: 4, output: 20, cacheRead: 0.40), Price(input: 8, output: 30, cacheRead: 0.80)),
        "gpt-5.6-terra": (Price(input: 2, output: 12, cacheRead: 0.20), Price(input: 4, output: 18, cacheRead: 0.40)),
        "gpt-5.6-luna": (Price(input: 0.20, output: 1.20, cacheRead: 0.02), Price(input: 0.40, output: 1.80, cacheRead: 0.04)),
        "gpt-6.1-sol": (Price(input: 2, output: 10, cacheRead: 0.10), Price(input: 4, output: 15, cacheRead: 0.20)),
        "gpt-6-sol": (Price(input: 2, output: 10, cacheRead: 0.20), Price(input: 4, output: 15, cacheRead: 0.40)),
        "gpt-6-astra": (Price(input: 10, output: 50, cacheRead: 1), Price(input: 20, output: 75, cacheRead: 2)),
        "gpt-6-luna": (Price(input: 0.10, output: 0.50, cacheRead: 0.01), Price(input: 0.20, output: 0.75, cacheRead: 0.02)),
        "gpt-5.5": (Price(input: 5, output: 30, cacheRead: 0.50), Price(input: 10, output: 45, cacheRead: 1)),
    ]

    static func openAI(_ model: String, inputTokens: Int) -> Price? {
        guard let rates = openAITable[model] else { return nil }
        return inputTokens > 272_000 ? rates.long : rates.short
    }

    /// Monthly subscription in dollars, from the plan name LimitBar shows.
    static func subscription(_ id: ProviderID, plan: String?) -> Double? {
        let plan = (plan ?? "").lowercased()
        switch id {
        case .claude:
            if plan.contains("20x") { return 200 }
            if plan.contains("max") { return 100 }
            if plan.contains("pro") { return 20 }
            return nil
        case .codex:
            if plan.contains("free") { return 0 }
            if plan.contains("plus") { return 20 }
            if plan.contains("pro") { return 200 }
            return nil
        case .opencode:
            return OpenCodeProvider.Plan.current.price
        }
    }
}
