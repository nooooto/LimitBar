import Foundation

/// How a service is doing by its own status page, worst last.
enum ServiceHealth: Int, Comparable {
    case operational, maintenance, degraded, outage

    static func < (a: ServiceHealth, b: ServiceHealth) -> Bool { a.rawValue < b.rawValue }
}

/// A service's status page, read: how it's doing, the sentence for the panel (nil when all is
/// well), and the page to open for more.
struct ServiceStatus: Equatable {
    let health: ServiceHealth
    let text: String?
    let page: URL
    let checkedAt: Date
}

/// Anthropic's and OpenCode's status pages, read for the parts LimitBar's services use: Claude
/// Code, the API and claude.ai for Claude; Go and the model in use for OpenCode. A page that
/// can't be read is unknown (nil), never an alarm.
enum ServiceStatusReader {
    static let claudePage = URL(string: "https://status.claude.com")!
    static let claudeSummary = URL(string: "https://status.claude.com/api/v2/summary.json")!
    static let openCodePage = URL(string: "https://status.opencode.ai")!
    static let openCodeStatus = URL(string: "https://status.opencode.ai/api/status")!

    /// How often the pages are read.
    static let interval: TimeInterval = 5 * 60

    /// How long the last good reading stands in for a page that stopped answering.
    static let keepFor: TimeInterval = 30 * 60

    /// The Statuspage components that matter, in order of precedence, with their name in the panel.
    private static let claudeComponents = [
        ("Claude Code", "Claude Code"),
        ("Claude API (api.anthropic.com)", "API di Claude"),
        ("claude.ai", "claude.ai"),
    ]

    private static func statuspageHealth(_ status: String?) -> ServiceHealth? {
        switch status {
        case "operational": return .operational
        case "under_maintenance": return .maintenance
        case "degraded_performance", "partial_outage": return .degraded
        case "major_outage": return .outage
        default: return nil
        }
    }

    private static func word(_ health: ServiceHealth) -> String {
        switch health {
        case .operational: return "operativo"
        case .maintenance: return "manutenzione in corso"
        case .degraded: return "prestazioni ridotte"
        case .outage: return "disservizio grave"
        }
    }

    /// Anthropic's Statuspage summary: the worst of the components that matter, with the first
    /// open incident that touches them (or names no component) as the reason.
    static func parseClaude(_ data: Data, at date: Date) -> ServiceStatus? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let components = json["components"] as? [[String: Any]] else { return nil }
        let states = Dictionary(components.compactMap { c in (c["name"] as? String).map { ($0, c["status"] as? String) } },
                                uniquingKeysWith: { first, _ in first })
        let known = claudeComponents.compactMap { name, label in statuspageHealth(states[name] ?? nil).map { (label, $0) } }
        // The first of the worst, so Claude Code wins a tie.
        var found: (String, ServiceHealth)?
        for entry in known where found.map({ entry.1 > $0.1 }) ?? true { found = entry }
        guard let worst = found else { return nil }
        guard worst.1 != .operational else { return ServiceStatus(health: .operational, text: nil, page: claudePage, checkedAt: date) }
        let used = Set(claudeComponents.map(\.0))
        let incident = (json["incidents"] as? [[String: Any]] ?? []).first { incident in
            let names = (incident["components"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            return names.isEmpty || !used.isDisjoint(with: names)
        }
        let reason = (incident?["name"] as? String).map { " · \($0)" } ?? ""
        return ServiceStatus(health: worst.1, text: "\(worst.0): \(word(worst.1))\(reason)", page: claudePage, checkedAt: date)
    }

    private static func openCodeHealth(_ status: String?) -> ServiceHealth? {
        switch status {
        case "operational": return .operational
        case "degraded": return .degraded
        case "outage": return .outage
        default: return nil
        }
    }

    /// OpenCode's status: Go and, inside it, the model in use (`model`, its id and its name); the
    /// worse of the two, the model on a tie since it's the more precise. Its incidents have no
    /// title, so the sentence comes from the reason.
    static func parseOpenCode(_ data: Data, model: (id: String, name: String)?, at date: Date) -> ServiceStatus? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["stale"] as? Bool != true,
              let go = (json["components"] as? [[String: Any]])?.first(where: { $0["service"] as? String == "go" }) else { return nil }
        var candidates: [(name: String, health: ServiceHealth, reason: String?)] = []
        if let health = openCodeHealth(go["status"] as? String) {
            candidates.append(("OpenCode Go", health, go["reason"] as? String))
        }
        if let model, let entry = (go["breakdown"] as? [[String: Any]])?.first(where: { $0["id"] as? String == model.id }),
           let health = openCodeHealth(entry["status"] as? String) {
            candidates.append((model.name, health, entry["reason"] as? String))
        }
        // max(by:) keeps the last of equals: the model.
        guard let worst = candidates.max(by: { $0.health < $1.health }) else { return nil }
        guard worst.health != .operational else {
            return ServiceStatus(health: .operational, text: nil, page: openCodePage, checkedAt: date)
        }
        let what: String
        switch worst.reason {
        case "errors": what = "errori"
        case "latency": what = "rallentato"
        default: what = worst.health == .outage ? "non disponibile" : "prestazioni ridotte"
        }
        return ServiceStatus(health: worst.health, text: "\(worst.name): \(what)", page: openCodePage, checkedAt: date)
    }

    /// The fresh reading, or while a page doesn't answer, the last good one for `keepFor`.
    static func merged(previous: ServiceStatus?, fresh: ServiceStatus?, now: Date) -> ServiceStatus? {
        if let fresh { return fresh }
        guard let previous, now.timeIntervalSince(previous.checkedAt) <= keepFor else { return nil }
        return previous
    }
}

extension ServiceStatusReader {
    /// The services with a status page to read.
    static func checks(_ id: ProviderID) -> Bool { id == .claude || id == .opencode }

    /// Reads the service's status page; nil when it doesn't answer or can't be read.
    static func fetch(_ id: ProviderID, model: (id: String, name: String)?) async -> ServiceStatus? {
        let url: URL
        switch id {
        case .claude: url = claudeSummary
        case .opencode: url = openCodeStatus
        case .codex: return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("LimitBar/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let now = Date()
        return id == .claude ? parseClaude(data, at: now) : parseOpenCode(data, model: model, at: now)
    }
}
