import Charts
import Foundation
import SwiftUI

enum WindowKind: String, CaseIterable {
    case fiveHour, week

    func window(in snapshot: ProviderSnapshot) -> UsageWindow? {
        switch self {
        case .fiveHour: return snapshot.fiveHour
        case .week: return snapshot.week
        }
    }

    /// "delle 5 ore", "settimanale", or "mensile" for Codex's 30-day window on the Free plan.
    func limitName(_ window: UsageWindow) -> String {
        switch self {
        case .fiveHour: return "delle 5 ore"
        case .week:
            let days = (window.windowMinutes ?? 0) / (24 * 60)
            return (28...31).contains(days) ? "mensile" : "settimanale"
        }
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
        let sample = UsageSample(date: snapshot.updatedAt, fiveHour: snapshot.fiveHour?.usedPercent,
                                 week: snapshot.week?.usedPercent)
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

/// Up to the last 24 hours of a service's main window, drawn as a small area chart. Until a
/// full day of readings exists it spans what there is, so early on it isn't a sliver.
///
/// On top of the readings: a dashed line from "now" to when the window runs out at the current
/// pace (the forecast, when there is one), a dashed rule where the window reset, and, under the
/// pointer, the time and percentage of the nearest reading.
struct HistoryChart: View {
    let samples: [UsageSample]
    let kind: WindowKind
    let current: Double?
    let tint: Color
    let now: Date
    /// When this window runs out at the current pace, if that's before it resets.
    var runsOut: Date? = nil

    // @State is a macro in the current SDK and needs Xcode's plugins; a StateObject builds with the CLT alone.
    @StateObject private var pointer = ChartPointer()

    private struct Point: Identifiable {
        let date: Date
        let value: Double
        var id: Date { date }
    }

    private var points: [Point] {
        let start = now.addingTimeInterval(-86400)
        var points = samples.compactMap { sample -> Point? in
            guard sample.date >= start, let value = sample.value(kind) else { return nil }
            return Point(date: sample.date, value: value)
        }
        // Carry the line to "now", which also shows a reset that happened since the last reading.
        if let current, let last = points.last, now > last.date {
            points.append(Point(date: now, value: current))
        }
        return points
    }

    /// The readings in stretches of one colour: red between readings that both have the window
    /// used up, the service's colour elsewhere. Neighbouring stretches share their end reading,
    /// so the line stays whole.
    private func segments(_ points: [Point]) -> [(points: [Point], usedUp: Bool)] {
        let usedUp = zip(points, points.dropFirst()).map {
            $0.value >= UsageWindow.exhausted && $1.value >= UsageWindow.exhausted
        }
        guard let last = usedUp.last else { return [(points, false)] }
        var segments: [(points: [Point], usedUp: Bool)] = []
        var start = 0
        for gap in 1..<max(usedUp.count, 1) where usedUp[gap] != usedUp[gap - 1] {
            segments.append((Array(points[start...gap]), usedUp[gap - 1]))
            start = gap
        }
        segments.append((Array(points[start...]), last))
        return segments
    }

    /// Readings at the limit with no neighbour there, so no red stretch shows them.
    private func lonePeaks(_ points: [Point]) -> [Point] {
        points.indices.filter { i in
            points[i].value >= UsageWindow.exhausted
                && (i == 0 || points[i - 1].value < UsageWindow.exhausted)
                && (i == points.count - 1 || points[i + 1].value < UsageWindow.exhausted)
        }.map { points[$0] }
    }

    /// The first reading after each reset: where the usage fell back.
    private func resets(in points: [Point]) -> [Date] {
        zip(points, points.dropFirst()).compactMap { before, after in
            after.value < before.value - 0.5 ? after.date : nil
        }
    }

    /// Percentage points the usage has to move before the chart is worth showing.
    private static let minimumChange: Double = 2

    /// The top of the scale follows the highest reading, so low usage still shows its trend:
    /// 25% above it, rounded up to a tenth, between 10% and 100%.
    private static func top(for high: Double) -> Double {
        min(100, max(10, (high * 1.25 / 10).rounded(.up) * 10))
    }

    /// "ultime 24 ore", "ultime 3 ore", "ultimi 40 min".
    private static func spanLabel(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds / 3600)
        if hours >= 2 { return "ultime \(min(hours, 24)) ore" }
        return "ultimi \(Int(seconds / 60)) min"
    }

    var body: some View {
        let points = self.points
        let values = points.map(\.value)
        // Under half an hour of readings would be a sliver at the right edge of a 24-hour chart,
        // and a line that barely moves only takes room: show it once there's a shape to see,
        // or a forecast to draw.
        if let first = points.first, let last = points.last, let low = values.min(), let high = values.max(),
           last.date.timeIntervalSince(first.date) >= 1800 && high - low >= Self.minimumChange
            || runsOut != nil && last.date.timeIntervalSince(first.date) >= 600 {
            chart(points, first: first, high: high)
        }
    }

    private func chart(_ points: [Point], first: Point, high: Double) -> some View {
        // With a forecast the time axis runs on to it, and the scale up to the limit it reaches.
        let end = max(runsOut ?? now, now)
        let top = runsOut != nil ? 100 : Self.top(for: high)
        let hovered = pointer.date.flatMap { date in
            points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        }

        return VStack(alignment: .leading, spacing: 2) {
            Chart {
                ForEach(Array(segments(points).enumerated()), id: \.offset) { index, segment in
                    let colour = segment.usedUp ? Color.red : tint
                    ForEach(segment.points) { point in
                        AreaMark(x: .value("Ora", point.date), y: .value("Uso", point.value),
                                 series: .value("Serie", "uso \(index)"), stacking: .unstacked)
                            .foregroundStyle(LinearGradient(colors: [colour.opacity(0.35), colour.opacity(0.03)],
                                                            startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Ora", point.date), y: .value("Uso", point.value),
                                 series: .value("Serie", "uso \(index)"))
                            .foregroundStyle(colour)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }

                // A single reading at the limit, between two below it, has no stretch to colour.
                ForEach(lonePeaks(points)) { point in
                    PointMark(x: .value("Ora", point.date), y: .value("Uso", point.value))
                        .foregroundStyle(Color.red)
                        .symbolSize(10)
                }

                ForEach(resets(in: points), id: \.self) { date in
                    RuleMark(x: .value("Ora", date))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 0.75, dash: [2, 2]))
                }

                if let runsOut, let current {
                    RuleMark(x: .value("Ora", now))
                        .foregroundStyle(Color.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 0.5))
                    LineMark(x: .value("Ora", now), y: .value("Uso", current), series: .value("Serie", "previsione"))
                        .foregroundStyle(tint.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1.25, dash: [3, 2.5]))
                    LineMark(x: .value("Ora", runsOut), y: .value("Uso", 100.0), series: .value("Serie", "previsione"))
                        .foregroundStyle(tint.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1.25, dash: [3, 2.5]))
                }

                if let hovered {
                    RuleMark(x: .value("Ora", hovered.date))
                        .foregroundStyle(Color.primary.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 0.75))
                    PointMark(x: .value("Ora", hovered.date), y: .value("Uso", hovered.value))
                        .foregroundStyle(tint)
                        .symbolSize(18)
                }
            }
            .chartXScale(domain: first.date...end)
            .chartYScale(domain: 0...top)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let plot = proxy.plotFrame else { return }
                                let x = location.x - geometry[plot].origin.x
                                pointer.date = proxy.value(atX: x, as: Date.self)
                            case .ended:
                                pointer.date = nil
                            }
                        }
                }
            }
            .frame(height: 26)

            HStack {
                if let hovered {
                    // Under the pointer the caption reads out the nearest reading.
                    Text("\(Format.clock(hovered.date)) · \(Int(hovered.value.rounded()))%")
                        .foregroundStyle(hovered.value >= UsageWindow.exhausted ? Color.red : Color.primary)
                } else {
                    Text((kind == .fiveHour ? "5 ore · " : "Limite · ") + Self.spanLabel(now.timeIntervalSince(first.date)))
                }
                Spacer()
                // With a forecast the line above the chart already says when it runs out.
                if runsOut == nil { Text("adesso") }
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }
}

private final class ChartPointer: ObservableObject {
    /// The time under the pointer, while it's over the chart.
    @Published var date: Date?
}
