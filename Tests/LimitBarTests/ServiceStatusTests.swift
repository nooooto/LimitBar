import Foundation
import Testing
@testable import LimitBar

private let now = Date(timeIntervalSince1970: 1_793_000_000)

/// A Statuspage summary with these component states and open incidents (name → affected components).
private func claudeSummary(_ states: [String: String], incidents: [(String, [String])] = []) -> Data {
    let names = ["claude.ai", "Claude Console (platform.claude.com)", "Claude API (api.anthropic.com)",
                 "Claude Code", "Claude Cowork", "Claude for Government"]
    let json: [String: Any] = [
        "status": ["indicator": "none", "description": "All Systems Operational"],
        "components": names.map { ["name": $0, "status": states[$0] ?? "operational", "group": false] },
        "incidents": incidents.map { name, components in
            ["name": name, "status": "investigating", "impact": "minor",
             "components": components.map { ["name": $0, "status": "degraded_performance"] }]
        },
        "scheduled_maintenances": [],
    ]
    return try! JSONSerialization.data(withJSONObject: json)
}

/// OpenCode's status with Go's state and reason, and the models in its breakdown.
private func openCodeStatus(go: String, reason: String = "none", models: [(String, String, String)] = [],
                            stale: Bool = false) -> Data {
    let json: [String: Any] = [
        "updatedAt": 1_793_000_000_000, "stale": stale, "status": go,
        "components": [
            ["service": "console", "status": "operational", "reason": "none", "breakdown": []],
            ["service": "go", "status": go, "reason": reason,
             "breakdown": models.map { ["id": $0.0, "status": $0.1, "reason": $0.2] }],
        ],
        "incidents": [], "notes": [], "history": [],
    ]
    return try! JSONSerialization.data(withJSONObject: json)
}

private let deepSeek = (id: "deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash")

@Test func claudeAllOperational() throws {
    let status = try #require(ServiceStatusReader.parseClaude(claudeSummary([:]), at: now))
    #expect(status.health == .operational)
    #expect(status.text == nil)
    #expect(status.page == ServiceStatusReader.claudePage)
    #expect(status.checkedAt == now)
}

@Test func claudeCodeDegradedNamesTheIncident() throws {
    let data = claudeSummary(["Claude Code": "degraded_performance"],
                             incidents: [("Elevated errors on Opus", ["Claude Code"])])
    let status = try #require(ServiceStatusReader.parseClaude(data, at: now))
    #expect(status.health == .degraded)
    #expect(status.text == "Claude Code: prestazioni ridotte · Elevated errors on Opus")
}

@Test func claudeWorstComponentWins() throws {
    let data = claudeSummary(["Claude API (api.anthropic.com)": "major_outage", "Claude Code": "partial_outage"])
    let status = try #require(ServiceStatusReader.parseClaude(data, at: now))
    #expect(status.health == .outage)
    #expect(status.text?.hasPrefix("API di Claude: disservizio grave") == true)
}

@Test func claudeMaintenance() throws {
    let status = try #require(ServiceStatusReader.parseClaude(claudeSummary(["claude.ai": "under_maintenance"]), at: now))
    #expect(status.health == .maintenance)
    #expect(status.text == "claude.ai: manutenzione in corso")
}

@Test func claudeIgnoresComponentsNotUsed() throws {
    let data = claudeSummary(["Claude Cowork": "major_outage"], incidents: [("Cowork down", ["Claude Cowork"])])
    let status = try #require(ServiceStatusReader.parseClaude(data, at: now))
    #expect(status.health == .operational)
    #expect(status.text == nil)
}

@Test func claudeIncidentWithoutComponentsCounts() throws {
    let data = claudeSummary(["Claude Code": "degraded_performance"], incidents: [("Investigating reports", [])])
    let status = try #require(ServiceStatusReader.parseClaude(data, at: now))
    #expect(status.text == "Claude Code: prestazioni ridotte · Investigating reports")
}

@Test func openCodeModelInUseSlow() throws {
    let data = openCodeStatus(go: "operational", models: [("deepseek-v4.1-flash", "degraded", "latency"),
                                                          ("glm-5.3", "operational", "none")])
    let status = try #require(ServiceStatusReader.parseOpenCode(data, model: deepSeek, at: now))
    #expect(status.health == .degraded)
    #expect(status.text == "DeepSeek V4.1 Flash: rallentato")
    #expect(status.page == ServiceStatusReader.openCodePage)
}

