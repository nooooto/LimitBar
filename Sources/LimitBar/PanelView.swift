import SwiftUI

private enum Layout {
    static let padding: CGFloat = 14
    static let spacing: CGFloat = 14
    static let nameColumn: CGFloat = 116
    static let column: CGFloat = 92
    static let logoSize: CGFloat = 18
    static let logoInset = logoSize + 6
    /// Highlighted rows sit this far in from the panel's edge (concentric 12 pt corners)...
    static let rowInset: CGFloat = 6
    /// ...and this far from the separators around them, as in the system menus.
    static let rowGap: CGFloat = 3
    /// Padding inside a highlighted service row, the same on every side.
    static let rowPadding: CGFloat = 8
    static let width = padding * 2 + nameColumn + column * 2 + spacing * 2
}

struct PanelView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 0) {
                header
                ForEach(settings.visibleProviders) { id in
                    // A click opens the service's own usage page, like a menu item.
                    HoverRow(highlightOpacity: 0.06, action: { id.openUsagePage() }) {
                        if id == .opencode {
                            // Its limits are per model, so it gets a layout built around the models.
                            OpenCodeSection(state: store.state(id), now: context.date,
                                            workingSessions: store.activity.sessions(id))
                        } else if id == .claude {
                            ClaudeSection(state: store.state(id), now: context.date, samples: store.history[id] ?? [],
                                          showHistory: settings.showHistory, workingSessions: store.activity.sessions(id))
                        } else {
                            ProviderRow(provider: id, state: store.state(id), now: context.date,
                                        samples: store.history[id] ?? [], showHistory: settings.showHistory,
                                        workingSessions: store.activity.sessions(id))
                        }
                    }
                    .help(id.usageDestination)
                    .padding(.horizontal, Layout.rowInset)
                    .padding(.vertical, Layout.rowGap)
                    if id == .claude, store.state(.claude).needsSignIn || store.claudeLoginPending {
                        ClaudeSignIn(store: store)
                    }
                    Divider().padding(.horizontal, Layout.padding)
                }
                if settings.showValue {
                    // Only the services whose work can be priced from logs on this Mac.
                    ValueSection(store: store, providers: settings.visibleProviders.filter(\.isInCostLedger), now: context.date)
                }
                footer.padding(.top, 4)
            }
            .padding(.vertical, 8)
        }
        .frame(width: Layout.width)
    }

    private var header: some View {
        HStack(spacing: Layout.spacing) {
            Text("LimitBar")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: Layout.nameColumn, alignment: .leading)
            Text("5 ore").frame(width: Layout.column, alignment: .leading)
            Text("Settimana").frame(width: Layout.column, alignment: .leading)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Layout.padding)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            MenuRow(title: "Aggiorna ora", icon: "arrow.clockwise", busy: store.isRefreshing) {
                Task { await store.refresh(force: true) }
            } trailing: {
                Shortcut("⌘R")
            }
            .keyboardShortcut("r", modifiers: .command)

            MenuRow(title: "Impostazioni…", icon: "gearshape", action: { SettingsWindow.shared.show() }) {
                Shortcut("⌘,")
            }
            .keyboardShortcut(",", modifiers: .command)

            if store.claudeSignedInHere {
                MenuRow(title: "Disconnetti Claude", icon: "person.crop.circle.badge.xmark",
                        action: { store.signOutOfClaude() }) { EmptyView() }
            }

            MenuRow(title: "Esci da LimitBar", icon: "power", action: { NSApp.terminate(nil) }) {
                Shortcut("⌘Q")
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 6)
    }
}

private struct ProviderRow: View {
    let provider: ProviderID
    let state: ProviderState
    let now: Date
    let samples: [UsageSample]
    let showHistory: Bool
    /// Sessions of this service working right now (Claude Code sessions, Codex turns).
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

