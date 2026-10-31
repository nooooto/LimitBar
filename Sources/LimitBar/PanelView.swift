import SwiftUI

/// The panel: a card per service, with its limits as rings, then this month's value at API
/// prices, then the commands. It sits on Liquid Glass (see StatusController), so the cards are
/// faint platters rather than more glass, and text takes the system's vibrant hierarchy
/// (primary, secondary, tertiary); colour is for each service and for limits running out.
struct PanelView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: Layout.cardSpacing) {
                ForEach(settings.visibleProviders) { id in
                    // A click on the card opens the service's own usage page.
                    Card(action: { id.openUsagePage() }) {
                        if id == .opencode {
                            OpenCodeCard(state: store.state(id), now: context.date,
                                         workingSessions: store.activity.sessions(id), status: store.serviceStatus[id])
                        } else {
                            LimitsCard(provider: id, state: store.state(id), now: context.date,
                                       samples: store.history[id] ?? [], showHistory: settings.showHistory,
                                       workingSessions: store.activity.sessions(id), status: store.serviceStatus[id])
                            if id == .claude, store.state(.claude).needsSignIn || store.claudeLoginPending {
                                ClaudeSignIn(store: store)
                            }
                        }
                    }
                    .help(id.usageDestination)
                }
                if settings.showValue {
                    // Only the services whose work can be priced (see CostLedger).
                    ValueCard(store: store, providers: settings.visibleProviders.filter(\.isInCostLedger), now: context.date)
                }
                Footer(store: store)
            }
            .padding(Layout.inset)
        }
        .frame(width: Layout.width)
    }
}

/// Sizes. The cards sit `inset` in from the panel's edge with corners concentric to it.
enum Layout {
    static let width: CGFloat = 340
    static let panelRadius: CGFloat = 22
    static let inset: CGFloat = 10
    static let cardRadius: CGFloat = panelRadius - inset
    static let cardPadding: CGFloat = 12
    static let cardSpacing: CGFloat = 8
    /// Between the groups inside a card: header, rings, notes, chart.
    static let group: CGFloat = 12
    static let ring: CGFloat = 54
    static let ringLine: CGFloat = 6
    static let valueColumn: CGFloat = 58
}

/// Orange from 80%, red from 90%, as in the menu bar; `normal` otherwise.
private func level(_ percent: Double, normal: Color) -> Color {
    percent >= 90 ? Color(nsColor: .systemRed) : percent >= 80 ? Color(nsColor: .systemOrange) : normal
}

// MARK: - Building blocks

/// A platter for one part of the panel, a little brighter under the pointer when it does
/// something on click. Buttons inside it keep their own clicks.
private struct Card<Content: View>: View {
    var action: (() -> Void)? = nil
    @ViewBuilder let content: Content
    // @State is a macro in the current SDK and needs Xcode's plugins; a StateObject builds with the CLT alone.
    @StateObject private var hover = HoverState()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: Layout.group) { content }
            .padding(Layout.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Color.primary.opacity(action != nil && hover.isOn ? 0.085 : 0.05)))
            .contentShape(shape)
            .onHover { hover.isOn = $0 }
            .onTapGesture { action?() }
    }
}

/// "[logo] Claude          ● Al lavoro
///         Pro": the service's icon, its name over what it runs on (plan or model), and
/// whether it's working or when it was last read.
private struct CardHeader: View {
    let provider: ProviderID
    let detail: String?
    let snapshot: ProviderSnapshot?
    let workingSessions: Int
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: provider.logo).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.title).font(.system(size: 13, weight: .semibold))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if workingSessions > 0 {
                HStack(spacing: 5) {
                    Circle().fill(provider.tint).frame(width: 7, height: 7)
                    Text(workingSessions == 1 ? "Al lavoro" : "\(workingSessions) al lavoro")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(provider.tint)
            } else if let snapshot {
                Text("Aggiornato " + Format.ago(snapshot.updatedAt, now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .help(snapshot.source == "statusline" ? "Letto dalla status line di Claude Code" : "")
            }
        }
    }
}

/// A limit as a ring filling up in the service's colour (orange, then red, as it runs out),
/// with its name and a line or two under it; with a `pace`, a tick where even use would be and
/// a line saying how far from it the use is.
private struct Gauge: View {
    let title: String
    let percent: Double
    let tint: Color
    let lines: [String]
    var pace: Pace? = nil

