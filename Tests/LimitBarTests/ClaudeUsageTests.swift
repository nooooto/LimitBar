import Foundation
import Testing
@testable import LimitBar

/// The windows need their length for the pace (see Pace), which Anthropic doesn't send.
@Test func claudeUsageWindowsCarryTheirLength() throws {
    let json: [String: Any] = [
        "five_hour": ["utilization": 51, "resets_at": "2026-10-31T19:49:59.123+00:00"],
        "seven_day": ["utilization": 13, "resets_at": "2026-11-03T12:59:59Z"],
        "seven_day_opus": ["utilization": 4, "resets_at": "2026-11-03T12:59:59Z"],
    ]
    let snapshot = ClaudeProvider.snapshot(usage: json, plan: "Pro", at: Date())
    #expect(snapshot.fiveHour?.windowMinutes == 300)
    #expect(snapshot.week?.windowMinutes == 10080)
    #expect(snapshot.week?.usedPercent == 13)
    let opus = try #require(snapshot.extras.first { $0.label == "Week Opus" })
    #expect(opus.window.windowMinutes == 10080)
}

/// A higher reading from a source without the length (an older cache) mustn't drop it.
@Test func mergedWindowKeepsItsLength() throws {
    let reset = Date().addingTimeInterval(3 * 86400)
    let fresh = UsageWindow(usedPercent: 10, resetsAt: reset, windowMinutes: 10080)
    let cached = UsageWindow(usedPercent: 13, resetsAt: reset)
    let merged = try #require(UsageWindow.merged(fresh, cached))
    #expect(merged.usedPercent == 13)
    #expect(merged.windowMinutes == 10080)
}
