import SwiftUI

/// The panel, laid out like a terminal program: lines of monospaced text on one grid (see
/// Terminal: a label, a bar, a percentage and values against the right edge), each group of lines
/// under its column headers, two tones of text, and colour for each service and for limits
/// running out. Interface words are lower case; names and acronyms keep theirs (Claude, Pro, API).
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
                        .padding(.vertical, Spacing.section)
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
            .font(Terminal.font())
            .foregroundStyle(Terminal.foreground)
        }
        .frame(width: Terminal.width)
    }

    private func header(_ now: Date) -> some View {
        HStack {
            Text("LimitBar").font(Terminal.font(weight: .bold))
            Spacer()
            Text(Format.stamp(now)).foregroundStyle(Terminal.dim)
        }
        .padding(.horizontal, Terminal.padding)
        .padding(.top, Spacing.edge)
        .padding(.bottom, Spacing.section)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            MenuLine(title: store.isRefreshing ? "⋯ aggiornamento in corso" : "↻ aggiorna ora", shortcut: "⌘R") {
                Task { await store.refresh(force: true) }
            }
            .keyboardShortcut("r", modifiers: .command)

            MenuLine(title: "⚙ impostazioni…", shortcut: "⌘,") { SettingsWindow.shared.show() }
                .keyboardShortcut(",", modifiers: .command)

            if store.claudeSignedInHere {
                MenuLine(title: "⏏ disconnetti Claude", shortcut: nil) { store.signOutOfClaude() }
            }

            MenuLine(title: "⏻ esci da LimitBar", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        // The rows' own padding (4) makes up the rest of the room above and below.
        .padding(.top, Spacing.section - 4)
        .padding(.bottom, Spacing.edge - 4)
    }
}

/// The vertical rhythm: every section has the same room above and below its lines, and the
/// groups of lines inside it the same room between them.
private enum Spacing {
    static let section: CGFloat = 10
    /// At the panel's top and bottom edges: what a section gets from a rule, whose line sits in
    /// the middle of a line's height, so the first and last lines sit as far from the edge.
    static let edge: CGFloat = section + Terminal.lineHeight / 2
    static let group: CGFloat = 8
    static let line: CGFloat = 3
}

// MARK: - Building blocks

/// A line across the panel, in the middle of a line of text's height, so the sections above
/// and below it get the same room.
private struct Rule: View {
    var body: some View {
        Rectangle()
            .fill(Terminal.dim.opacity(0.45))
            .frame(height: 1)
            .frame(height: Terminal.lineHeight)
            .padding(.horizontal, Terminal.padding)
    }
}

/// "Claude Pro                          ● al lavoro": a service's name in its colour and what it
/// runs on (plan or model), then whether it's working or when it was last read.
private struct TitleLine: View {
    let name: String
    let tint: Color
    let detail: String?
    let snapshot: ProviderSnapshot?
    let workingSessions: Int
    let now: Date

    var body: some View {
        HStack(spacing: 0) {
            Text(name).font(Terminal.font(weight: .bold)).foregroundStyle(tint)
            if let detail { Text(" " + detail).foregroundStyle(Terminal.dim) }
            Spacer(minLength: Terminal.cell)
            if workingSessions > 0 {
                Text(workingSessions == 1 ? "● al lavoro" : "● \(workingSessions) al lavoro")
                    .font(Terminal.font(weight: .semibold))
                    .foregroundStyle(tint)
            } else if let snapshot {
                Text("↻ " + Format.ago(snapshot.updatedAt, now: now))
                    .foregroundStyle(Terminal.dim)
                    .help(snapshot.source == "statusline" ? "Letto dalla status line di Claude Code" : "")
            }
        }
        .lineLimit(1)
    }
}

/// The column headers over a group of lines: `title` over the labels (and bars), `middle` over
/// the percentages, `right` over the values on the right. With `bar`, the label and bar columns
/// get a header each.
private struct ColumnHeader: View {
    var title: String = ""
    var bold = false
    var bar: String = ""
    var middle: String = ""
    let right: String

