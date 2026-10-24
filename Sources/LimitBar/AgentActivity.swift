import Foundation

/// Whether Claude Code, Codex and OpenCode are working right now, which colours and enlarges
/// their glyphs in the menu bar.
///
/// - Claude: Claude Code hooks run scripts/claude-activity.sh, which keeps one file per busy
///   session in ~/Library/Application Support/LimitBar/claude-activity.
/// - Codex: its live session logs, read by CodexActivityMonitor.
/// - OpenCode: replies it has started and not finished, in its database (OpenCodeActivity).
@MainActor
final class AgentActivity: ObservableObject {
    /// How many sessions of each agent are working right now.
    @Published private(set) var claudeSessions = 0
    @Published private(set) var codexSessions = 0
    @Published private(set) var openCodeSessions = 0
    /// Called when an agent stops working, with how long it had been at it.
    var onStretchEnded: ((ProviderID, TimeInterval) -> Void)?
    /// When each agent went from idle to working; a stretch lasts while any of its sessions works.
    private var workingSince: [ProviderID: Date] = [:]

    private static let claudeFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LimitBar/claude-activity")
    /// A session file this old is a turn that ended without a Stop hook (e.g. interrupted).
    /// Tool calls refresh it, so only a very long stretch without one would hit this.
    private static let claudeStale: TimeInterval = 600

    private var claudeWatcher: DispatchSourceFileSystemObject?
    private var claudeRecheck: Timer?
    private var codexMonitor: CodexActivityMonitor?
    private var codexRecheck: Timer?
    /// OpenCode writes its database's WAL file with every bit of a reply; the folder shows the
    /// WAL file coming and going.
    private var openCodeFolderWatcher: DispatchSourceFileSystemObject?
    private var openCodeFileWatcher: DispatchSourceFileSystemObject?
    private var openCodeRecheck: Timer?
    private var openCodePending = false

    init() {
        try? FileManager.default.createDirectory(at: Self.claudeFolder, withIntermediateDirectories: true)
        claudeWatcher = FileWatch.start(Self.claudeFolder) { [weak self] in
            MainActor.assumeIsolated { self?.updateClaude() }
        }
        if ProviderID.codex.isActive {
            let monitor = CodexActivityMonitor { [weak self] in
                MainActor.assumeIsolated { self?.updateCodex() }
            }
            monitor.start()
            codexMonitor = monitor
        }
        openCodeFolderWatcher = FileWatch.start(OpenCodeProvider.folder) { [weak self] in
            MainActor.assumeIsolated { self?.openCodeChanged() }
        }
        updateClaude()
        if ProviderID.codex.isActive { updateCodex() }
        updateOpenCode()
    }

    func sessions(_ id: ProviderID) -> Int {
        switch id {
        case .claude: return claudeSessions
        case .codex: return codexSessions
        case .opencode: return openCodeSessions
        }
    }

    func isWorking(_ id: ProviderID) -> Bool { sessions(id) > 0 }

    /// Each fresh session file is a Claude session at work.
    private func updateClaude() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.claudeFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let cutoff = Date().addingTimeInterval(-Self.claudeStale)
        let working = files.filter { url in
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (modified ?? .distantPast) > cutoff
        }.count
        if working != claudeSessions {
            noteChange(.claude, from: claudeSessions, to: working)
            claudeSessions = working
        }
        // Nothing announces a file going stale, so look again in a minute while busy.
        claudeRecheck = recheck(working > 0, after: 60, replacing: claudeRecheck) { $0.updateClaude() }
    }

    private func updateCodex() {
        let working = CodexActivityMonitor.workingSessions()
        if working != codexSessions {
            noteChange(.codex, from: codexSessions, to: working)
            codexSessions = working
        }
        // The turn's end must show up right away, so look every second while busy.
        codexRecheck = recheck(working > 0, after: 1, replacing: codexRecheck) { $0.updateCodex() }
    }

    /// A reply streams in as many writes a second: look once now, then once after the burst.
    private func openCodeChanged() {
        guard !openCodePending else { return }
        openCodePending = true
        updateOpenCode()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.openCodePending = false
            self?.updateOpenCode()
        }
    }

    private func updateOpenCode() {
        // The WAL file is replaced after a checkpoint: watch whichever one is there now.
        openCodeFileWatcher?.cancel()
        openCodeFileWatcher = FileWatch.start(OpenCodeProvider.folder.appendingPathComponent("opencode.db-wal"),
                                              events: [.write, .extend, .delete, .rename]) { [weak self] in
            MainActor.assumeIsolated { self?.openCodeChanged() }
        }
        let working = OpenCodeActivity.workingSessions()
        if working != openCodeSessions {
            noteChange(.opencode, from: openCodeSessions, to: working)
            openCodeSessions = working
        }
        // A reply that stops without a final write only goes stale; look again while busy.
        openCodeRecheck = recheck(working > 0, after: 5, replacing: openCodeRecheck) { $0.updateOpenCode() }
    }

    private func noteChange(_ id: ProviderID, from old: Int, to new: Int) {
        if old == 0, new > 0 {
            workingSince[id] = Date()
        } else if old > 0, new == 0, let start = workingSince.removeValue(forKey: id) {
            onStretchEnded?(id, Date().timeIntervalSince(start))
        }
    }

    /// A one-shot timer that runs `action` again while `busy`, replacing the previous one.
    private func recheck(_ busy: Bool, after seconds: TimeInterval, replacing previous: Timer?,
                         _ action: @escaping (AgentActivity) -> Void) -> Timer? {
        previous?.invalidate()
        guard busy else { return nil }
        return Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
    }
}
