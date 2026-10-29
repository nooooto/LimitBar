import Foundation
import SQLite3

/// OpenCode Go has no way to read its limits outside its web console, so they're estimated from
/// what OpenCode records on this Mac: every reply, with its model and cost in dollars, in
/// ~/.local/share/opencode/opencode.db. Only this Mac's work counts, so an account also used
/// elsewhere has used more than this shows; the panel says so.
///
/// The limits are shared by all models, each weighed by its own allowance: a model's monthly
/// allowance in dollars is 100% of the month, 20% of it of 5 hours and 50% of a week
/// (opencode.ai/v2/docs/console/go, Oct 2026). So $3 on a $15 model fills the 5 hours as much as
/// $16 on an $80 one, and what all the models used adds up: once it reaches 100%, none can be used.
///
/// The windows don't roll; each starts over all at once, as the console shows (checked against
/// it on 24 Oct 2026, see `periods`).
enum OpenCodeProvider {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode")
    static let database = folder.appendingPathComponent("opencode.db")
    /// The provider OpenCode files Go replies under (and its key under, in auth.json).
    static let goProvider = "opencode-go"

    enum Plan: String, CaseIterable, Identifiable {
        case go, goPlus
        var id: String { rawValue }
        var title: String { self == .go ? "Go" : "Go Plus" }
        /// Monthly price in dollars.
        var price: Double { self == .go ? 10 : 40 }

        /// Not readable anywhere, so it's a setting (see AppSettings.openCodePlan).
        static var current: Plan {
            UserDefaults.standard.string(forKey: "settings.openCodePlan").flatMap(Plan.init(rawValue:)) ?? .go
        }
    }

    /// Monthly allowance in dollars per model on Go and on Go Plus; nil for the free models,
    /// which have no limit. Gemini 4 Argon Contributor's are doubled for now.
    private static let allowances: [String: (name: String, go: Double?, plus: Double?)] = [
        "grok-4.7": ("Grok 4.7", 15, 60),
        "gpt-6-luna": ("GPT 6 Luna", 15, 60),
        "gpt-5.6-luna": ("GPT 5.6 Luna", 15, 60),
        "claude-haiku-5-5": ("Claude Haiku 5.5", 15, 60),
        "gemini-4-argon-contributor": ("Gemini 4 Argon", 60, 240),
        "glm-5.3-flash": ("GLM-5.3-Flash", 60, 180),
        "glm-5.3": ("GLM-5.3", 15, 120),
        "glm-5.2": ("GLM-5.2", 60, 180),
        "kimi-k3.1-pro": ("Kimi K3.1 Pro", 15, 60),
        "kimi-k3": ("Kimi K3", 15, 60),
        "kimi-k2.7-code": ("Kimi K2.7 Code", 60, 180),
        "longcat-2.0": ("LongCat-2.0", 60, 240),
        "longcat-2.5-preview-free": ("LongCat 2.5 Free", nil, nil),
        "step-5-preview": ("Step 5 Preview", 15, 60),
        "beam-free": ("Beam Free", nil, nil),
        "mimo-v2.6-flash": ("MiMo-V2.6-Flash", 60, 120),
        "mimo-v2.6-pro": ("MiMo-V2.6-Pro", 15, 60),
        "mimo-v2.5": ("MiMo-V2.5", 60, 120),
        "mimo-v2.5-pro": ("MiMo-V2.5-Pro", 15, 60),
        "minimax-m3.1-flash": ("MiniMax M3.1 Flash", 20, 80),
        "minimax-m3": ("MiniMax M3", 60, 180),
        "muse-spark-1.3-contributor": ("Muse Spark 1.3", 60, 120),
        "muse-spark-1.2-contributor": ("Muse Spark 1.2", 60, 120),
        "qwen3.8-max": ("Qwen3.8 Max", 15, 60),
        "qwen3.8-flash": ("Qwen3.8 Flash", 30, 90),
        "qwen3.7-plus": ("Qwen3.7 Plus", 60, 180),
        "deepseek-v4.1-flash": ("DeepSeek V4.1 Flash", 80, 160),
        "deepseek-v4-pro": ("DeepSeek V4 Pro", 15, 60),
        "hy4-preview": ("Hy4 preview", 30, 120),
        "hy3": ("Hy3", 60, 240),
    ]