    var body: some View {
        HStack(spacing: 0) {
            if bar.isEmpty {
                Text(Terminal.fit(title, Terminal.nameColumns))
                    .font(Terminal.font(weight: bold ? .bold : .regular))
                    .foregroundStyle(bold ? Terminal.foreground : Terminal.dim)
                    .fixedSize()
            } else {
                Text(Terminal.fit(title, Terminal.labelColumns)).fixedSize()
                Text(Terminal.fit(bar, Terminal.barColumns)).fixedSize()
            }
            Text(middle).frame(width: Terminal.cols(Terminal.percentColumns), alignment: .trailing)
            Text(right).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .foregroundStyle(Terminal.dim)
        .lineLimit(1)
    }
}

/// "5 ore     ━━━━━━━━╾────  76%    tra 38 min": a limit on the grid, its bar in the service's
/// colour until it runs low.
private struct LimitLine: View {
    let label: String
    let percent: Double
    let note: String
    let tint: Color

    var body: some View {
        let bar = Terminal.bar(percent, width: Terminal.barColumns)
        HStack(spacing: 0) {
            Text(Terminal.fit(label, Terminal.labelColumns)).foregroundStyle(Terminal.dim).fixedSize()
            Text(bar.filled).foregroundStyle(Terminal.level(percent, normal: tint)).fixedSize()
            Text(bar.empty).foregroundStyle(Terminal.dim.opacity(0.5)).fixedSize()
            Text("\(Int(percent.rounded()))%")
                .font(Terminal.font(weight: .semibold))
                .foregroundStyle(Terminal.level(percent))
                .frame(width: Terminal.cols(Terminal.percentColumns), alignment: .trailing)
            Text(note)
                .foregroundStyle(Terminal.dim)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .lineLimit(1)
    }
}

/// "✕ 5 ore esaurite · si azzerano alle 13:43" on one line when it fits; otherwise the second
/// half goes on a line of its own, under the first past the mark, rather than breaking anywhere.
private struct AlertLine: View {
    let first: String
    let second: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text("✕ \(first) · \(second)")
            VStack(alignment: .leading, spacing: Spacing.line) {
                Text("✕ \(first)")
                Text(second).padding(.leading, Terminal.cols(2))
            }
        }
        .foregroundStyle(Terminal.red)
        .lineLimit(1)
    }
}

/// A line that may wrap, its text kept clear of the mark: "! …", "· …".
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

/// How a window is named in the panel's sentences.
private struct Period {
    let label: String
    /// "5 ore esaurite", "settimana esaurita", "mese esaurito".
    let exhausted: String
    /// The verbs follow "5 ore", which is plural.
    let plural: Bool

    var resets: String { plural ? "si azzerano" : "si azzera" }

    static let fiveHours = Period(label: "5 ore", exhausted: "5 ore esaurite", plural: true)
    static let week = Period(label: "settimana", exhausted: "settimana esaurita", plural: false)
    static let month = Period(label: "mese", exhausted: "mese esaurito", plural: false)

    /// The week slot holds a monthly window on some plans (Codex Free).
    static func of(_ kind: WindowKind, _ window: UsageWindow) -> Period {
        kind == .fiveHour ? .fiveHours : kind.limitName(window) == "mensile" ? .month : .week
    }

    /// An extra limit Anthropic adds: a model's own week ("Settimana Opus", shown as "Opus"
    /// under the week), or the extra usage paid on top of the plan.
    static func extra(_ label: String) -> Period {
        let modelWeek = "Settimana "
        if label.hasPrefix(modelWeek) {
            let model = String(label.dropFirst(modelWeek.count))
            return Period(label: model, exhausted: "settimana \(model) esaurita", plural: false)
        }
        if label == "Uso extra" { return Period(label: "uso extra", exhausted: "uso extra esaurito", plural: false) }
        return Period(label: label.lowercased(), exhausted: "limite \(label) esaurito", plural: false)
    }
}

private extension String {
    /// "Si azzera …" from "si azzera …", for a tooltip that starts with it.
    var sentence: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Services

/// Claude (and Codex, if it's switched back on): an alert when a limit is used up, the limits
/// with the time until they reset, the forecast as one more line of the table, and the last
/// hours as a sparkline.
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