@Test func openCodeGoDownWithErrors() throws {
    let data = openCodeStatus(go: "outage", reason: "errors", models: [("deepseek-v4.1-flash", "operational", "none")])
    let status = try #require(ServiceStatusReader.parseOpenCode(data, model: deepSeek, at: now))
    #expect(status.health == .outage)
    #expect(status.text == "OpenCode Go: errori")
}

@Test func openCodeWordsWithoutAReason() throws {
    let degraded = try #require(ServiceStatusReader.parseOpenCode(openCodeStatus(go: "degraded"), model: nil, at: now))
    #expect(degraded.text == "OpenCode Go: prestazioni ridotte")
    let outage = try #require(ServiceStatusReader.parseOpenCode(openCodeStatus(go: "outage"), model: nil, at: now))
    #expect(outage.text == "OpenCode Go: non disponibile")
}

/// A page that answers but doesn't know is no signal, and replaces an older alarm.
@Test func openCodeStaleIsUnknown() throws {
    let status = try #require(ServiceStatusReader.parseOpenCode(openCodeStatus(go: "outage", stale: true), model: nil, at: now))
    #expect(status.health == .unknown)
    #expect(status.text == nil)
}

@Test func openCodeUnknownStatusIsUnknown() throws {
    let status = try #require(ServiceStatusReader.parseOpenCode(openCodeStatus(go: "unknown"), model: nil, at: now))
    #expect(status.health == .unknown)
}

@Test func anUnknownAnswerReplacesAnOlderOutage() throws {
    let outage = ServiceStatus(health: .outage, text: "x", page: ServiceStatusReader.openCodePage,
                               checkedAt: now.addingTimeInterval(-5 * 60))
    let unknown = try #require(ServiceStatusReader.parseOpenCode(openCodeStatus(go: "unknown"), model: nil, at: now))
    #expect(ServiceStatusReader.merged(previous: outage, fresh: unknown, now: now)?.health == .unknown)
}

@Test func claudeIncidentOfTheWorstComponentWins() throws {
    let data = claudeSummary(["claude.ai": "major_outage", "Claude Code": "degraded_performance"],
                             incidents: [("Slow Claude Code", ["Claude Code"]), ("claude.ai is down", ["claude.ai"])])
    let status = try #require(ServiceStatusReader.parseClaude(data, at: now))
    #expect(status.text == "claude.ai: disservizio grave · claude.ai is down")
}

@Test func unreadablePagesAreUnknown() {
    let html = Data("<html><body>Captive portal</body></html>".utf8)
    #expect(ServiceStatusReader.parseClaude(html, at: now) == nil)
    #expect(ServiceStatusReader.parseOpenCode(html, model: deepSeek, at: now) == nil)
}

@Test func lastGoodStatusKeptForHalfAnHour() throws {
    let recent = ServiceStatus(health: .degraded, text: "x", page: ServiceStatusReader.claudePage,
                               checkedAt: now.addingTimeInterval(-10 * 60))
    #expect(ServiceStatusReader.merged(previous: recent, fresh: nil, now: now) == recent)
    let old = ServiceStatus(health: .degraded, text: "x", page: ServiceStatusReader.claudePage,
                            checkedAt: now.addingTimeInterval(-31 * 60))
    #expect(ServiceStatusReader.merged(previous: old, fresh: nil, now: now) == nil)
    let fresh = ServiceStatus(health: .operational, text: nil, page: ServiceStatusReader.claudePage, checkedAt: now)
    #expect(ServiceStatusReader.merged(previous: recent, fresh: fresh, now: now) == fresh)
}

private func status(_ health: ServiceHealth, minutesAgo: Double = 0) -> ServiceStatus {
    ServiceStatus(health: health, text: health == .operational ? nil : "x", page: ServiceStatusReader.claudePage,
                  checkedAt: now.addingTimeInterval(-minutesAgo * 60))
}

@Test func switchedOffClearsEveryStatus() {
    let result = UsageStore.statusesAfterCheck(previous: [.claude: status(.outage)], fresh: [:], enabled: false,
                                               providers: [.claude, .opencode], now: now)
    #expect(result.isEmpty)
}

@Test func onlyTheServicesShownAreKept() {
    let result = UsageStore.statusesAfterCheck(previous: [:], fresh: [.claude: status(.degraded), .opencode: status(.outage)],
                                               enabled: true, providers: [.claude], now: now)
    #expect(result == [.claude: status(.degraded)])
}

@Test func aPageThatDoesNotAnswerKeepsTheLastStatus() {
    let previous = status(.degraded, minutesAgo: 10)
    let result = UsageStore.statusesAfterCheck(previous: [.claude: previous], fresh: [.claude: nil], enabled: true,
                                               providers: [.claude], now: now)
    #expect(result[.claude] == previous)
}
