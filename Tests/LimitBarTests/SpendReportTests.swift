import Foundation
import Testing
@testable import LimitBar

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}

private let now = date(2026, 11, 3)

private func summary() -> CostLedger.Summary {
    var summary = CostLedger.Summary()
    summary.projects = [
        "claude": ["2026-11-02": ["A": 3, "B": 1]],
        "opencode": ["2026-11-03": ["A": 0.5]],
    ]
    summary.totals = [
        "claude": ["2026-11-02": ["claude-opus-5-5": CostLedger.Totals(cost: 3, input: 100, output: 50),
                                  "claude-haiku-5-5": CostLedger.Totals(cost: 1, input: 10, output: 5)]],
        "opencode": ["2026-11-03": ["deepseek-v4.1-flash": CostLedger.Totals(cost: 0.5, input: 1000, output: 20)]],
    ]
    return summary
}

@Test func periodsListTheirDaysOldestFirst() {
    #expect(SpendPeriod.week.days(now: now) == ["2026-10-28", "2026-10-29", "2026-10-30", "2026-10-31",
                                                "2026-11-01", "2026-11-02", "2026-11-03"])
    #expect(SpendPeriod.month.days(now: now) == ["2026-11-01", "2026-11-02", "2026-11-03"])
    #expect(SpendPeriod.today.days(now: now) == ["2026-11-03"])
    let thirty = SpendPeriod.thirtyDays.days(now: now)
    #expect(thirty.count == 30)
    #expect(thirty.first == "2026-10-05")
    #expect(thirty.last == "2026-11-03")
}

@Test func aWeekAcrossNewYear() {
    #expect(SpendPeriod.week.days(now: date(2027, 1, 2)).first == "2026-12-27")
}

@Test func totalComesFromProjectsOfTheServicesShown() {
    #expect(SpendReport.make(summary: summary(), providers: [.claude, .opencode], period: .week, now: now).total == 4.5)
    #expect(SpendReport.make(summary: summary(), providers: [.claude], period: .week, now: now).total == 4)
}

@Test func modelsByValueWithTokensAndShare() throws {
    let report = SpendReport.make(summary: summary(), providers: [.claude], period: .week, now: now)
    let first = try #require(report.models.first)
    #expect(first.title == "Claude Opus 5.5")
    #expect(first.tokens == 150)
    #expect(first.share == 0.75)
    #expect(report.models.count == 2)
    #expect(report.input == 110)
    #expect(report.output == 55)
    #expect(report.modelsCost == 4)
}

@Test func daysCarryEachServiceCost() throws {
    let report = SpendReport.make(summary: summary(), providers: [.claude, .opencode], period: .week, now: now)
    #expect(report.days.count == 7)
    let second = try #require(report.days.first { $0.day == "2026-11-02" })
    #expect(second.costs[.claude] == 4)
    #expect(report.days.last?.costs[.opencode] == 0.5)
}

@Test func modelTitles() {
    #expect(SpendReport.modelTitle("claude-haiku-4-5-20251001", service: .claude) == "Claude Haiku 4.5")
    #expect(SpendReport.modelTitle("claude-opus-5-5", service: .claude) == "Claude Opus 5.5")
    #expect(SpendReport.modelTitle("deepseek-v4.1-flash", service: .opencode) == "DeepSeek V4.1 Flash")
    #expect(SpendReport.modelTitle("mystery-model", service: .opencode) == "mystery-model")
}

@Test func projectsByValueWithOtherLast() {
    var data = summary()
    data.projects["claude"]?["2026-11-01"] = [ProjectFolder.other: 10]
    let report = SpendReport.make(summary: data, providers: [.claude], period: .week, now: now)
    #expect(report.projects.map(\.name) == ["A", "B", ProjectFolder.other])
    #expect(report.projects.first?.share == 3.0 / 14.0)
}

@Test func anEmptyPeriodHasZerosEverywhere() {
    let report = SpendReport.make(summary: CostLedger.Summary(), providers: [.claude, .opencode], period: .thirtyDays, now: now)
    #expect(report.total == 0)
    #expect(report.days.count == 30)
    #expect(report.days.allSatisfy { $0.costs.values.allSatisfy { $0 == 0 } })
    #expect(report.models.isEmpty)
    #expect(report.projects.isEmpty)
}

@Test func incompleteDaysAreFlagged() {
    var data = summary()
    data.completeSince = ["claude": "2026-10-30"]
    #expect(SpendReport.make(summary: data, providers: [.claude], period: .week, now: now).incompleteBefore == "2026-10-30")
    #expect(SpendReport.make(summary: data, providers: [.claude], period: .today, now: now).incompleteBefore == nil)
}

@Test func thisMonthMatchesThePanel() {
    let data = summary()
    let panel = CostLedger.cost(of: [.claude, .opencode], in: data.projects) { $0.hasPrefix("2026-11") }
    #expect(SpendReport.make(summary: data, providers: [.claude, .opencode], period: .month, now: now).total == panel)
}
