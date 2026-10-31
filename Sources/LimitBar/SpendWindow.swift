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
            window.title = "Spesa"
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
        let now = Date()
        let report = SpendReport.make(summary: store.costs, providers: providers, period: model.period, now: now)
        Form {
            Section {
                Picker("Periodo", selection: $model.period) {
                    ForEach(SpendPeriod.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                summary(report, now: now)
            }
            if report.total > 0 {
                Section("Giorno per giorno") { chart(report) }
                if !report.models.isEmpty {
                    Section {
                        ForEach(report.models) { modelRow($0) }
                    } header: {
                        Text("Modelli")
                    } footer: {
                        // A cent of slack: the two records round differently.
                        if report.modelsCost < report.total - 0.01 {
                            Text("I modelli contano solo i giorni ancora nei registri locali: "
                                 + "\(Format.euros(fromDollars: report.modelsCost)) dei \(Format.euros(fromDollars: report.total)) del periodo.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if !report.projects.isEmpty {
                    Section("Progetti") { ForEach(report.projects) { ProjectRow(project: $0) } }
                }
            } else {
                Section { Text("Nessuna spesa nel periodo").foregroundStyle(.secondary) }
            }
            if let day = report.incompleteBefore {
                Section {
                    Label("I giorni prima del \(Format.rateDate(day)) non sono completi: i registri più vecchi non ci sono più.",
                          systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 520)
    }

    // MARK: Summary

    /// "312 €" with, for this month, how it compares with last month and what the plans saved,
    /// then the tokens.
    @ViewBuilder
    private func summary(_ report: SpendReport, now: Date) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.period == .month ? "Valore di \(Format.month(now))" : "Valore · \(model.period.title.lowercased())")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(Format.wholeEuros(fromDollars: report.total))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            Spacer()
            if model.period == .month {
                VStack(alignment: .trailing, spacing: 3) {
                    let comparison = store.monthComparison(providers, now: now)
                    Text(comparison.map(Format.change) ?? "Stima a prezzi API")
                        .foregroundStyle(.secondary)
                        .help(comparison.map(Format.comparisonNote) ?? "Quanto costerebbe lo stesso lavoro pagandolo a prezzi API")
                    let plans = providers.map { store.monthValue($0, now: now).subscription }
                    // Only a saving if every plan's price is known.
                    let saved = plans.contains(nil) ? 0 : report.total - plans.compactMap { $0 }.reduce(0, +)
                    if saved > 0 {
                        Text("\(Format.wholeEuros(fromDollars: saved)) risparmiati")
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
                tokenItem("Input", report.input)
                tokenItem("Output", report.output)
                tokenItem("Cache letta", report.cacheRead)
                tokenItem("Cache scritta", report.cacheWrite)
            }
            .help("Token dei registri locali, che arrivano indietro fino a 30 giorni per Claude Code")
        }
    }

    private func tokenItem(_ title: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(Self.tokens(count)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
        }
    }

    /// "12", "340 k", "1,2 M", "3,4 Mrd".
    static func tokens(_ count: Int) -> String {
        let value = Double(count)
        func short(_ divided: Double, _ unit: String) -> String {
            let digits = divided < 10 ? 1 : 0
            return divided.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "it_IT"))) + " " + unit
        }
        switch value {
        case 1_000_000_000...: return short(value / 1_000_000_000, "Mrd")
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
            providers.map { (date: day.date, service: $0, euros: ExchangeRate.shared.euros(fromDollars: day.costs[$0] ?? 0)) }
        }
        let selected = model.selectedDate.flatMap { date in
            report.days.first { Calendar.current.isDate($0.date, inSameDayAs: date) }
        }
        return Chart {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                BarMark(x: .value("Giorno", row.date, unit: .day), y: .value("Euro", row.euros))
                    .foregroundStyle(by: .value("Servizio", row.service.title))
            }
            if let selected {
                RuleMark(x: .value("Giorno", selected.date, unit: .day))
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
                AxisValueLabel { if let euros = value.as(Double.self) { Text("\(Int(euros)) €") } }
            }
        }
        .chartXSelection(value: $model.selectedDate)
        .frame(height: 190)
        .padding(.top, selected == nil ? 0 : 4)
    }

    /// "3 nov · Claude 12,40 € · OpenCode 0,30 €".
    private func dayNote(_ day: SpendReport.Day) -> some View {
        let parts = providers.compactMap { id in day.costs[id].flatMap { $0 > 0 ? "\(id.title) \(Format.euros(fromDollars: $0))" : nil } }
        return Text(([Format.day(day.date)] + (parts.isEmpty ? ["nessuna spesa"] : parts)).joined(separator: " · "))
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
            Text("\(Self.tokens(model.tokens)) token").foregroundStyle(.secondary)
            Text("\(Int((model.share * 100).rounded()))%")
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Text(Format.euros(fromDollars: model.cost))
                .fontWeight(.semibold)
                .frame(width: 80, alignment: .trailing)
        }
        .monospacedDigit()
        .help("\(model.title): \(Format.dollars(model.cost)) a prezzi API, input e output senza la cache")
    }
}

/// A project with its share of the period and its value; a click opens its folder in the Finder.
private struct ProjectRow: View {
    let project: SpendReport.Project

    var body: some View {
        let isOther = project.name == ProjectFolder.other
        HStack(spacing: 8) {
            Image(systemName: isOther ? "ellipsis.circle" : "folder").foregroundStyle(.secondary).frame(width: 16)
            Text(isOther ? "Altro" : project.name).lineLimit(1)
            Spacer(minLength: 8)
            Text("\(Int((project.share * 100).rounded()))%")
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Text(Format.euros(fromDollars: project.cost))
                .fontWeight(.semibold)
                .frame(width: 80, alignment: .trailing)
        }
        .monospacedDigit()
        .contentShape(Rectangle())
        .onTapGesture {
            if let folder = project.folder { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) }
        }
        .help(isOther ? "Chat senza cartella e cartelle con più progetti"
                      : project.folder != nil ? "Clic per aprirlo nel Finder" : project.name)
    }
}