    /// The limits in the order shown: 5 hours, week (or month), then any extra ones.
    private var limits: [(period: Period, window: UsageWindow?)] {
        guard let snapshot else { return [] }
        let week = snapshot.week.map { Period.of(.week, $0) } ?? .week
        return [(.fiveHours, snapshot.fiveHour), (week, snapshot.week)]
            + snapshot.extras.map { (Period.extra($0.label), $0.window) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TitleLine(name: provider.title, tint: provider.tint, detail: snapshot?.plan ?? provider.toolName,
                      snapshot: snapshot, workingSessions: workingSessions, now: now)
            if let snapshot {
                if let full = limits.first(where: { ($0.window?.effectivePercent(at: now) ?? 0) >= UsageWindow.exhausted }),
                   let reset = full.window?.resetsAt {
                    AlertLine(first: full.period.exhausted, second: "\(full.period.resets) \(Format.at(reset, now: now))")
                        .padding(.top, Spacing.group)
                }
                VStack(alignment: .leading, spacing: Spacing.line) {
                    ColumnHeader(right: "si azzera")
                    ForEach(limits, id: \.period.label) { limit in line(limit.period, limit.window) }
                    if let forecast {
                        let period = Period.of(forecast.kind, forecast.window)
                        // On the grid like the limits above: what runs out from the bars' column,
                        // when in the right-hand one, under the reset times.
                        let what = HStack(spacing: 0) {
                            Text(Terminal.fit("previsto", Terminal.labelColumns)).foregroundStyle(Terminal.dim).fixedSize()
                            Text(period.exhausted).fixedSize()
                        }
                        let when = Text(Format.at(forecast.date, now: now)).fixedSize()
                        // The longest pair ("settimana esaurita", "domani alle 08:09") leaves a
                        // column free between them; a date further off may not fit, and goes under.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 0) { what; Spacer(minLength: 0); when }
                            VStack(alignment: .trailing, spacing: Spacing.line) {
                                what.frame(maxWidth: .infinity, alignment: .leading)
                                when
                            }
                        }
                        .lineLimit(1)
                        .help("Al ritmo delle ultime ore, prima che il limite si azzeri")
                    }
                }
                .padding(.top, Spacing.group)
                if showHistory, let spark = Sparkline(samples: samples, snapshot: snapshot, now: now, tint: provider.tint) {
                    spark.padding(.top, Spacing.group)
                }
            } else if state.error == nil {
                Text("in attesa di dati…").foregroundStyle(Terminal.dim).padding(.top, Spacing.group)
            }
            notes
        }
    }

    @ViewBuilder
    private var notes: some View {
        if let note = snapshot?.note { NoteLine(mark: "·", text: note).padding(.top, Spacing.group) }
        if let error = state.error {
            NoteLine(mark: "!", text: error, color: Terminal.red).padding(.top, Spacing.group)
        } else if let notice = state.notice {
            NoteLine(mark: "·", text: notice).padding(.top, Spacing.group)
        }
    }

    @ViewBuilder
    private func line(_ period: Period, _ window: UsageWindow?) -> some View {
        if let window {
            LimitLine(label: period.label, percent: window.effectivePercent(at: now),
                      note: Format.countdown(window.resetsAt, now: now) ?? "", tint: provider.tint)
                .help(window.resetsAt.map { "\(period.resets.sentence) \(Format.at($0, now: now))" } ?? "")
        } else {
            HStack(spacing: 0) {
                Text(Terminal.fit(period.label, Terminal.labelColumns)).fixedSize()
                Text("nessun limite")
            }
            .foregroundStyle(Terminal.dim)
        }
    }
}

/// "▁▁▂▃▃▅▅▅▅▆▇▁▂▃▃▃": the main window over the last day across the whole line, one cell per
/// slice of time in eighths of the line's height, like block characters; nil until there's half
/// an hour of readings that actually move.
private struct Sparkline: View {
    let values: [Double]
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
        let width = Terminal.columns
        let slice = now.timeIntervalSince(first.0) / Double(width)
        values = (1...width).map { index in
            let end = first.0.addingTimeInterval(slice * Double(index))
            return points.last { $0.0 <= end }?.1 ?? first.1
        }
    }

    var body: some View {
        // Drawn as one shape rather than as characters, whose glyphs leave hairlines between them.
        // The bars stand on the baseline and reach the ascender, as text on the line would.
        Canvas { context, _ in
            var bars = Path()
            for (index, value) in values.enumerated() {
                let eighths = CGFloat(min(Int(min(max(value, 0), 100) / 100 * 7.999), 7) + 1)
                let height = Terminal.ascender * eighths / 8
                bars.addRect(CGRect(x: Terminal.cols(index), y: Terminal.ascender - height, width: Terminal.cell, height: height))
            }
            context.fill(bars, with: .color(tint))
        }
        .frame(width: Terminal.cols(values.count), height: Terminal.lineHeight)
        .help("Uso nelle ultime 24 ore, da sinistra a destra fino ad adesso")
    }
}