    /// The chart follows the window the menu bar would care about: 5 hours if there is one.
    private var chartKind: WindowKind { snapshot?.fiveHour != nil ? .fiveHour : .week }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: Layout.spacing) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(nsImage: provider.logo)
                            .resizable()
                            .frame(width: Layout.logoSize, height: Layout.logoSize)
                        Text(provider.title).font(.system(size: 13, weight: .semibold))
                    }
                    Text(snapshot?.plan ?? provider.toolName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.leading, Layout.logoInset)
                    Group {
                        if let snapshot {
                            // The icon stands in for "aggiornato", which didn't fit the column;
                            // a terminal means the numbers came from Claude Code's status line.
                            HStack(spacing: 3) {
                                Image(systemName: snapshot.source == "statusline" ? "terminal" : "arrow.clockwise")
                                    .font(.system(size: 8, weight: .semibold))
                                Text(Format.ago(snapshot.updatedAt, now: now))
                            }
                        } else {
                            Text("in attesa di dati")
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, Layout.logoInset)

                    if workingSessions > 0 {
                        HStack(spacing: 4) {
                            Circle().fill(provider.tint).frame(width: 6, height: 6)
                            Text(workingSessions == 1 ? "al lavoro" : "\(workingSessions) al lavoro")
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(provider.tint)
                        .padding(.leading, Layout.logoInset)
                    }
                }
                .lineLimit(1)
                .frame(width: Layout.nameColumn, alignment: .leading)

                UsageCell(window: snapshot?.fiveHour, columnMinutes: 5 * 60, tint: provider.tint, now: now,
                          placeholder: snapshot == nil ? "…" : "senza limite 5 ore")
                UsageCell(window: snapshot?.week, columnMinutes: 7 * 24 * 60, tint: provider.tint, now: now,
                          placeholder: snapshot == nil ? "…" : "senza limite sett.")
            }

            ForEach(snapshot?.extras ?? []) { extra in
                HStack(spacing: Layout.spacing) {
                    Text(extra.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.leading, Layout.logoInset)
                        .frame(width: Layout.nameColumn, alignment: .leading)
                    Color.clear.frame(width: Layout.column, height: 1)
                    CompactCell(window: extra.window, tint: provider.tint, now: now)
                }
            }

            if let forecast {
                Label("A questo ritmo finisci il limite \(forecast.kind.limitName(forecast.window)) "
                      + Format.at(forecast.date, now: now),
                      systemImage: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 10.5))
                    .foregroundStyle(provider.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showHistory, let snapshot {
                HistoryChart(samples: samples, kind: chartKind,
                             current: chartKind.window(in: snapshot)?.effectivePercent(at: now),
                             tint: provider.tint, now: now,
                             runsOut: forecast?.kind == chartKind ? forecast?.date : nil)
                    .padding(.leading, Layout.logoInset)
            }

            if let note = snapshot?.note {
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            if let notice = state.notice {
                Label(notice, systemImage: "clock")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            }
        }
        .padding(Layout.rowPadding)
    }
}

/// This month's work at API prices next to each plan: what the official usage pages don't show.
private struct ValueSection: View {
    @ObservedObject var store: UsageStore
    let providers: [ProviderID]
    let now: Date

