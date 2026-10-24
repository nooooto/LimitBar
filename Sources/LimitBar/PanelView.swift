import SwiftUI

/// The panel, laid out like a terminal program: lines of monospaced text on a grid of
/// `Terminal.columns` characters, bars and charts made of block characters, two tones of text and
/// colour only for limits running out (see Terminal).
struct PanelView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 0) {
                header(context.date)
                Rule()
                ForEach(settings.visibleProviders) { id in
                    // A click opens the service's own usage page, like a menu item.
                    HoverRow(action: { id.openUsagePage() }) {
                        Group {
                            if id == .opencode {
                                OpenCodeBlock(state: store.state(id), now: context.date,
                                              workingSessions: store.activity.sessions(id))
                            } else {
                                LimitsBlock(provider: id, state: store.state(id), now: context.date,
                                            samples: store.history[id] ?? [], showHistory: settings.showHistory,
                                            workingSessions: store.activity.sessions(id))
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .help(id.usageDestination)
                    if id == .claude, store.state(.claude).needsSignIn || store.claudeLoginPending {
                        ClaudeSignIn(store: store)
                    }
                    Rule()
                }
                if settings.showValue {
                    // Only the services whose work can be priced (see CostLedger).
                    ValueBlock(store: store, providers: settings.visibleProviders.filter(\.isInCostLedger), now: context.date)
                }
                footer
            }
            .padding(.vertical, 6)
            .font(Terminal.font())
            .foregroundStyle(Terminal.foreground)
        }
        .frame(width: Terminal.width)
    }

    private func header(_ now: Date) -> some View {
        HStack {
            Text("limitbar").font(Terminal.font(weight: .bold))
            Spacer()
            Text(Format.stamp(now)).foregroundStyle(Terminal.dim)
        }
        .padding(.horizontal, Terminal.padding)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            MenuLine(title: store.isRefreshing ? "⋯ aggiornamento" : "↻ aggiorna ora", shortcut: "⌘R") {
                Task { await store.refresh(force: true) }
            }
            .keyboardShortcut("r", modifiers: .command)

            MenuLine(title: "⚙ impostazioni…", shortcut: "⌘,") { SettingsWindow.shared.show() }
                .keyboardShortcut(",", modifiers: .command)

            if store.claudeSignedInHere {
                MenuLine(title: "⏏ disconnetti claude", shortcut: nil) { store.signOutOfClaude() }
            }

            MenuLine(title: "⏻ esci", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.top, 4)
    }
}

// MARK: - Building blocks

/// A line across the panel, drawn with box characters like the rest.
private struct Rule: View {
    var body: some View {
        Text(String(repeating: "─", count: Terminal.columns))
            .foregroundStyle(Terminal.dim.opacity(0.45))
            .lineLimit(1)
            .padding(.horizontal, Terminal.padding)
    }
}

/// "claude pro                        ● al lavoro": a service's name and plan, then its state.
private struct TitleLine: View {
    let title: String
    /// The service's signature colour, for its name and its "al lavoro".
    let tint: Color
    let plan: String?
    let snapshot: ProviderSnapshot?
    let workingSessions: Int
    let now: Date

    var body: some View {
        HStack(spacing: 0) {
            Text(title).font(Terminal.font(weight: .bold)).foregroundStyle(tint)
            if let plan { Text(" " + plan.lowercased()).foregroundStyle(Terminal.dim) }
            Spacer(minLength: Terminal.cell)
            if workingSessions > 0 {
                Text(workingSessions == 1 ? "● al lavoro" : "● \(workingSessions) al lavoro")
                    .font(Terminal.font(weight: .semibold))
                    .foregroundStyle(tint)
            } else if let snapshot {
                // A terminal: the numbers came from Claude Code's status line.
                Text((snapshot.source == "statusline" ? "⌘ " : "↻ ") + Format.ago(snapshot.updatedAt, now: now))
                    .foregroundStyle(Terminal.dim)
            }
        }
        .lineLimit(1)
    }
}