    /// A model missing from the table gets the smallest allowance, so its window fills up early
    /// rather than late.
    private static func allowance(_ model: String, plan: Plan) -> (name: String, dollars: Double)? {
        guard let entry = allowances[model] else { return (model, plan == .go ? 15 : 60) }
        return (plan == .go ? entry.go : entry.plus).map { (entry.name, $0) }
    }

    /// The label the monthly window goes by among the snapshot's extras.
    static let monthLabel = "Mese"

    /// The 5 hours, the week and the month: their length, and the part of a model's monthly
    /// allowance each one holds.
    private static let windows: [(minutes: Int, share: Double)] = [(5 * 60, 0.2), (7 * 24 * 60, 0.5), (30 * 24 * 60, 1)]

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2  // Monday
        return calendar
    }()

    /// The 5 hours, the week and the month in force at `now`, as OpenCode's console counts them:
    /// - the 5 hours start with the first paid reply once the previous ones are over and end 5
    ///   hours later, whatever happens in between; until the next reply there are none (nil);
    /// - the week starts on Monday at 00:00 UTC;
    /// - the month starts on the day and at the hour of the subscription, taken from the first Go
    ///   reply (`firstUse`), and lasts a calendar month.
    static func periods(replies: [Reply], plan: Plan, firstUse: Date?, now: Date) -> [DateInterval?] {
        var block: DateInterval?
        let paid = replies.filter { $0.date <= now && $0.cost > 0 && allowance($0.model, plan: plan) != nil }
        for reply in paid.sorted(by: { $0.date < $1.date }) where block.map({ reply.date >= $0.end }) ?? true {
            block = DateInterval(start: reply.date, duration: Double(windows[0].minutes) * 60)
        }
        // Whole months since the first use: the current one starts after that many.
        let month = firstUse.flatMap { first -> DateInterval? in
            let months = utc.dateComponents([.month], from: first, to: now).month ?? 0
            guard let from = utc.date(byAdding: .month, value: months, to: first),
                  let to = utc.date(byAdding: .month, value: months + 1, to: first) else { return nil }
            return DateInterval(start: from, end: to)
        }
        return [block.flatMap { $0.end > now ? $0 : nil }, utc.dateInterval(of: .weekOfYear, for: now), month]
    }

    static func fetch() async throws -> ProviderSnapshot {
        let now = Date()
        if ProcessInfo.processInfo.environment["LIMITBAR_RENDER_OPENCODE_SAMPLE"] != nil {
            var sample = snapshot(replies: sampleReplies(now: now), plan: .current, firstUse: now.addingTimeInterval(-10 * 86400),
                                  now: now, current: "gemini-4-argon-contributor")
            sample.source = "sample"
            return sample
        }
        guard isConnected else { throw ProviderError.notSignedIn("OpenCode Go non collegato · collegalo dall'app OpenCode") }
        // A month is at most 31 days.
        guard let replies = OpenCodeDatabase.replies(since: now.addingTimeInterval(-31 * 86400)) else {
            throw ProviderError.badResponse
        }
        return snapshot(replies: replies, plan: .current, firstUse: firstUse(), now: now,
                        current: OpenCodeActivity.currentModel())
    }

    private static let firstUseKey = "opencode.firstUse"

    /// When Go was first used, which sets when its months begin: the earliest Go reply ever
    /// seen, kept in LimitBar's defaults so it outlives OpenCode's database (a new Mac, a
    /// reinstall) rather than starting the months over from whatever reply comes next.
    private static func firstUse() -> Date? {
        let defaults = UserDefaults.standard
        let remembered = defaults.object(forKey: firstUseKey) as? Date
        let first = [remembered, OpenCodeDatabase.firstReply()].compactMap { $0 }.min()
        if let first, first != remembered { defaults.set(first, forKey: firstUseKey) }
        return first
    }

    typealias Reply = (date: Date, model: String, cost: Double)

    /// LIMITBAR_RENDER_OPENCODE_SAMPLE=1 fills OpenCode with these, to check the layout with --render.
    private static func sampleReplies(now: Date) -> [Reply] {
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        return [(ago(0.5), "glm-5.3", 1.1), (ago(2), "glm-5.3", 0.9), (ago(30), "glm-5.3", 2.4),
                (ago(1), "glm-5.2", 3.2), (ago(50), "glm-5.2", 9.5), (ago(200), "glm-5.2", 14),
                (ago(3), "deepseek-v4.1-flash", 0.6), (ago(4), "beam-free", 0), (ago(5), "beam-free", 0)]
    }

    /// The shared 5-hour, weekly and monthly windows (the month as an extra limit), and each
    /// model's share of them this month, the one chosen in OpenCode (`current`, a model ID) first.
    static func snapshot(replies: [Reply], plan: Plan, firstUse: Date?, now: Date, current: String? = nil) -> ProviderSnapshot {
        let periods = periods(replies: replies, plan: plan, firstUse: firstUse, now: now)
        func window(_ index: Int) -> UsageWindow {
            sharedWindow(index, period: periods[index], replies: replies, plan: plan, now: now)
        }
        var snapshot = ProviderSnapshot(plan: plan.title, fiveHour: window(0), week: window(1), updatedAt: now, source: "local")
        snapshot.extras = [ExtraLimit(label: monthLabel, window: window(2))]
        snapshot.models = modelUsage(replies: replies, plan: plan, periods: periods, now: now, current: current)
        return snapshot
    }

    /// One shared window: every reply in it counts its cost over its model's cap for the window.
    /// With no window in force (5 hours not started) nothing is used and nothing resets.
    static func sharedWindow(_ index: Int, period: DateInterval?, replies: [Reply], plan: Plan, now: Date) -> UsageWindow {
        let minutes = windows[index].minutes
        guard let period else { return UsageWindow(usedPercent: 0, resetsAt: nil, windowMinutes: minutes) }
        let total = replies
            .filter { period.holds($0.date) && $0.date <= now && $0.cost > 0 }
            .compactMap { reply in allowance(reply.model, plan: plan).map { reply.cost / ($0.dollars * windows[index].share) * 100 } }
            .reduce(0, +)
        return UsageWindow(usedPercent: min(total, 100), resetsAt: period.end, windowMinutes: minutes)
    }

    /// The models used this month, plus the one chosen in OpenCode even before it has answered:
    /// that one first, then the ones that used most of the shared limits.
    static func modelUsage(replies: [Reply], plan: Plan, periods: [DateInterval?], now: Date, current: String? = nil) -> [ModelUsage] {
        let monthStart = periods[2]?.start ?? now.addingTimeInterval(-Double(windows[2].minutes) * 60)
        let recent = replies.filter { $0.date >= monthStart && $0.date <= now }
        var byModel = Dictionary(grouping: recent, by: \.model)
        if let current, byModel[current] == nil { byModel[current] = [] }
        return byModel.compactMap { model, replies -> ModelUsage? in
            let allowance = allowance(model, plan: plan)
            // A paid model's reply that cost nothing failed; a free model's always costs nothing.
            let counted = allowance == nil ? replies : replies.filter { $0.cost > 0 }
            guard !counted.isEmpty || model == current else { return nil }
            func window(_ index: Int) -> ModelWindow {
                let inside = periods[index].map { period in counted.filter { period.holds($0.date) } } ?? []
                return ModelWindow(used: inside.reduce(0) { $0 + $1.cost }, cap: allowance.map { $0.dollars * windows[index].share })
            }
            return ModelUsage(name: allowance?.name ?? allowances[model]?.name ?? model, requests: counted.count,
                              spent: counted.reduce(0) { $0 + $1.cost }, isFree: allowance == nil,
                              fiveHour: window(0), week: window(1), month: window(2), isCurrent: model == current)
        }
        .sorted { ($0.inUse ? 1 : 0, $0.month.share, $0.spent) > ($1.inUse ? 1 : 0, $1.month.share, $1.spent) }
    }

    /// Whether OpenCode has a Go key, in its auth.json (only the key's presence is read).
    private static var isConnected: Bool {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("auth.json")),
              let auth = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return auth[goProvider] != nil
    }
}

