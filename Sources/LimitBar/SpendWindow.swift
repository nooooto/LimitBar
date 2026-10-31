import AppKit
import Charts
import SwiftUI

/// The Spesa window: the work of a period at API prices, day by day, by model and by project.
/// Opened from the value card in the panel; one window, brought forward when asked again.
@MainActor
final class SpendWindow {
    static let shared = SpendWindow()
    private var window: NSWindow?

    func show(store: UsageStore) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SpendView(store: store)))
            window.title = L("Spending")
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: 560, height: 640))
            window.contentMinSize = NSSize(width: 560, height: 520)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        // A menu bar app isn't frontmost on its own; without this the window opens behind others.
        // Taking the focus also closes the panel, which goes away when it stops being key.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The period shown, remembered, and the day under the pointer in the chart.
@MainActor
private final class SpendModel: ObservableObject {
    @Published var period: SpendPeriod {
        didSet { UserDefaults.standard.set(period.rawValue, forKey: "spend.period") }
    }
    @Published var selectedDate: Date?

    init() {
        period = UserDefaults.standard.string(forKey: "spend.period").flatMap(SpendPeriod.init(rawValue:)) ?? .month
    }
}

private struct SpendView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings = AppSettings.shared
    // @State is a macro in the current SDK and needs Xcode's plugins; a StateObject builds with the CLT alone.
    @StateObject private var model = SpendModel()

    /// Only the services whose work can be priced (see CostLedger).
    private var providers: [ProviderID] { settings.visibleProviders.filter(\.isInCostLedger) }

    var body: some View {
        // A minute's tick, so a window left open past midnight moves on to the new day.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    private func content(now: Date) -> some View {
        let report = SpendReport.make(summary: store.costs, providers: providers, period: model.period, now: now)
        return Form {
            Section {
                Picker(L("Period"), selection: $model.period) {
                    ForEach(SpendPeriod.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                summary(report, now: now)
            }
            if report.total > 0 {
                Section(L("Day by day")) { chart(report) }
                if !report.models.isEmpty {
                    Section {
                        ForEach(report.models) { modelRow($0) }
                    } header: {
                        Text(L("Models"))
                    } footer: {
                        // A cent of slack: the two records round differently.
                        if report.modelsCost < report.total - 0.01 {
                            Text(L("The models only count the days still in the local logs: %@ of the period's %@.",
                                   Format.money(report.modelsCost), Format.money(report.total)))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if !report.projects.isEmpty {
                    Section(L("Projects")) { ForEach(report.projects) { ProjectRow(project: $0) } }
                }
            } else {
                Section { Text(L("No spending in this period")).foregroundStyle(.secondary) }
            }
            if let day = report.incompleteBefore {
                Section {
                    Label(L("The days before %@ aren't complete: the older logs are gone.", Format.rateDate(day)),
                          systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Summary

    /// "312 €" with, for this month, how it compares with last month and what the plans saved,
    /// then the tokens.
    @ViewBuilder
    private func summary(_ report: SpendReport, now: Date) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.period == .month ? L("Value in %@", Format.month(now)) : L("Value · %@", model.period.title.lowercased()))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(Format.wholeMoney(report.total))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            Spacer()
            if model.period == .month {
                VStack(alignment: .trailing, spacing: 3) {
                    let comparison = store.monthComparison(providers, now: now)
                    Text(comparison.map(Format.change) ?? L("Estimate at API prices"))
                        .foregroundStyle(.secondary)
                        .help(comparison.map(Format.comparisonNote) ?? L("What the same work would cost paid at API prices"))
                    let plans = providers.map { store.monthValue($0, now: now).subscription }
                    // Only a saving if every plan's price is known.
                    let saved = plans.contains(nil) ? 0 : report.total - plans.compactMap { $0 }.reduce(0, +)
                    if saved > 0 {
                        Text(L("%@ saved", Format.wholeMoney(saved)))
                            .fontWeight(.semibold)
                            .foregroundStyle(Color(nsColor: .systemGreen))
                    }
                }
                .font(.system(size: 12))
                .monospacedDigit()
            }
        }
        if report.input + report.output + report.cacheRead + report.cacheWrite > 0 {
            HStack(spacing: 14) {
                tokenItem(L("Input"), report.input)
                tokenItem(L("Output"), report.output)
                tokenItem(L("Cache read"), report.cacheRead)
                tokenItem(L("Cache write"), report.cacheWrite)
            }
            .help(L("Tokens from the local logs, which go back up to 30 days for Claude Code"))
        }
    }

    private func tokenItem(_ title: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(Self.tokens(count)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
        }
    }

    /// "12", "340 k", "1.2 M", "3.4 B".
    static func tokens(_ count: Int) -> String {
        let value = Double(count)
        func short(_ divided: Double, _ unit: String) -> String {
            let digits = divided < 10 ? 1 : 0
            return divided.formatted(.number.precision(.fractionLength(digits)).locale(Format.locale)) + " " + unit
        }
        switch value {
        case 1_000_000_000...: return short(value / 1_000_000_000, L("B", context: "billion"))
        case 1_000_000...: return short(value / 1_000_000, "M")
        case 1_000...: return short(value / 1_000, "k")
        default: return "\(count)"
        }
    }

    // MARK: Chart

    /// A bar a day, stacked by service in its colour; the day under the pointer gets a rule and
    /// what each service was worth on it.
    private func chart(_ report: SpendReport) -> some View {
        let rows = report.days.flatMap { day in
            providers.map { (date: day.date, service: $0, amount: Format.convert(day.costs[$0] ?? 0)) }
        }
        // The tallest day, for the axis labels' precision.
        let top = report.days.map { day in day.costs.values.reduce(0) { $0 + Format.convert($1) } }.max() ?? 0
        let selected = model.selectedDate.flatMap { date in
            report.days.first { Calendar.current.isDate($0.date, inSameDayAs: date) }
        }
        return Chart {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                BarMark(x: .value(L("Day"), row.date, unit: .day), y: .value(L("Amount"), row.amount))
                    .foregroundStyle(by: .value(L("Service"), row.service.title))
            }
            if let selected {
                RuleMark(x: .value(L("Day"), selected.date, unit: .day))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        dayNote(selected)
                    }
            }
        }
        .chartForegroundStyleScale(domain: providers.map(\.title), range: providers.map(\.tint))
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel { if let amount = value.as(Double.self) { Text(Format.axisMoney(amount, top: top)) } }
            }
        }
        .chartXSelection(value: $model.selectedDate)
        .frame(height: 190)
        .padding(.top, selected == nil ? 0 : 4)
    }

    /// "3 nov · Claude 12,40 € · OpenCode 0,30 €".
    private func dayNote(_ day: SpendReport.Day) -> some View {
        let parts = providers.compactMap { id in day.costs[id].flatMap { $0 > 0 ? "\(id.title) \(Format.money($0))" : nil } }
        return Text(([Format.day(day.date)] + (parts.isEmpty ? [L("no spending")] : parts)).joined(separator: " · "))
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: Models

    private func modelRow(_ model: SpendReport.Model) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: model.service.logo).resizable().frame(width: 16, height: 16)
            Text(model.title).lineLimit(1)
            Spacer(minLength: 8)
            Text(L("%@ tokens", Self.tokens(model.tokens))).foregroundStyle(.secondary)
            Text("\(Int((model.share * 100).rounded()))%")
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Text(Format.money(model.cost))
                .fontWeight(.semibold)
                .frame(width: 80, alignment: .trailing)
        }
        .monospacedDigit()
        .help(L("%@: %@ at API prices, input and output without the cache", model.title, Format.dollars(model.cost)))
    }
}

/// A project with its share of the period and its value; a click opens its folder in the Finder.
private struct ProjectRow: View {
    let project: SpendReport.Project

    var body: some View {
        let isOther = project.name == ProjectFolder.other
        HStack(spacing: 8) {
            Image(systemName: isOther ? "ellipsis.circle" : "folder").foregroundStyle(.secondary).frame(width: 16)
            Text(isOther ? L("Other") : project.name).lineLimit(1)
            Spacer(minLength: 8)
            Text("\(Int((project.share * 100).rounded()))%")
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Text(Format.money(project.cost))
                .fontWeight(.semibold)
                .frame(width: 80, alignment: .trailing)
        }
        .monospacedDigit()
        .contentShape(Rectangle())
        .onTapGesture {
            if let folder = project.folder { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) }
        }
        .help(isOther ? L("Chats without a folder and folders with several projects")
                      : project.folder != nil ? L("Click to open it in the Finder") : project.name)
    }
}
