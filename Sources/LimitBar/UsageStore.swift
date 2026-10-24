import AppKit
import Combine
import Network

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var states: [ProviderID: ProviderState] = [:] {
        didSet {
            // Every new reading feeds the history (chart, forecast) and the notifications.
            for id in ProviderID.allCases {
                guard let snapshot = states[id]?.snapshot, snapshot != oldValue[id]?.snapshot else { continue }
                snapshotChanged(id, snapshot)
            }
        }
    }
    @Published private(set) var isRefreshing = false
    @Published private(set) var history: [ProviderID: [UsageSample]] = UsageHistory.load()

    let settings = AppSettings.shared
    let activity = AgentActivity()
    /// API-price totals from the local logs, per model and per project.
    @Published private(set) var costs = CostLedger.Summary()
    private let ledger = CostLedger()
    private var lastRefresh: Date?
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var wakeObserver: NSObjectProtocol?
    private var statusWatcher: DispatchSourceFileSystemObject?
    /// The OpenCode desktop app's state folder and files, where it notes the model picked.
    private var openCodeStateWatchers: [DispatchSourceFileSystemObject] = []
    private var openCodeModel = OpenCodeActivity.currentModel()
    private var openCodeModelCheck: DispatchWorkItem?
    private var settingsObserver: AnyCancellable?
    private var activityObserver: AnyCancellable?
    private var powerObserver: NSObjectProtocol?
    private let pathMonitor = NWPathMonitor()
    private var isOnline = true

    init() {
        for id in ProviderID.allCases {
            let cached = Cache.load(id)
            states[id] = ProviderState(snapshot: cached)
            // Relaunching the app shouldn't cost an extra request if the cached data is recent.
            if let cached, cached.source == "api" { lastAttempt[id] = cached.updatedAt }
        }
        scheduleTimer()
        settingsObserver = settings.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the new value is stored.
            DispatchQueue.main.async { self?.settingsChanged() }
        }
        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleTimer() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async { self?.networkChanged(online: online) }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        // The menu bar label follows the agents' activity, so pass its changes on.
        // When a turn ends its replies are in the logs, so the value can be brought up to date too.
        activityObserver = activity.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            DispatchQueue.main.async { self?.updateValue() }
        }
        activity.onStretchEnded = { [weak self] id, duration in
            guard let self, self.settings.enabledProviders.contains(id) else { return }
            // OpenCode's estimate is read locally, so it can follow each turn's cost right away.
            if id == .opencode { Task { await self.refresh() } }
            Notifier.stretchEnded(id, after: duration, enabled: self.settings.notifyFinished)
        }
        updateValue()
        watchClaudeStatus()
        watchOpenCodeModel()
        Task { await refresh() }
    }

    func state(_ id: ProviderID) -> ProviderState { states[id] ?? ProviderState() }

    func refreshIfStale() {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 30 { return }
        Task { await refresh() }
    }

    // MARK: Settings, history, notifications

    /// The chosen interval, doubled while the Mac is in Low Power Mode.
    private var refreshInterval: TimeInterval {
        settings.refreshInterval * (ProcessInfo.processInfo.isLowPowerModeEnabled ? 2 : 1)
    }

    private func scheduleTimer() {
        let interval = refreshInterval
        guard interval != timerInterval else { return }
        timer?.invalidate()
        timerInterval = interval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        // Lets macOS batch this wakeup with others; the exact second doesn't matter here.
        timer.tolerance = interval * 0.1
        self.timer = timer
    }

    /// Without a connection there's nothing to ask; once it's back, catch up right away.
    private func networkChanged(online: Bool) {
        let cameBack = online && !isOnline
        isOnline = online
        if cameBack { Task { await refresh() } }
    }

    private func settingsChanged() {
        scheduleTimer()
        // OpenCode's limits depend on its plan: work them out again now, not at the next turn.
        if settings.openCodePlan != openCodePlan {
            openCodePlan = settings.openCodePlan
            lastAttempt[.opencode] = nil
        }
        if !settings.notifyResets { Notifier.cancelResetAlerts() }
        if settings.notifyThresholds || settings.notifyResets { Notifier.requestAuthorization() }
        // The menu bar number, the panel rows and the iCloud copy all depend on the settings.
        objectWillChange.send()
        Task { await refresh() }
    }

    private func snapshotChanged(_ id: ProviderID, _ snapshot: ProviderSnapshot) {
        // Sample data for a layout render is shown, never kept or acted on.
        guard !snapshot.isSample else { return }
        var samples = history[id] ?? []
        if UsageHistory.record(snapshot, into: &samples) {
            history[id] = samples
            UsageHistory.save(history)
        }
        if settings.enabledProviders.contains(id) {
            Notifier.evaluate(id, snapshot: snapshot, settings: settings)
        }
    }

    // MARK: Request pacing

    /// Anthropic's usage endpoint answers 429 when polled often, so Claude is never asked more
    /// than every 5 minutes, whatever the chosen interval.
    private func minimumSpacing(_ id: ProviderID) -> TimeInterval {
        switch id {
        case .claude: return max(300, refreshInterval)
        case .codex: return refreshInterval
        // Read from this Mac's own database: as often as a minute costs nothing.
        case .opencode: return min(60, refreshInterval)
        }
    }

    private static let initialBackoff: TimeInterval = 300
    /// A 429 here lasts on the order of minutes; waiting longer than this only leaves stale numbers.
    private static let maximumBackoff: TimeInterval = 600

    private var lastAttempt: [ProviderID: Date] = [:]
    private var openCodePlan = OpenCodeProvider.Plan.current
    private var blockedUntil: [ProviderID: Date] = [:]
    private var backoff: [ProviderID: TimeInterval] = [:]

    /// `force` (the "Aggiorna ora" button) always tries once, even during a back-off.
    private func isDue(_ id: ProviderID, force: Bool, now: Date, spacing: TimeInterval) -> Bool {
        if force { return true }
        if let until = blockedUntil[id], until > now { return false }
        guard let last = lastAttempt[id] else { return true }
        // A little slack so the 2-minute timer doesn't miss a 2-minute spacing by milliseconds.
        return now.timeIntervalSince(last) >= spacing - 5
    }

    func refresh(force: Bool = false) async {
        updateValue()
        let now = Date()
        let claudeIsLocal = applyLocalClaude(now: now)
        guard !isRefreshing, isOnline else { return }
        let due = settings.visibleProviders.filter {
            let spacing = $0 == .claude && claudeIsLocal
                ? max(Self.spacingWhileLocal, refreshInterval) : minimumSpacing($0)
            return isDue($0, force: force, now: now, spacing: spacing)
        }
        guard !due.isEmpty else { return }

        isRefreshing = true
        lastRefresh = now
        for id in due { lastAttempt[id] = now }
        let results = await withTaskGroup(of: (ProviderID, Result<ProviderSnapshot, Error>).self) { group in
            for id in due {
                group.addTask { (id, await Self.capture(id.fetch)) }
            }
            var collected: [(ProviderID, Result<ProviderSnapshot, Error>)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        for (id, result) in results { apply(result, to: id) }
        isRefreshing = false
    }

    private nonisolated static func capture(
        _ fetch: @Sendable () async throws -> ProviderSnapshot
    ) async -> Result<ProviderSnapshot, Error> {
        do { return .success(try await fetch()) } catch { return .failure(error) }
    }

    private func apply(_ result: Result<ProviderSnapshot, Error>, to id: ProviderID) {
        var state = self.state(id)
        if case .failure(ProviderError.rateLimited(let retryAfter)) = result {
            let delay = min(retryAfter ?? backoff[id].map { $0 * 2 } ?? Self.initialBackoff, Self.maximumBackoff)
            backoff[id] = delay
            let retryAt = Date().addingTimeInterval(max(delay, 60))
            blockedUntil[id] = retryAt
            let when = Format.at(retryAt, now: Date())
            if state.snapshot != nil {
                // The numbers on screen are still the last good ones, so this isn't an error.
                state.notice = "Aggiornamento in pausa · riprovo \(when)"
                state.error = nil
            } else {
                state.error = "Troppe richieste · riprovo \(when)"
            }
            states[id] = state
            return
        }
        state.notice = nil
        switch result {
        case .success(let snapshot):
            backoff[id] = nil
            blockedUntil[id] = nil
            // A log-based fallback can be older than what we already have from the API.
            if let current = state.snapshot, current.updatedAt > snapshot.updatedAt {
                state.error = "Server non raggiungibile"
            } else {
                // Claude Code's local reading may be newer than the server's for one of the windows.
                let snapshot = id == .claude ? snapshot.merging(windowsOf: state.snapshot) : snapshot
                state.snapshot = snapshot
                state.error = nil
                state.needsSignIn = false
                Cache.save(snapshot, for: id)
            }
        case .failure(let error):
            switch error as? ProviderError {
            case .notSignedIn, .expired: state.needsSignIn = true
            default: break
            }
            if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
                state.error = "Nessuna connessione"
            } else {
                state.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        states[id] = state
    }

    // MARK: Claude from the terminal

    /// Claude Code updates its status line after every reply, so a copy this recent stands in for the server.
    private static let localFreshness: TimeInterval = 300
    /// Claude Code's copy is whole percents, taken before each reply is counted, so the
    /// server is still asked now and then to catch up with it.
    private static let spacingWhileLocal: TimeInterval = 600

    /// Shows the limits Claude Code saw last if they're newer than ours; returns true
    /// while they're fresh enough that the usage endpoint can be asked less often.
    @discardableResult
    private func applyLocalClaude(now: Date) -> Bool {
        var state = self.state(.claude)
        guard let local = ClaudeProvider.localSnapshot(previous: state.snapshot) else { return false }
        if state.snapshot.map({ local.updatedAt > $0.updatedAt }) ?? true {
            // Never step back below a higher reading the server already gave for the same window.
            let local = local.merging(windowsOf: state.snapshot)
            state.snapshot = local
            state.error = nil
            state.notice = nil
            states[.claude] = state
            Cache.save(local, for: .claude)
        }
        return now.timeIntervalSince(local.updatedAt) < Self.localFreshness
    }

    /// The status line script replaces the file with a rename, which shows up as a write on its folder.
    private func watchClaudeStatus() {
        let folder = ClaudeProvider.statusFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        statusWatcher = FileWatch.start(folder) { [weak self] in
            MainActor.assumeIsolated { _ = self?.applyLocalClaude(now: Date()) }
        }
    }

    /// Picking another model in OpenCode should show at once: its limits are the ones that matter
    /// now. The app rewrites these files for other reasons too, so only a new model refreshes.
    private func watchOpenCodeModel() {
        guard ProviderID.opencode.isActive else { return }
        openCodeStateWatchers.forEach { $0.cancel() }
        let folder = OpenCodeActivity.desktopFolder
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("opencode.workspace.") && $0.pathExtension == "dat" }
        let changed: () -> Void = { [weak self] in MainActor.assumeIsolated { self?.openCodeStateChanged() } }
        openCodeStateWatchers = ([FileWatch.start(folder, handler: changed)]
            + files.map { FileWatch.start($0, events: [.write, .extend, .delete, .rename], handler: changed) })
            .compactMap { $0 }
    }

    private func openCodeStateChanged() {
        // A burst of writes makes one check, half a second after the last.
        openCodeModelCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.watchOpenCodeModel()  // a file may have been replaced or added
                let model = OpenCodeActivity.currentModel()
                guard model != self.openCodeModel else { return }
                self.openCodeModel = model
                self.lastAttempt[.opencode] = nil
                Task { await self.refresh() }
            }
        }
        openCodeModelCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: check)
    }

    // MARK: Value at API prices

    /// Reads what's new in the session logs; cheap after the first pass.
    func updateValue() {
        ledger.update { [weak self] summary in
            guard let self else { return }
            costs = summary
            Notifier.weeklySummaryIfDue(costs: summary.projects, history: history,
                                        providers: settings.visibleProviders.filter(\.isInCostLedger),
                                        enabled: settings.notifyWeekly)
        }
        // API prices are in dollars; the panel shows euros at the ECB's daily rate.
        ExchangeRate.shared.refreshIfNeeded { [weak self] in self?.objectWillChange.send() }
    }

    /// This month's work with a service, priced at the API rates, next to its subscription.
    func monthValue(_ id: ProviderID, now: Date = Date()) -> ServiceValue {
        let month = String(CostLedger.dayKey(now).prefix(7))
        var value = ServiceValue(cost: 0, subscription: Prices.subscription(id, plan: state(id).snapshot?.plan))
        value.cost = CostLedger.cost(of: [id], in: costs.projects) { $0.hasPrefix(month) }
        return value
    }

    /// This month so far next to the same days of last month, when last month had any work.
    func monthComparison(_ providers: [ProviderID], now: Date = Date()) -> MonthComparison? {
        MonthComparison(costs: costs.projects, completeSince: costs.completeSince, providers: providers, now: now)
    }

    /// This month's biggest projects by what their work with `providers` was worth, then one
    /// `ProjectFolder.other` entry with the rest: chats without a folder, folders that hold
    /// several projects, and the smaller projects.
    func monthProjects(_ providers: [ProviderID], shown: Int, now: Date = Date()) -> [ProjectValue] {
        let month = String(CostLedger.dayKey(now).prefix(7))
        var byName: [String: ProjectValue] = [:]
        for id in providers {
            for (day, projects) in costs.projects[id.rawValue] ?? [:] where day.hasPrefix(month) {
                for (name, cost) in projects {
                    byName[name, default: ProjectValue(name: name, folder: costs.projectFolders[name])].costs[id, default: 0] += cost
                }
            }
        }
        let projects = byName.values
            .filter { $0.name != ProjectFolder.other && $0.total > 0 }
            .sorted { $0.total > $1.total }
        var rest = byName[ProjectFolder.other] ?? ProjectValue(name: ProjectFolder.other)
        for project in projects.dropFirst(shown) {
            rest.costs.merge(project.costs, uniquingKeysWith: +)
            rest.folded.append(project.name)
        }
        return Array(projects.prefix(shown)) + (rest.total > 0 ? [rest] : [])
    }

    // MARK: Claude sign-in

    @Published private(set) var claudeLoginPending = false
    @Published private(set) var claudeSignedInHere = ClaudeAuth.isSignedIn
    private var pendingLogin: ClaudeAuth.PendingLogin?

    func startClaudeLogin() {
        pendingLogin = ClaudeAuth.beginLogin()
        claudeLoginPending = true
    }

    func cancelClaudeLogin() {
        pendingLogin = nil
        claudeLoginPending = false
    }

    /// Reads the `code#state` string the browser page shows from the clipboard.
    func finishClaudeLogin() async {
        guard let pending = pendingLogin else { return }
        guard let pasted = NSPasteboard.general.string(forType: .string), pasted.contains("#") else {
            states[.claude]?.error = "Copia prima il codice dal browser"
            return
        }
        do {
            try await ClaudeAuth.completeLogin(pasted: pasted, pending: pending)
            cancelClaudeLogin()
            claudeSignedInHere = true
            await refresh(force: true)
        } catch {
            states[.claude]?.error = "Accesso non riuscito · " + ((error as? LocalizedError)?.errorDescription ?? "riprova")
        }
    }

    func signOutOfClaude() {
        ClaudeAuth.signOut()
        claudeSignedInHere = false
        Task { await refresh(force: true) }
    }

    // MARK: Menu bar label

    /// The label with each glyph grown by `growth` (0 at rest, 1 working); a service missing from
    /// it is drawn as its activity says. A glyph keeps its colour while it's still bigger than at
    /// rest, so it shrinks back before turning plain.
    func statusLabel(growth: [ProviderID: CGFloat]) -> Icons.StatusLabel {
        let now = Date()
        let parts = settings.visibleProviders.map { id -> Icons.StatusPart in
            let logo = id.glyph
            let number = menuBarNumber(id, now: now)
            let coloured = activity.isWorking(id) || (growth[id] ?? 0) > 0
            // From 90% (and while used up) a working glyph takes the number's red, so it stands out.
            let glyph = coloured ? (number.urgent ? .systemRed : glyphColor(id)) : nil
            let artwork = coloured && !number.urgent ? glyphArtwork(id) : nil
            return Icons.StatusPart(logo: logo, text: number.text, alert: number.alert, glyph: glyph,
                                    glyphArtwork: artwork, growth: growth[id], tint: growth[id].map { min(max($0, 0), 1) })
        }
        return Icons.statusLabel(parts)
    }

    /// What the menu bar shows next to a service and in which colour: orange from 80%, red from
    /// 90% (`urgent`), and when a limit is used up, the time until it frees up rather than "100%".
    private func menuBarNumber(_ id: ProviderID, now: Date) -> (text: String, alert: NSColor?, urgent: Bool) {
        if let until = blockedUntil(id, now: now), let left = Format.shortCountdown(until, now: now) {
            return (left, .systemRed, true)
        }
        guard let value = menuBarValue(id, now: now) else { return ("–", nil, false) }
        let text = "\(Int(value.rounded()))%"
        if value >= 90 { return (text, .systemRed, true) }
        return (text, value >= 80 ? .systemOrange : nil, false)
    }

    /// While a service works its glyph takes its colour: Claude's orange, and for Codex the real
    /// cloud of its icon (see glyphArtwork), or its violet when the Codex app isn't installed.
    private func glyphColor(_ id: ProviderID) -> NSColor? {
        switch id {
        case .claude: return Icons.claudeOrange
        case .codex: return Icons.codexCloudArtwork == nil ? Icons.codexViolet : nil
        case .opencode: return Icons.openCodePink
        }
    }

    private func glyphArtwork(_ id: ProviderID) -> NSImage? {
        id == .codex ? Icons.codexCloudArtwork : nil
    }

    /// When a service can be used again, while one of its limits is used up: the later reset
    /// if both are.
    func blockedUntil(_ id: ProviderID, now: Date) -> Date? {
        guard let snapshot = state(id).snapshot else { return nil }
        return [snapshot.fiveHour, snapshot.week].compactMap { $0 }
            .filter { $0.effectivePercent(at: now) >= UsageWindow.exhausted }
            .compactMap(\.resetsAt)
            .max()
    }

    /// Whether the menu bar label is counting down to a reset, and so changes by the minute.
    var showsCountdown: Bool {
        let now = Date()
        return settings.visibleProviders.contains { blockedUntil($0, now: now) != nil }
    }

    /// The percentage the menu bar shows for a service, per the "Numero mostrato" setting.
    private func menuBarValue(_ id: ProviderID, now: Date) -> Double? {
        guard let snapshot = state(id).snapshot else { return nil }
        let five = snapshot.fiveHour?.effectivePercent(at: now)
        let week = snapshot.week?.effectivePercent(at: now)
        switch settings.menuBarNumber {
        case .highest: return [five, week].compactMap { $0 }.max()
        case .fiveHour: return five ?? week
        case .week: return week ?? five
        }
    }
}