    var body: some View {
        let color = level(percent, normal: tint)
        VStack(spacing: 7) {
            ZStack {
                Circle().stroke(color.opacity(0.18), lineWidth: Layout.ringLine)
                Circle()
                    .trim(from: 0, to: min(max(percent, 0), 100) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: Layout.ringLine, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if let pace {
                    PaceTick(fraction: pace.expected)
                        .stroke(.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(percent >= 80 ? AnyShapeStyle(color) : AnyShapeStyle(.primary))
            }
            .frame(width: Layout.ring, height: Layout.ring)
            VStack(spacing: 1) {
                Text(title).font(.system(size: 11.5, weight: .semibold))
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(index == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                }
                if let pace {
                    Text(pace.text)
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(paceColor(pace.state))
                        .help("Dove saresti usando il limite in modo costante fino al reset")
                }
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func paceColor(_ state: Pace.State) -> AnyShapeStyle {
        switch state {
        case .onTrack: return AnyShapeStyle(.secondary)
        case .ahead: return AnyShapeStyle(Color(nsColor: .systemOrange))
        case .behind: return AnyShapeStyle(Color(nsColor: .systemGreen))
        }
    }
}

/// A short radial mark across the ring at `fraction` of the way round, clockwise from the top.
private struct PaceTick: Shape {
    let fraction: Double

    func path(in rect: CGRect) -> Path {
        let angle = fraction * 2 * .pi - .pi / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        func point(_ radius: CGFloat) -> CGPoint {
            CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
        }
        var path = Path()
        path.move(to: point((Layout.ring - Layout.ringLine) / 2 - 1))
        path.addLine(to: point((Layout.ring + Layout.ringLine) / 2 + 1))
        return path
    }
}

/// The rings side by side, three to a row.
private struct Gauges: View {
    let gauges: [Gauge]

    var body: some View {
        let rows = stride(from: 0, to: gauges.count, by: 3).map { Array(gauges[$0..<min($0 + 3, gauges.count)]) }
        VStack(spacing: Layout.group) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, gauge in gauge }
                }
            }
        }
    }
}

/// A sentence on a tinted strip: a limit used up, the forecast, an error.
private struct Banner: View {
    let symbol: String
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: Layout.cardRadius - 4, style: .continuous))
    }
}

/// A quieter note: where the numbers come from, an update paused.
private struct Note: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

/// How a window is named in the panel's sentences.
private struct Period {
    let label: String
    /// "5 ore esaurite", "Settimana esaurita", "Mese esaurito".
    let exhausted: String
    /// The verbs and adjectives follow "5 ore", which is plural.
    let plural: Bool

    var resets: String { plural ? "si azzerano" : "si azzera" }
    var notStarted: String { plural ? "Non iniziate" : "Non iniziata" }

    static let fiveHours = Period(label: "5 ore", exhausted: "5 ore esaurite", plural: true)
    static let week = Period(label: "Settimana", exhausted: "Settimana esaurita", plural: false)
    static let month = Period(label: "Mese", exhausted: "Mese esaurito", plural: false)

    /// The week slot holds a monthly window on some plans (Codex Free).
    static func of(_ kind: WindowKind, _ window: UsageWindow) -> Period {
        kind == .fiveHour ? .fiveHours : kind.limitName(window) == "mensile" ? .month : .week
    }

    /// An extra limit Anthropic adds: a model's own week ("Settimana Opus", shown as "Opus"),
    /// or the extra usage paid on top of the plan.
    static func extra(_ label: String) -> Period {
        let modelWeek = "Settimana "
        if label.hasPrefix(modelWeek) {
            let model = String(label.dropFirst(modelWeek.count))
            return Period(label: model, exhausted: "Settimana \(model) esaurita", plural: false)
        }
        if label == "Uso extra" { return Period(label: "Uso extra", exhausted: "Uso extra esaurito", plural: false) }
        return Period(label: label, exhausted: "Limite \(label) esaurito", plural: false)
    }
}

private extension String {
    /// "Si azzera …" from "si azzera …", for a sentence that starts with it.
    var sentence: String { prefix(1).uppercased() + dropFirst() }
}