/// "5 ore  ━━━━━━━━╾───────  53%  tra 2h50": a limit on one line. The bar, percentage and
/// the right-hand note fit the grid: 6 + 1 + 16 + 1 + 4 + 2 + 16 characters.
private struct LimitLine: View {
    let label: String
    let percent: Double
    let note: String
    /// The bar's colour while the limit isn't running out: the service's.
    var tint: Color = Terminal.foreground

    var body: some View {
        let bar = Terminal.bar(percent, width: 16)
        HStack(spacing: 0) {
            Text(Terminal.fit(label, 7)).foregroundStyle(Terminal.dim).fixedSize()
            Text(bar.filled).foregroundStyle(Terminal.level(percent, normal: tint)).fixedSize()
            Text(bar.empty).foregroundStyle(Terminal.dim.opacity(0.5)).fixedSize()
            Text(String(format: "%4d%%", Int(percent.rounded())))
                .font(Terminal.font(weight: .semibold))
                .foregroundStyle(Terminal.level(percent))
                .frame(width: Terminal.cols(5), alignment: .trailing)
            Text(note)
                .foregroundStyle(Terminal.dim)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .lineLimit(1)
    }
}

/// A line of secondary text that may wrap: "› …", "! …".
private struct NoteLine: View {
    let mark: String
    let text: String
    var color: Color = Terminal.dim

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(mark + " ").foregroundStyle(color)
            Text(text).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Services

/// Claude (and Codex, if it's switched back on): its limits as bar lines, the forecast, and the
/// last hours as a sparkline.
private struct LimitsBlock: View {
    let provider: ProviderID
    let state: ProviderState
    let now: Date
    let samples: [UsageSample]
    let showHistory: Bool
    let workingSessions: Int

    private var snapshot: ProviderSnapshot? { state.snapshot }

    /// The window that runs out first at the current pace, if one does before it resets.
    private var forecast: (kind: WindowKind, window: UsageWindow, date: Date)? {
        guard let snapshot else { return nil }
        return WindowKind.allCases.compactMap { kind -> (WindowKind, UsageWindow, Date)? in
            guard let window = kind.window(in: snapshot),
                  let date = UsageHistory.forecast(kind, window: window, samples: samples, now: now) else { return nil }
            return (kind, window, date)
        }
        .min { $0.2 < $1.2 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TitleLine(title: provider.title.lowercased(), tint: provider.tint, plan: snapshot?.plan ?? provider.toolName,
                      snapshot: snapshot, workingSessions: workingSessions, now: now)
            if let snapshot {
                VStack(alignment: .leading, spacing: 2) {
                    line("5 ore", snapshot.fiveHour)
                    line(WindowKind.week.limitName(snapshot.week ?? UsageWindow(usedPercent: 0)) == "mensile" ? "mese" : "sett.",
                         snapshot.week)
                    ForEach(snapshot.extras) { extra in line(extra.label.lowercased(), extra.window) }
                }
                .padding(.top, 2)
                if let forecast {
                    NoteLine(mark: "›", text: "a questo ritmo finisci il limite \(forecast.kind.limitName(forecast.window)) "
                             + Format.at(forecast.date, now: now), color: Terminal.foreground)
                }
                if showHistory, let spark = Sparkline(samples: samples, snapshot: snapshot, now: now, tint: provider.tint) {
                    spark
                }
            } else if state.error == nil {
                Text("in attesa di dati…").foregroundStyle(Terminal.dim)
            }
            if let note = snapshot?.note { NoteLine(mark: "i", text: note) }
            if let error = state.error {
                NoteLine(mark: "!", text: error, color: Terminal.red)
            } else if let notice = state.notice {
                NoteLine(mark: "·", text: notice)
            }
        }
    }