    var body: some View {
        let values = providers.map { ($0, store.monthValue($0, now: now)) }
        let total = values.reduce(0) { $0 + $1.1.cost }
        let subscriptions = values.compactMap(\.1.subscription)
        // Only a saving if every plan's price is known.
        let saved = subscriptions.count == values.count ? total - subscriptions.reduce(0, +) : 0
        let projects = store.monthProjects(providers, shown: Self.projectsShown, now: now)
        let comparison = store.monthComparison(providers, now: now)
        if total > 0 {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    if let comparison {
                        header("Valore di \(Format.month(now))", note: Format.change(comparison))
                            .help(Format.comparisonNote(comparison))
                    } else {
                        header("Valore di \(Format.month(now))", note: "stima a prezzi API")
                    }
                    ForEach(values, id: \.0) { id, value in
                        row(id.title, amount: value.cost) {
                            Image(nsImage: id.logo).resizable()
                        } detail: {
                            planLine(id, value).help(priceNote(id, value))
                        }
                    }
                    if saved > 0 {
                        row("Risparmiato", amount: saved, amountColor: .green) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.green)
                        } detail: {
                            Text("rispetto alle API").foregroundStyle(.secondary)
                        }
                    }
                }

                if !projects.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        header("Progetti", note: "quota del mese")
                        ForEach(projects) { project in
                            projectRow(project, monthTotal: total)
                        }
                    }
                }
            }
            .padding(.horizontal, Layout.padding)
            .padding(.vertical, 10)
            Divider().padding(.horizontal, Layout.padding)
        }
    }

    private static let projectsShown = 3

    private static let iconSize: CGFloat = 14

    private func header(_ title: String, note: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(note)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    /// Every row of the section on the panel's grid: icon and name in the name column, a detail
    /// in the next one, and the amount in whole euros against the right edge, so they line up.
    private func row<Icon: View, Detail: View>(_ name: String, amount: Double, amountColor: Color = .primary,
                                               @ViewBuilder icon: () -> Icon,
                                               @ViewBuilder detail: () -> Detail) -> some View {
        HStack(spacing: Layout.spacing) {
            HStack(spacing: 6) {
                icon().frame(width: Self.iconSize, height: Self.iconSize)
                Text(name)
                    .font(.system(size: 12))
                    .truncationMode(.middle)
            }
            .frame(width: Layout.nameColumn, alignment: .leading)

            detail()
                .font(.system(size: 10.5))
                .monospacedDigit()
                .frame(width: Layout.column, alignment: .leading)

            Text(Format.wholeEuros(fromDollars: amount))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(amountColor)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .lineLimit(1)
    }

    /// A project, its value this month, and its share of the month split by service. A click
    /// opens its folder in the Finder, like a menu item; Altro and folders that are gone don't.
    @ViewBuilder
    private func projectRow(_ project: ProjectValue, monthTotal: Double) -> some View {
        let parts = providers.compactMap { id in project.costs[id].map { (id, $0) } }
        let share = monthTotal > 0 ? min(project.total / monthTotal, 1) : 0
        let note = projectNote(project, parts: parts, share: share)
        let content = row(project.name, amount: project.total) {
            Image(systemName: project.name == ProjectFolder.other ? "ellipsis.circle.fill" : "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } detail: {
            ShareBar(parts: parts.map { ($0.0.tint, $0.1) }, share: share).frame(height: 4)
        }
        if let folder = project.folder {
            // The highlight reaches past the row as far as the menu rows' does, so the text stays in place.
            HoverRow(action: { NSWorkspace.shared.open(URL(fileURLWithPath: folder, isDirectory: true)) }) {
                content
                    .padding(.horizontal, Layout.rowPadding)
                    .padding(.vertical, Self.hoverPadding)
            }
            .padding(.horizontal, -Layout.rowPadding)
            .padding(.vertical, -Self.hoverPadding)
            .help(note + "\nClic per aprirlo nel Finder")
        } else {
            content.help(note)
        }
    }

    /// Vertical room in a project row's highlight, taken back outside so the rows keep their spacing.
    private static let hoverPadding: CGFloat = 4

    /// Tooltip: "LimitBar: Claude 80,12 €, Codex 4,10 € · 52% del mese", and for Altro what's in it.
    private func projectNote(_ project: ProjectValue, parts: [(ProviderID, Double)], share: Double) -> String {
        let services = parts.map { "\($0.0.title) \(Format.euros(fromDollars: $0.1))" }.joined(separator: ", ")
        let note = "\(project.name): \(services) · \(Int((share * 100).rounded()))% del mese"
        guard project.name == ProjectFolder.other else { return note }
        let folded = project.folded.isEmpty ? "" : ", e \(project.folded.joined(separator: ", "))"
        return note + "\nChat senza cartella, cartelle con più progetti\(folded)"
    }

    /// "×8,0 il Pro": how many times its price the plan paid back. "piano Free" for free plans.
    private func planLine(_ id: ProviderID, _ value: ServiceValue) -> Text {
        let plan = store.state(id).snapshot?.plan ?? ""
        if let multiple = value.multiple {
            let times = Text(Format.multiple(multiple)).fontWeight(.semibold).foregroundColor(id.tint)
            return Text("\(times) il \(plan)").foregroundColor(.secondary)
        }
        return Text(plan.isEmpty ? "" : "piano \(plan)").foregroundColor(.secondary)
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

private struct ClaudeSignIn: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.claudeLoginPending {
                Text("Approva nel browser, copia il codice che compare, poi:")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Incolla codice") { Task { await store.finishClaudeLogin() } }
                        .buttonStyle(.borderedProminent)
                        .tint(ProviderID.claude.tint)
                    Button("Annulla") { store.cancelClaudeLogin() }
                }
                .controlSize(.small)
            } else {
                Button("Accedi a Claude…") { store.startClaudeLogin() }
                    .controlSize(.small)
            }
        }
        .padding(.leading, Layout.padding + Layout.logoInset)
        .padding(.trailing, Layout.padding)
        .padding(.bottom, 10)
    }
}

