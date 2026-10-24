import CoreServices
import Foundation

/// Tells whether Codex is working, from the session logs it writes live in ~/.codex/sessions
/// (desktop app and CLI alike): a turn starts with a `task_started` event and ends with
/// `task_complete` or `turn_aborted`. No Codex configuration is involved.
///
/// FSEvents only reports new session files: Codex keeps a log open and appends to it, and those
/// appends produce no FSEvents. So each recent log also gets its own kqueue watcher, which does
/// see every write.
final class CodexActivityMonitor {
    private static let sessions = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")
    /// A log untouched this long belongs to a turn that ended without saying so (e.g. a crash).
    private static let stale: TimeInterval = 600
    /// With neither event in a log's tail (a long turn), recent writes mean it's still going.
    private static let recentWrite: TimeInterval = 120

    private var stream: FSEventStreamRef?
    private var fileWatchers: [String: DispatchSourceFileSystemObject] = [:]
    /// Logs written to in this window are watched for appends; older ones are done.
    private static let watchedAge: TimeInterval = 86400
    private var pending = false
    private let onChange: () -> Void
    private let folder: URL

    init(onChange: @escaping () -> Void, folder: URL = sessions) {
        self.onChange = onChange
        self.folder = folder
    }

    deinit {
        fileWatchers.values.forEach { $0.cancel() }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    func start() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<CodexActivityMonitor>.fromOpaque(info).takeUnretainedValue()
            monitor.watchRecentLogs()  // a new session or day folder may have appeared
            monitor.changed()
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
        watchRecentLogs()
    }

    /// Keeps a write watcher on each log of today and yesterday touched in the last day.
    private func watchRecentLogs(now: Date = Date()) {
        let fm = FileManager.default
        var recent = Set<String>()
        for dayFolder in Self.dayFolders(in: folder, around: now) {
            let files = (try? fm.contentsOfDirectory(at: dayFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if now.timeIntervalSince(modified) < Self.watchedAge { recent.insert(file.path) }
            }
        }
        for (path, watcher) in fileWatchers where !recent.contains(path) {
            watcher.cancel()
            fileWatchers[path] = nil
        }
        for path in recent where fileWatchers[path] == nil {
            fileWatchers[path] = FileWatch.start(URL(fileURLWithPath: path), events: [.write, .extend, .delete, .rename]) {
                [weak self] in self?.changed()
            }
        }
    }

    /// Today's and yesterday's folders cover any turn still in progress, even past midnight.
    private static func dayFolders(in root: URL, around now: Date) -> [URL] {
        let calendar = Calendar.current
        return [now, now.addingTimeInterval(-86400)].map { day in
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            return root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
        }
    }

    /// Codex writes its log many times a second while streaming. The first change is looked at
    /// right away (so a new turn shows at once); the rest of a burst gets one more look after it.
    private func changed() {
        guard !pending else { return }
        pending = true
        onChange()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.pending = false
            self?.onChange()
        }
    }

    /// The latest turn, in the most recently written log: whether it completed (rather than being
    /// interrupted or still going), and the folder it worked in.
    static func lastTurn(now: Date = Date(), sessionsFolder: URL = sessions) -> (completed: Bool, folder: String?)? {
        let fm = FileManager.default
        let logs = dayFolders(in: sessionsFolder, around: now).flatMap { folder in
            ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.pathExtension == "jsonl" }
        }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        guard let latest = logs.max(by: { modified($0) < modified($1) }),
              let tail = CodexProvider.tail(of: latest, bytes: 64 * 1024) else { return nil }
        func last(_ event: String) -> String.Index? { tail.range(of: "\"\(event)\"", options: .backwards)?.lowerBound }
        let completed = last("task_complete").map { done in
            [last("task_started"), last("turn_aborted")].allSatisfy { other in other.map { $0 < done } ?? true }
        } ?? false
        // The folder is in each turn's turn_context line, as "cwd":"<JSON string>".
        let folder = tail.range(of: "\"cwd\":", options: .backwards).flatMap { key -> String? in
            let rest = String(tail[key.upperBound...].prefix(4096))
            guard let value = rest.range(of: #""(?:[^"\\]|\\.)*""#, options: [.regularExpression, .anchored]) else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(rest[value].utf8), options: .fragmentsAllowed)) as? String
        }
        return (completed, folder)
    }

    static func isWorking(now: Date = Date(), sessionsFolder: URL = sessions) -> Bool {
        workingSessions(now: now, sessionsFolder: sessionsFolder) > 0
    }

    /// How many session logs are in the middle of a turn.
    static func workingSessions(now: Date = Date(), sessionsFolder: URL = sessions) -> Int {
        let fm = FileManager.default
        var working = 0
        for folder in dayFolders(in: sessionsFolder, around: now) {
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      now.timeIntervalSince(modified) < stale,
                      let tail = CodexProvider.tail(of: file, bytes: 16 * 1024) else { continue }
                let started = tail.range(of: "\"task_started\"", options: .backwards)?.lowerBound
                let ended = [tail.range(of: "\"task_complete\"", options: .backwards),
                             tail.range(of: "\"turn_aborted\"", options: .backwards)]
                    .compactMap { $0?.lowerBound }.max()
                switch (started, ended) {
                case let (start?, end?) where start > end: working += 1
                case (.some, nil): working += 1
                case (nil, nil) where now.timeIntervalSince(modified) < recentWrite: working += 1
                default: continue
                }
            }
        }
        return working
    }
}