/// "Settimana esaurita · si azzera domani alle 01:00", for the first limit used up.
private func exhaustedBanner(_ limits: [(period: Period, window: UsageWindow?)], now: Date) -> Banner? {
    guard let full = limits.first(where: { ($0.window?.effectivePercent(at: now) ?? 0) >= UsageWindow.exhausted }),
          let reset = full.window?.resetsAt else { return nil }
    return Banner(symbol: "xmark.octagon.fill", text: "\(full.period.exhausted) · \(full.period.resets) \(Format.at(reset, now: now))",
                  color: Color(nsColor: .systemRed))
}

/// What a limit's ring says under its name about time: until it resets, or that it hasn't started.
private func timeLine(_ period: Period, _ window: UsageWindow, now: Date) -> String {
    if let countdown = Format.countdown(window.resetsAt, now: now) { return countdown }
    return window.effectivePercent(at: now) > 0 ? "" : period.notStarted
}

// MARK: - Services

/// Claude (and Codex, if it's switched back on): a ring per limit with the time until it
/// resets, an alert when one is used up, the forecast, and the last hours as a chart.
private struct LimitsCard: View {
    let provider: ProviderID
    let state: ProviderState
    let now: Date
    let samples: [UsageSample]
    let showHistory: Bool
    let workingSessions: Int
    let status: ServiceStatus?

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
        CardHeader(provider: provider, detail: snapshot?.plan ?? provider.toolName, snapshot: snapshot,
                   workingSessions: workingSessions, now: now)
        ServiceStatusStrip(status: status)
        if let snapshot {
            exhaustedBanner(limits, now: now)
            Gauges(gauges: limits.enumerated().map { index, limit in
                guard let window = limit.window else {
                    return Gauge(title: limit.period.label, percent: 0, tint: provider.tint, lines: ["Nessun limite"])
                }
                // The 5 hours (first) are used in bursts: they keep the forecast, not a pace.
                return Gauge(title: limit.period.label, percent: window.effectivePercent(at: now), tint: provider.tint,
                             lines: [timeLine(limit.period, window, now: now)],
                             pace: index == 0 ? nil : Pace.of(window, now: now))
            })
            if let forecast {
                let period = Period.of(forecast.kind, forecast.window)
                Banner(symbol: "chart.line.uptrend.xyaxis",
                       text: "A questo ritmo: \(period.exhausted.lowercasedFirst) \(Format.at(forecast.date, now: now))",
                       color: Color(nsColor: .systemOrange))
                    .help("Al ritmo delle ultime ore, prima che il limite si azzeri")
            }
            if showHistory, let chart = UsageChart(samples: samples, snapshot: snapshot, now: now, tint: provider.tint) {
                chart
            }
            if let note = snapshot.note { Note(symbol: "info.circle", text: note) }
        } else if state.error == nil {
            Note(symbol: "hourglass", text: "In attesa di dati…")
        }
        StateNotes(state: state)
    }
}

private extension String {
    /// "settimana esaurita" from "Settimana esaurita", for the middle of a sentence.
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

/// What the service's status page reports, when it isn't all well: orange for reduced
/// performance, red for an outage, a quiet note for maintenance. A click opens the page.
private struct ServiceStatusStrip: View {
    let status: ServiceStatus?

    var body: some View {
        if let status, status.health != .operational {
            let text = status.text ?? ""
            Button {
                NSWorkspace.shared.open(status.page)
            } label: {
                switch status.health {
                case .outage: Banner(symbol: "xmark.octagon.fill", text: text, color: Color(nsColor: .systemRed))
                case .degraded: Banner(symbol: "exclamationmark.triangle.fill", text: text, color: Color(nsColor: .systemOrange))
                default: Note(symbol: "wrench.and.screwdriver", text: text)
                }
            }
            .buttonStyle(.plain)
            .help("Apri la pagina di stato")
        }
    }
}

/// The service's error, or a notice that its numbers are still the last good ones.
private struct StateNotes: View {
    let state: ProviderState

    var body: some View {
        if let error = state.error {
            Banner(symbol: "exclamationmark.triangle.fill", text: error, color: Color(nsColor: .systemRed))
        } else if let notice = state.notice {
            Note(symbol: "pause.circle", text: notice)
        }
    }
}

/// The main window over the last day as an area, in the service's colour and red where it was
/// used up; nil until there's half an hour of readings that actually move.
private struct UsageChart: View {
    let values: [Double]
    let tint: Color