private struct UsageCell: View {
    let window: UsageWindow?
    /// The window length the column header promises ("5 ore" or "Settimana").
    let columnMinutes: Int
    let tint: Color
    let now: Date
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let window {
                let value = window.effectivePercent(at: now)
                let percent = Text("\(Int(value.rounded()))%").font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                let period = Format.period(window.windowMinutes, unlessEqualTo: columnMinutes).map { " · \($0)" } ?? ""
                Text("\(percent) usato\(Text(period).font(.system(size: 11, weight: .medium)))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                UsageBar(value: value, tint: tint)
                if let reset = Format.reset(window.resetsAt, now: now) {
                    Text(reset)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let countdown = Format.countdown(window.resetsAt, now: now) {
                    Text(countdown)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                Text(placeholder)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .lineLimit(1)
        .frame(width: Layout.column, alignment: .leading)
    }
}

/// Claude in the same language as OpenCode's section: a one-line header, then a card with each
/// limit (5 hours, week, any extra ones) as a full-width bar with the time left until it resets,
/// and inside it the forecast and the chart. (Codex, switched off for now, keeps ProviderRow.)
private struct ClaudeSection: View {
    let state: ProviderState
    let now: Date
    let samples: [UsageSample]
    let showHistory: Bool
    let workingSessions: Int

    private let provider = ProviderID.claude
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

    /// The chart follows the window the menu bar would care about: 5 hours if there is one.
    private var chartKind: WindowKind { snapshot?.fiveHour != nil ? .fiveHour : .week }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let snapshot {
                card(snapshot)
            } else if state.error == nil {
                Text("In attesa di dati…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let note = snapshot?.note {
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            } else if let notice = state.notice {
                Label(notice, systemImage: "clock")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Layout.rowPadding)
    }

    /// "[logo] Claude Pro … ● al lavoro", or when it was last read (a terminal: from Claude Code).
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(nsImage: provider.logo)
                .resizable()
                .frame(width: Layout.logoSize, height: Layout.logoSize)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(provider.title).font(.system(size: 13, weight: .semibold))
                Text(snapshot?.plan ?? provider.toolName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if workingSessions > 0 {
                HStack(spacing: 4) {
                    Circle().fill(provider.tint).frame(width: 6, height: 6)
                    Text(workingSessions == 1 ? "al lavoro" : "\(workingSessions) al lavoro")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(provider.tint)
            } else if let snapshot {
                HStack(spacing: 3) {
                    Image(systemName: snapshot.source == "statusline" ? "terminal" : "arrow.clockwise")
                        .font(.system(size: 8, weight: .semibold))
                    Text(Format.ago(snapshot.updatedAt, now: now))
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }

    private func card(_ snapshot: ProviderSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let window = snapshot.fiveHour {
                ResetLine(label: "5 ore", window: window, tint: provider.tint, now: now)
            }
            if let window = snapshot.week {
                ResetLine(label: WindowKind.week.limitName(window) == "mensile" ? "Mese" : "Settimana",
                          window: window, tint: provider.tint, now: now)
            }
            ForEach(snapshot.extras) { extra in
                ResetLine(label: extra.label, window: extra.window, tint: provider.tint, now: now)
            }
            if let forecast {
                Label("A questo ritmo finisci il limite \(forecast.kind.limitName(forecast.window)) "
                      + Format.at(forecast.date, now: now),
                      systemImage: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 10.5))
                    .foregroundStyle(provider.tint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            if showHistory {
                HistoryChart(samples: samples, kind: chartKind,
                             current: chartKind.window(in: snapshot)?.effectivePercent(at: now),
                             tint: provider.tint, now: now,
                             runsOut: forecast?.kind == chartKind ? forecast?.date : nil)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

/// "5 ore  [════════──────]  45%  tra 2 h 50 min": a limit as a full-width bar with the time left
/// until it resets; the exact time is in the tooltip. The percentage turns orange from 80% and
/// red from 90%, like the menu bar.
private struct ResetLine: View {
    let label: String
    let window: UsageWindow
    let tint: Color
    let now: Date

    var body: some View {
        let value = window.effectivePercent(at: now)
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            UsageBar(value: value, tint: tint)
            Text("\(Int(value.rounded()))%")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(value >= 90 ? Color.red : value >= 80 ? Color.orange : Color.primary)
                .frame(width: 34, alignment: .trailing)
            Text(Format.countdown(window.resetsAt, now: now) ?? (window.resetsAt == nil ? "" : "ora"))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
        }
        .monospacedDigit()
        .lineLimit(1)
        .help(window.resetsAt.map { "Si azzera " + Format.at($0, now: now) } ?? "")
    }
}

/// OpenCode Go: a header with the month's total, a card with the limits all models share and
/// the dollars left with the model picked in OpenCode, and how much of the last 5 hours each
/// model used.
private struct OpenCodeSection: View {
    let state: ProviderState
    let now: Date
    let workingSessions: Int

    private let provider = ProviderID.opencode
    private var snapshot: ProviderSnapshot? { state.snapshot }
    private var models: [ModelUsage] { snapshot?.models ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let snapshot {
                SharedLimitsCard(snapshot: snapshot, current: models.first(where: \.inUse), tint: provider.tint, now: now)
                // Who filled the 5 hours, since all models draw on the same limits.
                let users = models.filter { $0.fiveHour.share >= 0.5 }.sorted { $0.fiveHour.share > $1.fiveHour.share }
                if !users.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Chi ha consumato le ultime 5 ore")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(users.prefix(4)) { model in
                            ModelShareLine(model: model, tint: provider.tint)
                        }
                    }
                    .padding(.horizontal, 10)
                    .help(models.filter { $0.month.share > 0 || $0.requests > 0 }.map {
                        "\($0.name): \(requests($0.requests)), \(Format.dollars($0.spent)), \(Int($0.month.share.rounded()))% del mese"
                    }.joined(separator: "\n"))
                }
            }
            if snapshot != nil, models.isEmpty {
                Text("Nessuna richiesta con Go negli ultimi 30 giorni")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            } else if let notice = state.notice {
                Label(notice, systemImage: "clock")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            if snapshot != nil {
                Label("Stima dall'uso su questo Mac · limiti condivisi da tutti i modelli", systemImage: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Layout.rowPadding)
    }

    /// "[logo] OpenCode Go … ● al lavoro" over "30 giorni: 35 richieste · 0,12 $".
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(nsImage: provider.logo)
                .resizable()
                .frame(width: Layout.logoSize, height: Layout.logoSize)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(provider.title).font(.system(size: 13, weight: .semibold))
                    Text(snapshot?.plan ?? provider.toolName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if !models.isEmpty {
                    Text("30 giorni: \(requests(models.reduce(0) { $0 + $1.requests })) · \(Format.dollars(models.reduce(0) { $0 + $1.spent }))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            if workingSessions > 0 {
                HStack(spacing: 4) {
                    Circle().fill(provider.tint).frame(width: 6, height: 6)
                    Text(workingSessions == 1 ? "al lavoro" : "\(workingSessions) al lavoro")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(provider.tint)
            } else if let snapshot {
                Text(Format.ago(snapshot.updatedAt, now: now))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }

    private func requests(_ count: Int) -> String { count == 1 ? "1 richiesta" : "\(count) richieste" }

}

/// "Kimi K3.1 Pro  [██████████]  100%  3,00 $": a model's slice of the shared 5 hours, with the
/// dollars it spent in them.
private struct ModelShareLine: View {
    let model: ModelUsage
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(model.name)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
            UsageBar(value: min(model.fiveHour.share, 100), tint: tint)
                .frame(width: 70)
            Text("\(Int(model.fiveHour.share.rounded()))%")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 38, alignment: .trailing)
            Text(Format.dollars(model.fiveHour.used))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .monospacedDigit()
        .lineLimit(1)
    }
}

/// OpenCode Go's limits, shared by all models: 5 hours, week and month as full-width bars, with
/// the dollars left for the model in use (or the time until the window frees up). A full window
/// says when it can be used again.
private struct SharedLimitsCard: View {
    let snapshot: ProviderSnapshot
    /// The model picked in OpenCode, which sets how many dollars a share of the limits is worth.
    let current: ModelUsage?
    let tint: Color
    let now: Date

    var body: some View {
        let month = snapshot.extras.first { $0.label == "Mese" }?.window
        let limits: [(label: String, period: String, window: UsageWindow?, cap: Double?)] = [
            ("5 ore", "delle 5 ore", snapshot.fiveHour, current?.fiveHour.cap),
            ("Settimana", "settimanale", snapshot.week, current?.week.cap),
            ("Mese", "mensile", month, current?.month.cap),
        ]
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let current {
                    Text(current.name).font(.system(size: 12, weight: .semibold))
                    Text("in uso")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(tint))
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            if let full = limits.first(where: { ($0.window?.effectivePercent(at: now) ?? 0) >= UsageWindow.exhausted }),
               let free = full.window?.resetsAt {
                Label("Limite \(full.period) pieno: OpenCode Go torna disponibile \(Format.at(free, now: now))",
                      systemImage: "nosign")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if current?.isFree == true {
                Text("Il modello in uso è gratuito: non consuma questi limiti")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            ForEach(limits, id: \.label) { limit in
                if let window = limit.window {
                    SharedLimitLine(label: limit.label, window: window, cap: current?.isFree == true ? nil : limit.cap,
                                    model: current?.name, tint: tint, now: now)
                }
            }
        }
        .padding(10)
        .background(card.fill(Color.primary.opacity(0.05)))
        .overlay(card.strokeBorder(tint.opacity(0.7), lineWidth: 1))
    }

    private var card: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }
}

/// "5 ore  [════════──────]  24%  12,16 $ rimasti": a shared limit as a full-width bar. On the
/// right, what's left of it in dollars of the model in use (its `cap` is the whole window), or,
/// with no paid model in use, the time until it frees up.
private struct SharedLimitLine: View {
    let label: String
    let window: UsageWindow
    let cap: Double?
    let model: String?
    let tint: Color
    let now: Date

    var body: some View {
        let value = window.effectivePercent(at: now)
        let left = cap.map { $0 * max(0, 100 - value) / 100 }
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            UsageBar(value: value, tint: tint)
            Text("\(Int(value.rounded()))%")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(value >= 90 ? Color.red : value >= 80 ? Color.orange : Color.primary)
                .frame(width: 34, alignment: .trailing)
            Text(left.map { "\(Format.dollars($0)) rimasti" } ?? Format.countdown(window.resetsAt, now: now) ?? "")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
        }
        .monospacedDigit()
        .lineLimit(1)
        .help(note(left: left))
    }

    /// "Con DeepSeek V4.1 Flash restano 12,16 $ · si libera alle 13:44".
    private func note(left: Double?) -> String {
        var parts: [String] = []
        if let left, let model { parts.append("Con \(model) restano \(Format.dollars(left))") }
        if let resetsAt = window.resetsAt, resetsAt > now { parts.append("si libera " + Format.at(resetsAt, now: now)) }
        return parts.joined(separator: " · ")
    }
}


private struct CompactCell: View {
    let window: UsageWindow
    let tint: Color
    let now: Date

    var body: some View {
        let value = window.effectivePercent(at: now)
        HStack(spacing: 6) {
            Text("\(Int(value.rounded()))%")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .frame(width: 30, alignment: .leading)
            UsageBar(value: value, tint: tint)
        }
        .frame(width: Layout.column, alignment: .leading)
    }
}

private struct UsageBar: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(value >= 90 ? Color.red : tint)
                    .frame(width: value > 0 ? max(3, geo.size.width * value / 100) : 0)
            }
        }
        .frame(height: 4)
    }
}

private struct Shortcut: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.tertiary)
    }
}

private struct MenuRow<Trailing: View>: View {
    let title: String
    let icon: String
    var busy = false
    let action: () -> Void
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HoverRow(action: action) {
            HStack(spacing: 8) {
                MenuRowLabel(title: title, icon: icon, busy: busy)
                Spacer()
                trailing
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }
}

/// A project's share of the month, drawn like UsageBar and split in the colours of the services
/// whose work it was.
private struct ShareBar: View {
    let parts: [(tint: Color, cost: Double)]
    /// The bar's length, 0 to 1 of the track.
    let share: Double