/// OpenCode Go: the model in use, an alert when a limit is used up, the limits all models share
/// with the dollars left of them in that model, and who used the 5 hours.
private struct OpenCodeBlock: View {
    let state: ProviderState
    let now: Date
    let workingSessions: Int

    private let tint = ProviderID.opencode.tint
    private var snapshot: ProviderSnapshot? { state.snapshot }
    private var models: [ModelUsage] { snapshot?.models ?? [] }

    var body: some View {
        let current = models.first(where: \.inUse)
        VStack(alignment: .leading, spacing: 0) {
            TitleLine(name: "OpenCode", tint: tint, detail: current?.name ?? snapshot?.plan, snapshot: snapshot,
                      workingSessions: workingSessions, now: now)
            if let snapshot {
                let paid = current?.isFree == true ? nil : current
                let limits: [(period: Period, window: UsageWindow?, cap: Double?)] = [
                    (.fiveHours, snapshot.fiveHour, paid?.fiveHour.cap),
                    (.week, snapshot.week, paid?.week.cap),
                    (.month, snapshot.month, paid?.month.cap),
                ]
                if let full = limits.first(where: { ($0.window?.effectivePercent(at: now) ?? 0) >= UsageWindow.exhausted }),
                   let reset = full.window?.resetsAt {
                    AlertLine(first: full.period.exhausted, second: "\(full.period.resets) \(Format.at(reset, now: now))")
                        .padding(.top, Spacing.group)
                }
                if current?.isFree == true {
                    NoteLine(mark: "·", text: "modello gratuito: non consuma i limiti").padding(.top, Spacing.group)
                }
                VStack(alignment: .leading, spacing: Spacing.line) {
                    ColumnHeader(right: paid == nil ? "si azzera" : "rimasti")
                    ForEach(limits, id: \.period.label) { limit in
                        if let window = limit.window { sharedLine(limit.period, window, cap: limit.cap, model: paid?.name) }
                    }
                }
                .padding(.top, Spacing.group)
                let users = models.filter { $0.fiveHour.share >= 0.5 }.sorted { $0.fiveHour.share > $1.fiveHour.share }
                if !users.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.line) {
                        ColumnHeader(title: "chi ha usato le 5 ore", right: "spesi")
                        ForEach(users.prefix(4)) { model in ShareLine(model: model) }
                    }
                    .padding(.top, Spacing.group)
                }
                if models.isEmpty {
                    Text("nessuna richiesta con Go negli ultimi 30 giorni")
                        .foregroundStyle(Terminal.dim)
                        .padding(.top, Spacing.group)
                }
            } else if state.error == nil {
                Text("in attesa di dati…").foregroundStyle(Terminal.dim).padding(.top, Spacing.group)
            }
            if let error = state.error {
                NoteLine(mark: "!", text: error, color: Terminal.red).padding(.top, Spacing.group)
            } else if let notice = state.notice {
                NoteLine(mark: "·", text: notice).padding(.top, Spacing.group)
            }
        }
        // What the numbers are, and each model's month, for whoever wonders.
        .help((["Stima dall'uso su questo Mac: i limiti sono condivisi da tutti i modelli."]
               + models.filter { $0.month.share > 0 || $0.requests > 0 }.map {
                   "\($0.name): \($0.requests == 1 ? "1 richiesta" : "\($0.requests) richieste"), \(Format.dollars($0.spent)), "
                       + "\(Int($0.month.share.rounded()))% del mese"
               }).joined(separator: "\n"))
    }

    /// A shared limit with what's left of it in dollars of the model in use, or, with no paid
    /// model in use, the time until it resets.
    private func sharedLine(_ period: Period, _ window: UsageWindow, cap: Double?, model: String?) -> some View {
        let value = window.effectivePercent(at: now)
        let left = cap.map { $0 * max(0, 100 - value) / 100 }
        let note = left.map(Format.dollars) ?? Format.countdown(window.resetsAt, now: now) ?? ""
        var tooltip: [String] = []
        if let left, let model { tooltip.append("Con \(model) restano \(Format.dollars(left))") }
        if let resetsAt = window.resetsAt, resetsAt > now { tooltip.append(period.resets + " " + Format.at(resetsAt, now: now)) }
        return LimitLine(label: period.label, percent: value, note: note, tint: tint)
            .help(tooltip.joined(separator: " · ").sentence)
    }
}