    @ViewBuilder
    private func line(_ label: String, _ window: UsageWindow?) -> some View {
        if let window {
            let left = window.resetsAt.flatMap { Format.shortCountdown($0, now: now) }
            LimitLine(label: label, percent: window.effectivePercent(at: now), note: left.map { "tra " + $0 } ?? "",
                      tint: provider.tint)
                .help(window.resetsAt.map { "Si azzera " + Format.at($0, now: now) } ?? "")
        } else {
            HStack(spacing: 0) {
                Text(Terminal.fit(label, 7)).foregroundStyle(Terminal.dim)
                Text("nessun limite").foregroundStyle(Terminal.dim)
            }
        }
    }
}

/// "▁▁▂▃▃▅▅▅▅▆▇▁▂▃▃▃  5 ore · 21h": the main window over the last day, one character per slice of
/// time; nil until there's half an hour of readings that actually move.
private struct Sparkline: View {
    let values: [Double]
    let label: String
    let tint: Color

    init?(samples: [UsageSample], snapshot: ProviderSnapshot, now: Date, tint: Color) {
        self.tint = tint
        let kind: WindowKind = snapshot.fiveHour != nil ? .fiveHour : .week
        var points = samples.compactMap { sample -> (Date, Double)? in
            guard sample.date >= now.addingTimeInterval(-86400), let value = sample.value(kind) else { return nil }
            return (sample.date, value)
        }
        if let current = kind.window(in: snapshot)?.effectivePercent(at: now) { points.append((now, current)) }
        guard let first = points.first, now.timeIntervalSince(first.0) >= 1800,
              let high = points.map(\.1).max(), let low = points.map(\.1).min(), high - low >= 2 else { return nil }
        // Each character shows the reading in force at the end of its slice.
        let width = 30
        let slice = now.timeIntervalSince(first.0) / Double(width)
        values = (1...width).map { index in
            let end = first.0.addingTimeInterval(slice * Double(index))
            return points.last { $0.0 <= end }?.1 ?? first.1
        }
        let hours = Int(now.timeIntervalSince(first.0) / 3600)
        label = (kind == .fiveHour ? "5 ore" : "limite") + " · " + (hours >= 1 ? "\(hours)h" : "\(Int(now.timeIntervalSince(first.0) / 60))m")
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(Terminal.sparkline(values)).foregroundStyle(tint).fixedSize()
            Text("  " + label)
                .foregroundStyle(Terminal.dim)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .lineLimit(1)
        .padding(.top, 2)
    }
}

/// OpenCode Go: its limits are one quota shared by all models (see OpenCodeProvider), so the
/// model in use, the shared lines with the dollars left in that model, and who used the 5 hours.
private struct OpenCodeBlock: View {
    let state: ProviderState
    let now: Date
    let workingSessions: Int