    var body: some View {
        GeometryReader { geometry in
            let total = parts.reduce(0) { $0 + $1.cost }
            let length = share > 0 ? max(3, geometry.size.width * share) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                HStack(spacing: 0) {
                    ForEach(parts.indices, id: \.self) { i in
                        Rectangle()
                            .fill(parts[i].tint)
                            .frame(width: total > 0 ? length * parts[i].cost / total : 0)
                    }
                }
                .frame(width: length, alignment: .leading)
                .clipShape(Capsule())
            }
        }
    }
}

/// A row that highlights on hover and runs `action` when clicked, like a menu item. The
/// highlight is concentric with the panel: 18 pt corners minus the 6 pt inset.
private struct HoverRow<Content: View>: View {
    var highlightOpacity = 0.1
    let action: () -> Void
    @ViewBuilder let content: Content
    // @State is a macro in the current SDK and needs Xcode's plugins; a StateObject builds with the CLT alone.
    @StateObject private var hover = HoverState()
    private let highlight = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        Button(action: action) {
            content
                .background(highlight.fill(hover.isOn ? Color.primary.opacity(highlightOpacity) : .clear))
                .contentShape(highlight)
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
    }
}

private final class HoverState: ObservableObject {
    /// LIMITBAR_RENDER_HOVER=1 shows every row highlighted, to check the layout with --render.
    @Published var isOn = ProcessInfo.processInfo.environment["LIMITBAR_RENDER_HOVER"] != nil
}

private struct MenuRowLabel: View {
    let title: String
    let icon: String
    var busy = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: icon).font(.system(size: 12))
                }
            }
            .frame(width: 16)
            .foregroundStyle(.secondary)
            Text(title).font(.system(size: 13))
        }
    }
}