/// "Kimi K3.1 Pro           100%          3,00 $": a model's part of the shared 5 hours and what
/// it spent in them, under the percentage and right-hand columns.
private struct ShareLine: View {
    let model: ModelUsage

    var body: some View {
        let share = model.fiveHour.share
        HStack(spacing: 0) {
            Text(Terminal.fit(model.name, Terminal.nameColumns)).fixedSize()
            Text("\(Int(share.rounded()))%")
                .font(Terminal.font(weight: .semibold))
                .foregroundStyle(Terminal.level(share))
                .frame(width: Terminal.cols(Terminal.percentColumns), alignment: .trailing)
            Text(Format.dollars(model.fiveHour.used))
                .foregroundStyle(Terminal.dim)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .lineLimit(1)
    }
}

// MARK: - Value at API prices

/// This month's work at API prices: per service its plan, how many times the plan's price the
/// work was worth, and its value; the saving; then the projects with their share of the month.
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
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("valore di \(Format.month(now))").font(Terminal.font(weight: .bold))
                    Spacer()
                    Text(comparison.map(Format.change) ?? "stima a prezzi API").foregroundStyle(Terminal.dim)
                }
                .help(comparison.map(Format.comparisonNote) ?? "Quanto costerebbe lo stesso lavoro pagandolo a prezzi API")
                VStack(alignment: .leading, spacing: Spacing.line) {
                    ColumnHeader(bar: "piano", middle: "resa", right: "valore")
                    ForEach(values, id: \.0) { id, value in serviceLine(id, value) }
                    if saved > 0 {
                        HStack(spacing: 0) {
                            Text(Terminal.fit("risparmio", Terminal.labelColumns)).fixedSize()
                            Text(Terminal.fit("rispetto alle API", Terminal.barColumns + Terminal.percentColumns))
                                .foregroundStyle(Terminal.dim)
                                .fixedSize()
                            Text(Format.wholeEuros(fromDollars: saved))
                                .font(Terminal.font(weight: .bold))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .lineLimit(1)
                        .help("Il valore del lavoro meno quello che costano gli abbonamenti")
                    }
                }
                .padding(.top, Spacing.group)
                if !projects.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.line) {
                        ColumnHeader(title: "progetti", bold: true, middle: "quota", right: "valore")
                        ForEach(projects) { project in projectLine(project, monthTotal: total) }
                    }
                    .padding(.top, Spacing.group)
                }
            }
            .padding(.horizontal, Terminal.padding)
            .padding(.vertical, Spacing.section)
            Rule()
        }
    }

    /// "Claude    Pro           ×15,3           274 €": the multiple in the service's colour.
    private func serviceLine(_ id: ProviderID, _ value: ServiceValue) -> some View {
        HStack(spacing: 0) {
            Text(Terminal.fit(id.title, Terminal.labelColumns)).fixedSize()
            Text(Terminal.fit(store.state(id).snapshot?.plan ?? "", Terminal.barColumns))
                .foregroundStyle(Terminal.dim)
                .fixedSize()
            Text(value.multiple.map(Format.multiple) ?? "–")
                .font(Terminal.font(weight: .semibold))
                .foregroundStyle(value.multiple == nil ? Terminal.dim : id.tint)
                .frame(width: Terminal.cols(Terminal.percentColumns), alignment: .trailing)
            Text(Format.wholeEuros(fromDollars: value.cost))
                .font(Terminal.font(weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .lineLimit(1)
        .help(priceNote(id, value))
    }

    /// A project, its share of the month and its value. A click opens its folder in the Finder
    /// (marked "▸"); Altro and folders that are gone don't open.
    @ViewBuilder
    private func projectLine(_ project: ProjectValue, monthTotal: Double) -> some View {
        let share = monthTotal > 0 ? min(project.total / monthTotal, 1) * 100 : 0
        let name = project.name == ProjectFolder.other ? "altro" : project.name
        let content = HStack(spacing: 0) {
            Text(Terminal.fit((project.folder == nil ? "  " : "▸ ") + name, Terminal.nameColumns)).fixedSize()
            Text("\(Int(share.rounded()))%")
                .foregroundStyle(Terminal.dim)
                .frame(width: Terminal.cols(Terminal.percentColumns), alignment: .trailing)
            Text(Format.wholeEuros(fromDollars: project.total))
                .font(Terminal.font(weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .lineLimit(1)
        if let folder = project.folder {
            HoverRow(nested: true, action: { NSWorkspace.shared.open(URL(fileURLWithPath: folder, isDirectory: true)) }) {
                content
            }
            .help(projectNote(project, share: share) + "\nClic per aprirlo nel Finder")
        } else {
            content.help(projectNote(project, share: share))
        }
    }

    /// Tooltip: "LimitBar: Claude 80,12 € · 52% del mese", and for Altro what's in it.
    private func projectNote(_ project: ProjectValue, share: Double) -> String {
        let services = providers.compactMap { id in project.costs[id].map { "\(id.title) \(Format.euros(fromDollars: $0))" } }
        let name = project.name == ProjectFolder.other ? "Altro" : project.name
        let note = "\(name): \(services.joined(separator: ", ")) · \(Int(share.rounded()))% del mese"
        guard project.name == ProjectFolder.other else { return note }
        let folded = project.folded.isEmpty ? "" : ", e \(project.folded.joined(separator: ", "))"
        return note + "\nChat senza cartella, cartelle con più progetti\(folded)"
    }

    /// Tooltip: what the plan costs, the exchange rate, and what the value is compared with.
    private func priceNote(_ id: ProviderID, _ value: ServiceValue) -> String {
        let plan = store.state(id).snapshot?.plan ?? id.title
        let rate = "cambio BCE del \(Format.rateDate(ExchangeRate.shared.rateDate))"
        guard let subscription = value.subscription else { return "Prezzo del piano \(plan) non noto" }
        if subscription == 0 { return "\(plan): gratis" }
        let times = value.multiple.map { ", quindi il lavoro vale \(Format.multiple($0)) il prezzo del piano" } ?? ""
        return "\(plan): \(Int(subscription)) $ al mese, circa \(Format.euros(fromDollars: subscription)) al \(rate)"
            + "\(times) (prezzi senza IVA, come quelli delle API)"
    }
}

// MARK: - Claude sign-in

private struct ClaudeSignIn: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.line) {
            if store.claudeLoginPending {
                Text("approva nel browser, copia il codice che compare, poi:")
                    .foregroundStyle(Terminal.dim)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Terminal.cell * 2) {
                    TextButton(title: "[ incolla codice ]") { Task { await store.finishClaudeLogin() } }
                    TextButton(title: "[ annulla ]") { store.cancelClaudeLogin() }
                }
            } else {
                TextButton(title: "[ accedi a Claude… ]") { store.startClaudeLogin() }
            }
        }
        .padding(.horizontal, Terminal.padding)
        .padding(.bottom, Spacing.section)
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

/// A bracketed text button, as a terminal program would show one; inverted under the pointer.
private struct TextButton: View {
    let title: String
    let action: () -> Void
    // @State is a macro in the current SDK and needs Xcode's plugins; a StateObject builds with the CLT alone.
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Terminal.font(weight: .semibold))
                .foregroundStyle(hover.isOn ? Color(nsColor: Terminal.background) : Terminal.foreground)
                .background(hover.isOn ? Terminal.foreground : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
    }
}

/// A row that highlights on hover, like a selection in a terminal, and runs `action` when clicked.
/// The highlight reaches a little past the text, which keeps its place on the grid: a row across
/// the panel sits in the panel's padding, a `nested` one in a block that has the padding already.
private struct HoverRow<Content: View>: View {
    var nested = false
    let action: () -> Void
    @ViewBuilder let content: Content
    // @State is a macro in the current SDK and needs Xcode's plugins; a StateObject builds with the CLT alone.
    @StateObject private var hover = HoverState()
    private let highlight = RoundedRectangle(cornerRadius: 4, style: .continuous)

    private static var margin: CGFloat { 6 }

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, Self.margin)
                .background(highlight.fill(hover.isOn ? Terminal.foreground.opacity(0.08) : .clear))
                .contentShape(highlight)
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
        .padding(.horizontal, nested ? -Self.margin : Terminal.padding - Self.margin)
    }
}

private final class HoverState: ObservableObject {
    /// LIMITBAR_RENDER_HOVER=1 shows every row highlighted, to check the layout with --render.
    @Published var isOn = ProcessInfo.processInfo.environment["LIMITBAR_RENDER_HOVER"] != nil
}