    private static let slices = 72

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
        // Each slice shows the reading in force at its end.
        let slice = now.timeIntervalSince(first.0) / Double(Self.slices)
        values = (1...Self.slices).map { index in
            let end = first.0.addingTimeInterval(slice * Double(index))
            return points.last { $0.0 <= end }?.1 ?? first.1
        }
    }

    var body: some View {
        Canvas { context, size in
            let step = size.width / CGFloat(values.count)
            func y(_ value: Double) -> CGFloat { size.height * (1 - CGFloat(min(max(value, 0), 100)) / 100) }
            // Steps, as the readings are: each slice level, joined by straight risers.
            var line = Path()
            for (index, value) in values.enumerated() {
                let x = CGFloat(index) * step
                if index == 0 { line.move(to: CGPoint(x: 0, y: y(value))) } else { line.addLine(to: CGPoint(x: x, y: y(value))) }
                line.addLine(to: CGPoint(x: x + step, y: y(value)))
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            let fade = Gradient(colors: [tint.opacity(0.45), tint.opacity(0.05)])
            context.fill(area, with: .linearGradient(fade, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            // Used up: those slices in red, the whole height.
            let red = Color(nsColor: .systemRed)
            for (index, value) in values.enumerated() where value >= UsageWindow.exhausted {
                context.fill(Path(CGRect(x: CGFloat(index) * step, y: 0, width: step, height: size.height)),
                             with: .linearGradient(Gradient(colors: [red.opacity(0.5), red.opacity(0.08)]),
                                                   startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .frame(height: 36)
        .help("Uso nelle ultime 24 ore, da sinistra a destra fino ad adesso")
    }
}

/// OpenCode Go: the model in use, a ring per shared limit with the dollars left of it for
/// that model, an alert when one is used up, and who used the 5 hours.
private struct OpenCodeCard: View {
    let state: ProviderState
    let now: Date
    let workingSessions: Int
    let status: ServiceStatus?

    private let tint = ProviderID.opencode.tint
    private var snapshot: ProviderSnapshot? { state.snapshot }
    private var models: [ModelUsage] { snapshot?.models ?? [] }

    var body: some View {
        let current = models.first(where: \.inUse)
        CardHeader(provider: .opencode, detail: current?.name ?? snapshot?.plan, snapshot: snapshot,
                   workingSessions: workingSessions, now: now)
        ServiceStatusStrip(status: status)
        Group {
            if let snapshot {
                let paid = current?.isFree == true ? nil : current
                let limits: [(period: Period, window: UsageWindow?, cap: Double?)] = [
                    (.fiveHours, snapshot.fiveHour, paid?.fiveHour.cap),
                    (.week, snapshot.week, paid?.week.cap),
                    (.month, snapshot.month, paid?.month.cap),
                ]
                exhaustedBanner(limits.map { ($0.period, $0.window) }, now: now)
                if current?.isFree == true {
                    Note(symbol: "gift", text: "Modello gratuito: non consuma i limiti")
                }
                Gauges(gauges: limits.compactMap { limit in
                    limit.window.map { gauge(limit.period, $0, cap: limit.cap, model: paid?.name) }
                })
                let users = models.filter { $0.fiveHour.share >= 0.5 }.sorted { $0.fiveHour.share > $1.fiveHour.share }
                if !users.isEmpty { ModelShares(models: Array(users.prefix(4)), tint: tint) }
                if models.isEmpty {
                    Note(symbol: "tray", text: "Nessuna richiesta con Go questo mese")
                }
            } else if state.error == nil {
                Note(symbol: "hourglass", text: "In attesa di dati…")
            }
            StateNotes(state: state)
        }
        // What the numbers are, and each model's month, for whoever wonders.
        .help((["Stima dall'uso su questo Mac: i limiti sono condivisi da tutti i modelli."]
               + models.filter { $0.month.share > 0 || $0.requests > 0 }.map {
                   "\($0.name): \($0.requests == 1 ? "1 richiesta" : "\($0.requests) richieste"), \(Format.dollars($0.spent)), "
                       + "\(Int($0.month.share.rounded()))% del mese"
               }).joined(separator: "\n"))
    }

    /// A shared limit with what's left of it in dollars of the model in use, and the time
    /// until it resets.
    private func gauge(_ period: Period, _ window: UsageWindow, cap: Double?, model: String?) -> Gauge {
        let value = window.effectivePercent(at: now)
        let left = cap.map { $0 * max(0, 100 - value) / 100 }
        var lines = [timeLine(period, window, now: now)]
        if let left { lines.insert("\(Format.dollars(left)) rimasti", at: 0) }
        // The 5 hours are used in bursts: no pace for them.
        let pace = period.label == Period.fiveHours.label ? nil : Pace.of(window, now: now)
        return Gauge(title: period.label, percent: value, tint: tint, lines: lines, pace: pace)
    }
}

/// Who used the 5 hours: one bar split among the models, each in a shade of OpenCode's colour,
/// and a line for each with its share and what it spent.
private struct ModelShares: View {
    let models: [ModelUsage]
    let tint: Color

    private static let shades: [Double] = [1, 0.62, 0.38, 0.22]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Chi ha usato le 5 ore").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(Array(models.enumerated()), id: \.offset) { index, model in
                        Capsule()
                            .fill(tint.opacity(Self.shades[index]))
                            .frame(width: max(4, geometry.size.width * min(model.fiveHour.share, 100) / 100 - 2))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 6)
            .background(Capsule().fill(tint.opacity(0.12)))
            VStack(spacing: 4) {
                ForEach(Array(models.enumerated()), id: \.offset) { index, model in
                    HStack(spacing: 7) {
                        Circle().fill(tint.opacity(Self.shades[index])).frame(width: 7, height: 7)
                        Text(model.name).lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(Int(model.fiveHour.share.rounded()))%")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(level(model.fiveHour.share, normal: .primary))
                        Text(Format.dollars(model.fiveHour.used))
                            .foregroundStyle(.secondary)
                            .frame(width: Layout.valueColumn, alignment: .trailing)
                    }
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                }
            }
        }
    }
}

// MARK: - Value at API prices

/// This month's work at API prices: the total and what the plans saved, per service its plan
/// and how many times the plan's price it was worth, then the projects with their share.
private struct ValueCard: View {
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
            Card(action: { SpendWindow.shared.show(store: store) }) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Valore di \(Format.month(now))")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(Format.wholeEuros(fromDollars: total))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(comparison.map(Format.change) ?? "Stima a prezzi API")
                            .foregroundStyle(.secondary)
                            .help(comparison.map(Format.comparisonNote) ?? "Quanto costerebbe lo stesso lavoro pagandolo a prezzi API")
                        if saved > 0 {
                            Text("\(Format.wholeEuros(fromDollars: saved)) risparmiati")
                                .fontWeight(.semibold)
                                .foregroundStyle(Color(nsColor: .systemGreen))
                                .help("Il valore del lavoro meno quello che costano gli abbonamenti")
                        }
                    }
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                }
                VStack(spacing: 6) {
                    ForEach(values, id: \.0) { id, value in serviceLine(id, value) }
                }
                if !projects.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Progetti")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 4)
                        ForEach(projects) { project in ProjectLine(project: project, monthTotal: total, note: projectNote(project, monthTotal: total)) }
                    }
                }
            }
        }
    }

    /// "[logo] Claude Pro          ×18,2    326 €": the multiple in the service's colour.
    private func serviceLine(_ id: ProviderID, _ value: ServiceValue) -> some View {
        HStack(spacing: 7) {
            Image(nsImage: id.logo).resizable().frame(width: 16, height: 16)
            Text(id.title)
            Text(store.state(id).snapshot?.plan ?? "").foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value.multiple.map(Format.multiple) ?? "–")
                .fontWeight(.semibold)
                .foregroundStyle(value.multiple == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(id.tint))
            Text(Format.wholeEuros(fromDollars: value.cost))
                .fontWeight(.semibold)
                .frame(width: Layout.valueColumn, alignment: .trailing)
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .lineLimit(1)
        .help(priceNote(id, value))
    }

    /// Tooltip: "LimitBar: Claude 80,12 € · 52% del mese", and for Altro what's in it.
    private func projectNote(_ project: ProjectValue, monthTotal: Double) -> String {
        let share = monthTotal > 0 ? min(project.total / monthTotal, 1) * 100 : 0
        let services = providers.compactMap { id in project.costs[id].map { "\(id.title) \(Format.euros(fromDollars: $0))" } }
        let name = project.name == ProjectFolder.other ? "Altro" : project.name
        var note = "\(name): \(services.joined(separator: ", ")) · \(Int(share.rounded()))% del mese"
        if project.name == ProjectFolder.other {
            let folded = project.folded.isEmpty ? "" : ", e \(project.folded.joined(separator: ", "))"
            note += "\nChat senza cartella, cartelle con più progetti\(folded)"
        } else if project.folder != nil {
            note += "\nClic per aprirlo nel Finder"
        }
        return note
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

/// A project, its share of the month and its value. A click opens its folder in the Finder;
/// Altro and folders that are gone don't open.
private struct ProjectLine: View {
    let project: ProjectValue
    let monthTotal: Double
    let note: String
    @StateObject private var hover = HoverState()

    var body: some View {
        let share = monthTotal > 0 ? min(project.total / monthTotal, 1) * 100 : 0
        let isOther = project.name == ProjectFolder.other
        let opens = project.folder != nil
        HStack(spacing: 7) {
            Image(systemName: isOther ? "ellipsis.circle" : "folder")
                .foregroundStyle(.tertiary)
                .frame(width: 16)
            Text(isOther ? "Altro" : project.name)
                .foregroundStyle(isOther ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(Int(share.rounded()))%").foregroundStyle(.tertiary)
            Text(Format.wholeEuros(fromDollars: project.total))
                .fontWeight(.semibold)
                .frame(width: Layout.valueColumn, alignment: .trailing)
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(opens && hover.isOn ? 0.08 : 0)))
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onHover { hover.isOn = $0 }
        .onTapGesture {
            if let folder = project.folder { NSWorkspace.shared.open(URL(fileURLWithPath: folder, isDirectory: true)) }
        }
        .help(note)
    }
}

// MARK: - Claude sign-in

private struct ClaudeSignIn: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.claudeLoginPending {
                Text("Approva l'accesso nel browser, copia il codice che compare, poi incollalo qui.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Incolla codice") { Task { await store.finishClaudeLogin() } }.prominentGlassButton()
                    Button("Annulla") { store.cancelClaudeLogin() }.glassButton()
                }
            } else {
                Button("Accedi a Claude…") { store.startClaudeLogin() }.prominentGlassButton()
            }
        }
    }
}