    private var snapshot: ProviderSnapshot? { state.snapshot }
    private var models: [ModelUsage] { snapshot?.models ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TitleLine(title: "opencode", tint: ProviderID.opencode.tint, plan: snapshot?.plan ?? "go", snapshot: snapshot,
                      workingSessions: workingSessions, now: now)
            if let snapshot {
                let current = models.first(where: \.inUse)
                if let current {
                    HStack(spacing: 0) {
                        Text(Terminal.fit("modello", 8)).foregroundStyle(Terminal.dim)
                        Text(current.name)
                        if current.isFree { Text(" · gratis").foregroundStyle(Terminal.dim) }
                    }
                    .lineLimit(1)
                }
                let month = snapshot.extras.first { $0.label == "Mese" }?.window
                let limits: [(label: String, period: String, window: UsageWindow?, cap: Double?)] = [
                    ("5 ore", "delle 5 ore", snapshot.fiveHour, current?.fiveHour.cap),
                    ("sett.", "settimanale", snapshot.week, current?.week.cap),
                    ("mese", "mensile", month, current?.month.cap),
                ]
                if let full = limits.first(where: { ($0.window?.effectivePercent(at: now) ?? 0) >= UsageWindow.exhausted }),
                   let free = full.window?.resetsAt {
                    NoteLine(mark: "✕", text: "limite \(full.period) pieno · di nuovo libero \(Format.at(free, now: now))",
                             color: Terminal.red)
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(limits, id: \.label) { limit in
                        if let window = limit.window {
                            sharedLine(limit.label, window, cap: current?.isFree == true ? nil : limit.cap, model: current?.name)
                        }
                    }
                }
                .padding(.top, 2)
                let users = models.filter { $0.fiveHour.share >= 0.5 }.sorted { $0.fiveHour.share > $1.fiveHour.share }
                if !users.isEmpty {
                    Text("chi ha usato le 5 ore").foregroundStyle(Terminal.dim).padding(.top, 4)
                    ForEach(users.prefix(4)) { model in ShareLine(model: model) }
                }
            } else if state.error == nil {
                Text("in attesa di dati…").foregroundStyle(Terminal.dim)
            }
            if snapshot != nil, models.isEmpty {
                Text("nessuna richiesta con go negli ultimi 30 giorni").foregroundStyle(Terminal.dim)
            }
            if let error = state.error {
                NoteLine(mark: "!", text: error, color: Terminal.red)
            } else if let notice = state.notice {
                NoteLine(mark: "·", text: notice)
            }
            if snapshot != nil {
                NoteLine(mark: "i", text: "stima da questo mac · limiti condivisi da tutti i modelli")
            }
        }
        .help(models.filter { $0.month.share > 0 || $0.requests > 0 }.map {
            "\($0.name): \($0.requests == 1 ? "1 richiesta" : "\($0.requests) richieste"), \(Format.dollars($0.spent)), "
                + "\(Int($0.month.share.rounded()))% del mese"
        }.joined(separator: "\n"))
    }

    /// A shared limit, with what's left of it in dollars of the model in use, or with no paid model
    /// in use, the time until it frees up.
    private func sharedLine(_ label: String, _ window: UsageWindow, cap: Double?, model: String?) -> some View {
        let value = window.effectivePercent(at: now)
        let left = cap.map { $0 * max(0, 100 - value) / 100 }
        let note = left.map { Format.dollars($0) + " rimasti" }
            ?? window.resetsAt.flatMap { Format.shortCountdown($0, now: now) }.map { "tra " + $0 } ?? ""
        var tooltip: [String] = []
        if let left, let model { tooltip.append("Con \(model) restano \(Format.dollars(left))") }
        if let resetsAt = window.resetsAt, resetsAt > now { tooltip.append("si libera " + Format.at(resetsAt, now: now)) }
        return LimitLine(label: label, percent: value, note: note, tint: ProviderID.opencode.tint)
            .help(tooltip.joined(separator: " · "))
    }
}

/// "Kimi K3.1 Pro         ━━━━━━━━ 100%   3,00 $": a model's slice of the shared 5 hours.
private struct ShareLine: View {
    let model: ModelUsage

    var body: some View {
        let share = model.fiveHour.share
        let bar = Terminal.bar(min(share, 100), width: 8)
        HStack(spacing: 0) {
            Text(Terminal.fit("  " + model.name, 22)).fixedSize()
            Text(bar.filled).foregroundStyle(Terminal.level(share, normal: ProviderID.opencode.tint)).fixedSize()
            Text(bar.empty).foregroundStyle(Terminal.dim.opacity(0.5)).fixedSize()
            Text(String(format: "%4d%%", Int(share.rounded())))
                .font(Terminal.font(weight: .semibold))
                .foregroundStyle(Terminal.level(share))
                .frame(width: Terminal.cols(5), alignment: .trailing)
            Text(Format.dollars(model.fiveHour.used))
                .foregroundStyle(Terminal.dim)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .lineLimit(1)
    }
}

// MARK: - Value at API prices

/// This month's work at API prices next to each plan, then the projects it went to.
private struct ValueBlock: View {
    @ObservedObject var store: UsageStore
    let providers: [ProviderID]
    let now: Date

    private static let projectsShown = 3