/// Whether OpenCode is working: a reply it has started and not finished (no `time.completed`
/// yet), updated recently enough that the app didn't just quit in the middle of it.
enum OpenCodeActivity {
    private static let stale: TimeInterval = 600

    static func workingSessions(now: Date = Date()) -> Int {
        OpenCodeDatabase.unfinishedSessions(updatedSince: now.addingTimeInterval(-stale)) ?? 0
    }

    /// The folder of the session that was worked on last, for the "ha finito" alert.
    static func lastFolder() -> String? {
        OpenCodeDatabase.lastSessionFolder()
    }

    /// Where the desktop app keeps its state, one file per project folder, written as soon as a
    /// model is picked; the database only learns of it with the next message.
    static let desktopFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ai.opencode.desktop")

    /// The Go model chosen for the latest session: the desktop app's pick for it, otherwise the
    /// model the database last recorded for it. Nil for a model from another provider.
    static func currentModel() -> String? {
        guard let session = OpenCodeDatabase.latestSession() else { return nil }
        let picked = desktopSelection(for: session.id) ?? session.model
        guard let picked, picked.provider == OpenCodeProvider.goProvider else { return nil }
        return picked.model
    }

    /// The model picked for `session` in the desktop app's `workspace:model-selection` entries.
    private static func desktopSelection(for session: String) -> (provider: String, model: String)? {
        let files = (try? FileManager.default.contentsOfDirectory(at: desktopFolder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("opencode.workspace.") && file.pathExtension == "dat" {
            guard let data = try? Data(contentsOf: file),
                  let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let entry = (state["workspace:model-selection"] as? String)?.data(using: .utf8),
                  let selection = (try? JSONSerialization.jsonObject(with: entry)) as? [String: Any],
                  let pick = ((selection["session"] as? [String: Any])?[session] as? [String: Any])?["model"] as? [String: Any],
                  let provider = pick["providerID"] as? String, let model = pick["modelID"] as? String else { continue }
            return (provider, model)
        }
        return nil
    }
}

private extension DateInterval {
    /// Whether `date` falls in the interval, its end excluded: that instant is the next one's.
    func holds(_ date: Date) -> Bool { date >= start && date < end }
}

/// Read-only queries on OpenCode's SQLite database, which OpenCode keeps open and writes in WAL
/// mode; a reader sees what's committed without getting in its way.
enum OpenCodeDatabase {
    /// Go replies since `date`: when each was made, by which model, and what it cost.
    static func replies(since date: Date) -> [OpenCodeProvider.Reply]? {
        query("""
            SELECT time_created, json_extract(data, '$.modelID'), json_extract(data, '$.cost') FROM message
            WHERE time_created >= ? AND json_extract(data, '$.role') = 'assistant'
              AND json_extract(data, '$.providerID') = ?
            """, Int64(date.timeIntervalSince1970 * 1000), OpenCodeProvider.goProvider) { row in
            (Date(timeIntervalSince1970: Double(sqlite3_column_int64(row, 0)) / 1000),
             sqlite3_column_text(row, 1).map { String(cString: $0) } ?? "?",
             sqlite3_column_double(row, 2))
        }
    }

    /// The first Go reply this Mac has, failed ones too: the nearest thing to when the
    /// subscription started, which sets when its months begin.
    static func firstReply() -> Date? {
        query("""
            SELECT MIN(time_created) FROM message
            WHERE json_extract(data, '$.role') = 'assistant' AND json_extract(data, '$.providerID') = ?
            """, OpenCodeProvider.goProvider) { row -> Date? in
            sqlite3_column_type(row, 0) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: Double(sqlite3_column_int64(row, 0)) / 1000)
        }?.first ?? nil
    }

    static func unfinishedSessions(updatedSince date: Date) -> Int? {
        query("""
            SELECT COUNT(DISTINCT session_id) FROM message
            WHERE time_updated >= ? AND json_extract(data, '$.role') = 'assistant'
              AND json_extract(data, '$.time.completed') IS NULL
            """, Int64(date.timeIntervalSince1970 * 1000)) { Int(sqlite3_column_int64($0, 0)) }?.first
    }

    /// The session updated last, with the model the database recorded for it.
    static func latestSession() -> (id: String, model: (provider: String, model: String)?)? {
        query("SELECT id, model FROM session ORDER BY time_updated DESC LIMIT 1") { row -> (String, (String, String)?) in
            let id = sqlite3_column_text(row, 0).map { String(cString: $0) } ?? ""
            let json = sqlite3_column_text(row, 1).map { String(cString: $0) }
            let model = json.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
            let pair = (model?["providerID"] as? String).flatMap { provider in (model?["id"] as? String).map { (provider, $0) } }
            return (id, pair)
        }?.first.map { (id: $0.0, model: $0.1.map { (provider: $0.0, model: $0.1) }) }
    }

    /// A reply OpenCode has finished, for the cost ledger.
    struct FinishedReply {
        let id: String
        let created: Date
        /// When it was last written (ms), which only moves forward: the ledger's read position.
        let updated: Int64
        let model: String
        let cost: Double
        let folder: String?
        let input: Int, output: Int, cacheRead: Int, cacheWrite: Int
    }

    /// Replies from any provider finished and last written after `cursor` (ms), oldest first.
    static func finishedReplies(updatedAfter cursor: Int64) -> [FinishedReply]? {
        query("""
            SELECT m.id, m.time_created, m.time_updated, json_extract(m.data, '$.modelID'),
                   json_extract(m.data, '$.cost'), s.directory,
                   json_extract(m.data, '$.tokens.input'),
                   ifnull(json_extract(m.data, '$.tokens.output'), 0) + ifnull(json_extract(m.data, '$.tokens.reasoning'), 0),
                   json_extract(m.data, '$.tokens.cache.read'), json_extract(m.data, '$.tokens.cache.write')
            FROM message m LEFT JOIN session s ON s.id = m.session_id
            WHERE m.time_updated > ? AND json_extract(m.data, '$.role') = 'assistant'
              AND json_extract(m.data, '$.time.completed') IS NOT NULL
            ORDER BY m.time_updated
            """, cursor) { row in
            func text(_ column: Int32) -> String? { sqlite3_column_text(row, column).map { String(cString: $0) } }
            func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(row, column)) }
            return FinishedReply(id: text(0) ?? "", created: Date(timeIntervalSince1970: Double(sqlite3_column_int64(row, 1)) / 1000),
                                 updated: sqlite3_column_int64(row, 2), model: text(3) ?? "?",
                                 cost: sqlite3_column_double(row, 4), folder: text(5),
                                 input: int(6), output: int(7), cacheRead: int(8), cacheWrite: int(9))
        }
    }

    static func lastSessionFolder() -> String? {
        query("SELECT directory FROM session ORDER BY time_updated DESC LIMIT 1") { row in
            sqlite3_column_text(row, 0).map { String(cString: $0) }
        }?.first ?? nil
    }

    /// Runs `sql` with `values` bound to its `?`s (text or integers), one `read` per row; nil when
    /// the database can't be opened or the query fails.
    private static func query<T>(_ sql: String, _ values: Any..., read: (OpaquePointer) -> T) -> [T]? {
        guard let (db, statement) = prepare(sql) else { return nil }
        defer {
            sqlite3_finalize(statement)
            sqlite3_close(db)
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let number as Int64: sqlite3_bind_int64(statement, position, number)
            case let text as String: sqlite3_bind_text(statement, position, text, -1, transient)
            default: return nil
            }
        }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(read(statement))
            case SQLITE_DONE: return rows
            default: return nil
            }
        }
    }

    /// Opens the database read-only and prepares `sql`. While OpenCode is closed its WAL files
    /// are gone, and a read-only connection can't create the one it needs to read (SQLite says
    /// "unable to open database file"); with no WAL left the file is complete and nothing is
    /// writing it, so it's then read as immutable, without those files.
    private static func prepare(_ sql: String) -> (OpaquePointer, OpaquePointer)? {
        let path = OpenCodeProvider.database.path
        let walGone = !FileManager.default.fileExists(atPath: path + "-wal")
        var attempts = [(path, SQLITE_OPEN_READONLY)]
        if walGone, let url = URL(string: "file://" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + "?immutable=1") {
            attempts.append((url.absoluteString, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI))
        }
        for (name, flags) in attempts {
            var db: OpaquePointer?
            var statement: OpaquePointer?
            if sqlite3_open_v2(name, &db, flags, nil) == SQLITE_OK, let db {
                sqlite3_busy_timeout(db, 1000)
                if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement { return (db, statement) }
            }
            sqlite3_close(db)
        }
        return nil
    }
}
