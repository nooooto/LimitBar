import Foundation
import Testing
@testable import LimitBar

/// A week (10 080 minutes), half gone at `now` unless `resetsIn` says otherwise.
private let now = Date(timeIntervalSince1970: 1_793_000_000)
private let day: TimeInterval = 86400

private func week(_ used: Double, resetsIn: TimeInterval? = 3.5 * day, minutes: Int? = 10080) -> UsageWindow {
    UsageWindow(usedPercent: used, resetsAt: resetsIn.map { now.addingTimeInterval($0) }, windowMinutes: minutes)
}

@Test func halfwayAtHalfIsOnTrack() throws {
    let pace = try #require(Pace.of(week(50), now: now))
    #expect(pace.state == .onTrack)
    #expect(pace.text == "In linea")
    #expect(abs(pace.expected - 0.5) < 1e-9)
}

@Test func usingMoreThanTimeIsAhead() throws {
    let pace = try #require(Pace.of(week(70), now: now))
    #expect(pace.state == .ahead)
    #expect(abs(pace.difference - 20) < 1e-9)
    #expect(pace.text == "20% in anticipo")
}

@Test func usingLessThanTimeLeavesMargin() throws {
    let pace = try #require(Pace.of(week(30), now: now))
    #expect(pace.state == .behind)
    #expect(pace.text == "20% di margine")
}

@Test func toleranceIsFivePoints() throws {
    #expect(Pace.of(week(54.9), now: now)?.state == .onTrack)
    let ahead = try #require(Pace.of(week(55), now: now))
    #expect(ahead.state == .ahead)
    #expect(ahead.text == "5% in anticipo")
    let behind = try #require(Pace.of(week(45), now: now))
    #expect(behind.state == .behind)
    #expect(behind.text == "5% di margine")
}

@Test func hiddenInTheFirstTenthOfTheWindow() {
    #expect(Pace.of(week(3, resetsIn: 0.95 * 7 * day), now: now) == nil)
}

@Test func hiddenWhenTheResetIsFurtherThanTheWindow() {
    #expect(Pace.of(week(10, resetsIn: 8 * day), now: now) == nil)
}

@Test func hiddenOnceTheWindowHasReset() {
    #expect(Pace.of(week(80, resetsIn: -60), now: now) == nil)
}

@Test func hiddenWhenUsedUp() {
    #expect(Pace.of(week(99.6), now: now) == nil)
}

@Test func hiddenWithoutLengthOrReset() {
    #expect(Pace.of(week(50, minutes: nil), now: now) == nil)
    #expect(Pace.of(week(50, resetsIn: nil), now: now) == nil)
}