    var body: some View {
        let values = providers.map { ($0, store.monthValue($0, now: now)) }
        let total = values.reduce(0) { $0 + $1.1.cost }
        let subscriptions = values.compactMap(\.1.subscription)
        // Only a saving if every plan's price is known.
        let saved = subscriptions.count == values.count ? total - subscriptions.reduce(0, +) : 0
        let projects = store.monthProjects(providers, shown: Self.projectsShown, now: now)
        let comparison = store.monthComparison(providers, now: now)
        if total > 0 {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("valore di \(Format.month(now))").font(Terminal.font(weight: .bold))
                    Spacer()
                    Text(comparison.map(Format.change) ?? "stima a prezzi api").foregroundStyle(Terminal.dim)
                }
                .help(comparison.map(Format.comparisonNote) ?? "")
                .padding(.bottom, 2)
                ForEach(values, id: \.0) { id, value in
                    valueLine(id.title.lowercased(), detail: planLine(id, value), amount: value.cost)
                        .help(priceNote(id, value))
                }
                if saved > 0 {
                    valueLine("risparmiato", detail: Text("rispetto alle api"), amount: saved, bold: true)
                }
                if !projects.isEmpty {
                    HStack {
                        Text("progetti").font(Terminal.font(weight: .bold))
                        Spacer()
                        Text("quota del mese").foregroundStyle(Terminal.dim)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                    ForEach(projects) { project in projectLine(project, monthTotal: total) }
                }
            }
            .padding(.horizontal, Terminal.padding)
            .padding(.vertical, 8)
            Rule()
        }
    }

    /// "claude      ×14,4 il pro           258 €"
    private func valueLine(_ name: String, detail: Text, amount: Double, bold: Bool = false) -> some View {
        HStack(spacing: 0) {
            Text(Terminal.fit(name, 12)).fixedSize()
            detail.foregroundStyle(Terminal.dim).fixedSize()
                .frame(width: Terminal.cols(20), alignment: .leading)
            Text(Format.wholeEuros(fromDollars: amount))
                .font(Terminal.font(weight: bold ? .bold : .semibold))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .lineLimit(1)
    }

    /// A project, its share of the month as a bar, and its value. A click opens its folder in the
    /// Finder; Altro and folders that are gone don't.
    @ViewBuilder
    private func projectLine(_ project: ProjectValue, monthTotal: Double) -> some View {
        let share = monthTotal > 0 ? min(project.total / monthTotal, 1) * 100 : 0
        let bar = Terminal.bar(share, width: 14)
        let content = HStack(spacing: 0) {
            Text(Terminal.fit((project.folder == nil ? "  " : "▸ ") + project.name.lowercased(), 18)).fixedSize()
            Text(bar.filled).foregroundStyle(dominantTint(project)).fixedSize()
            Text(bar.empty).foregroundStyle(Terminal.dim.opacity(0.5)).fixedSize()
            Text(Format.wholeEuros(fromDollars: project.total))
                .font(Terminal.font(weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .lineLimit(1)
        if let folder = project.folder {
            HoverRow(inset: false, action: { NSWorkspace.shared.open(URL(fileURLWithPath: folder, isDirectory: true)) }) {
                content
            }
            .help(projectNote(project, share: share) + "\nClic per aprirlo nel Finder")
        } else {
            content.help(projectNote(project, share: share))
        }
    }

    /// The colour of the service that did most of a project's work.
    private func dominantTint(_ project: ProjectValue) -> Color {
        project.costs.max { $0.value < $1.value }?.key.tint ?? Terminal.foreground
    }

    /// Tooltip: "LimitBar: Claude 80,12 € · 52% del mese", and for Altro what's in it.
    private func projectNote(_ project: ProjectValue, share: Double) -> String {
        let services = providers.compactMap { id in project.costs[id].map { "\(id.title) \(Format.euros(fromDollars: $0))" } }
        let note = "\(project.name): \(services.joined(separator: ", ")) · \(Int(share.rounded()))% del mese"
        guard project.name == ProjectFolder.other else { return note }
        let folded = project.folded.isEmpty ? "" : ", e \(project.folded.joined(separator: ", "))"
        return note + "\nChat senza cartella, cartelle con più progetti\(folded)"
    }

    /// "×14,4 il pro" (the multiple in the service's colour): how many times its price the plan
    /// paid back; "piano free" for free plans.
    private func planLine(_ id: ProviderID, _ value: ServiceValue) -> Text {
        let plan = (store.state(id).snapshot?.plan ?? "").lowercased()
        if let multiple = value.multiple {
            let times = Text(Format.multiple(multiple)).font(Terminal.font(weight: .semibold)).foregroundColor(id.tint)
            return Text("\(times) il \(plan)")
        }
        return Text(plan.isEmpty ? "" : "piano \(plan)")
    }

    /// Tooltip: what the plan costs, the exchange rate, and what the value is compared with.
    private func priceNote(_ id: ProviderID, _ value: ServiceValue) -> String {
        let plan = store.state(id).snapshot?.plan ?? id.title
        let rate = "cambio BCE del \(Format.rateDate(ExchangeRate.shared.rateDate))"
        guard let subscription = value.subscription else { return "Prezzo del piano \(plan) non noto" }
        if subscription == 0 { return "\(plan): gratis" }
        return "\(plan): \(Int(subscription)) $ al mese, circa \(Format.euros(fromDollars: subscription)) al \(rate) "
            + "(prezzi senza IVA, come quelli delle API)"
    }
}

// MARK: - Claude sign-in

private struct ClaudeSignIn: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if store.claudeLoginPending {
                Text("approva nel browser, copia il codice che compare, poi:")
                    .foregroundStyle(Terminal.dim)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Terminal.cell * 2) {
                    TextButton(title: "[ incolla codice ]") { Task { await store.finishClaudeLogin() } }
                    TextButton(title: "[ annulla ]") { store.cancelClaudeLogin() }
                }
            } else {
                TextButton(title: "[ accedi a claude… ]") { store.startClaudeLogin() }
            }
        }
        .padding(.horizontal, Terminal.padding)
        .padding(.bottom, 8)
    }
}

// MARK: - Menu

/// "↻ aggiorna ora                          ⌘R": a menu item, highlighted under the pointer.
private struct MenuLine: View {
    let title: String
    let shortcut: String?
    let action: () -> Void