// MARK: - Commands

/// Refresh and settings on the left, quit on the right, as glass buttons with their shortcuts.
private struct Footer: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        HStack(spacing: 8) {
            Button { Task { await store.refresh(force: true) } } label: {
                Label(store.isRefreshing ? "Aggiorno…" : "Aggiorna", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Aggiorna ora (⌘R)")
            .disabled(store.isRefreshing)
            Button { SettingsWindow.shared.show(store: store) } label: {
                Label("Impostazioni", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
            .help("Impostazioni di LimitBar (⌘,)")
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .keyboardShortcut("q", modifiers: .command)
            .help("Esci da LimitBar (⌘Q)")
        }
        .font(.system(size: 12))
        .panelButtons()
    }
}

/// The footer's buttons: glass shaped like the cards, its corners concentric with the panel's
/// (the system's glass button keeps its own, smaller radius whatever shape it's given).
@available(macOS 26.0, *)
private struct PanelButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .frame(minWidth: 32, minHeight: 30)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous))
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    @ViewBuilder fileprivate func panelButtons() -> some View {
        if #available(macOS 26.0, *) { buttonStyle(PanelButtonStyle()) } else { buttonStyle(.bordered).controlSize(.large) }
    }

    /// The system's glass buttons from macOS 26, bordered ones before.
    @ViewBuilder func glassButton() -> some View {
        if #available(macOS 26.0, *) { buttonStyle(.glass) } else { buttonStyle(.bordered) }
    }

    @ViewBuilder func prominentGlassButton() -> some View {
        if #available(macOS 26.0, *) { buttonStyle(.glassProminent) } else { buttonStyle(.borderedProminent) }
    }
}

final class HoverState: ObservableObject {
    /// LIMITBAR_RENDER_HOVER=1 shows every row highlighted, to check the layout with --render.
    @Published var isOn = ProcessInfo.processInfo.environment["LIMITBAR_RENDER_HOVER"] != nil
}