    var body: some View {
        HoverRow(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(Terminal.dim) }
            }
            .padding(.vertical, 4)
        }
    }
}

/// A bracketed text button, as a terminal program would show one.
private struct TextButton: View {
    let title: String
    let action: () -> Void
    // @State is a macro in the current SDK and needs Xcode's plugins; a StateObject builds with the CLT alone.
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Terminal.font(weight: .semibold))
                .foregroundStyle(hover.isOn ? Terminal.background.swiftUI : Terminal.foreground)
                .background(hover.isOn ? Terminal.foreground : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
    }
}

/// A row that highlights on hover, like a selection in a terminal, and runs `action` when clicked.
/// With `inset`, the highlight reaches a little past the text, which keeps its place on the grid.
private struct HoverRow<Content: View>: View {
    var inset = true
    let action: () -> Void
    @ViewBuilder let content: Content
    // @State is a macro in the current SDK and needs Xcode's plugins; a StateObject builds with the CLT alone.
    @StateObject private var hover = HoverState()
    private let highlight = RoundedRectangle(cornerRadius: 4, style: .continuous)

    private static var margin: CGFloat { 6 }

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, inset ? Self.margin : 0)
                .background(highlight.fill(hover.isOn ? Terminal.foreground.opacity(0.08) : .clear))
                .contentShape(highlight)
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
        .padding(.horizontal, inset ? Terminal.padding - Self.margin : 0)
    }
}

private final class HoverState: ObservableObject {
    /// LIMITBAR_RENDER_HOVER=1 shows every row highlighted, to check the layout with --render.
    @Published var isOn = ProcessInfo.processInfo.environment["LIMITBAR_RENDER_HOVER"] != nil
}

private extension NSColor {
    var swiftUI: Color { Color(nsColor: self) }
}
