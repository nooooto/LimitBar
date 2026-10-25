import AppKit
import UserNotifications

/// Threshold alerts (80% and 90%, once per window), a "di nuovo disponibile" alert scheduled for
/// the reset time of a window that has run out, an alert when an agent stops after a long
/// stretch of work, and a summary of last week on Monday morning.
@MainActor
enum Notifier {
    private static let thresholds: [Double] = [80, 90]

    private static var center: UNUserNotificationCenter { .current() }
    private static let defaults = UserDefaults.standard
    private static let presenter = Presenter()

    static func setUp() {
        center.delegate = presenter
        requestAuthorization()
    }

    static func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func evaluate(_ id: ProviderID, snapshot: ProviderSnapshot, settings: AppSettings) {
        let now = Date()
        for kind in WindowKind.allCases {
            guard let window = kind.window(in: snapshot) else { continue }
            let percent = window.effectivePercent(at: now)
            checkThresholds(id, kind: kind, window: window, percent: percent, enabled: settings.notifyThresholds)
            scheduleReset(id, kind: kind, window: window, percent: percent, enabled: settings.notifyResets, now: now)
        }
    }

    /// Drops pending reset alerts, e.g. after they're turned off in the settings.
    static func cancelResetAlerts() {
        let ids = ProviderID.allCases.flatMap { id in WindowKind.allCases.map { resetIdentifier(id, $0) } }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: Thresholds

    private static func checkThresholds(_ id: ProviderID, kind: WindowKind, window: UsageWindow,
                                         percent: Double, enabled: Bool) {
        let key = "notified.\(id.rawValue).\(kind.rawValue)"
        // The level already announced belongs to one window, identified by its reset minute
        // (Claude's reset times jitter by fractions of a second between readings).
        let windowStamp = window.resetsAt.map { ($0.timeIntervalSince1970 / 60).rounded() } ?? 0
        let saved = defaults.dictionary(forKey: key)
        var level = saved?["window"] as? Double == windowStamp ? saved?["level"] as? Double ?? 0 : 0

        if let crossed = thresholds.last(where: { percent >= $0 }), crossed > level {
            if enabled {
                var body = "Hai usato \(Format.percentWithArticle(percent))."
                if let resetsAt = window.resetsAt { body += " Si azzera \(Format.at(resetsAt, now: Date()))." }
                post(id: "threshold.\(id.rawValue).\(kind.rawValue)",
                     title: "\(id.title): \(Int(crossed))% del limite \(kind.limitName(window))", body: body)
            }
            level = crossed
        }
        defaults.set(["window": windowStamp, "level": level], forKey: key)
    }

    // MARK: Resets

    private static func resetIdentifier(_ id: ProviderID, _ kind: WindowKind) -> String {
        "reset.\(id.rawValue).\(kind.rawValue)"
    }

    private static func scheduleReset(_ id: ProviderID, kind: WindowKind, window: UsageWindow,
                                      percent: Double, enabled: Bool, now: Date) {
        let identifier = resetIdentifier(id, kind)
        guard enabled, percent >= UsageWindow.exhausted, let resetsAt = window.resetsAt, resetsAt > now else {
            if percent < UsageWindow.exhausted { center.removePendingNotificationRequests(withIdentifiers: [identifier]) }
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "\(id.title) è di nuovo disponibile"
        content.body = "Il limite \(kind.limitName(window)) si è azzerato."
        content.sound = .default
        // Re-adding with the same identifier replaces the pending alert, so readings can repeat this.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: resetsAt.timeIntervalSince(now), repeats: false)
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    // MARK: Agents stopping

    /// Shorter stretches end without an alert: quick answers come back while you're watching.
    static let longStretch: TimeInterval = 120

    /// Apps the agents run in. While one of them is in front you're already there, so no alert.
    private static let agentHosts: Set<String> = [
        "com.anthropic.claudefordesktop", "com.openai.codex", "com.openai.chat", "ai.opencode.desktop",
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
    ]

    /// Written by scripts/claude-activity.sh when a busy Claude Code session stops.
    private static let claudeLastStop = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LimitBar/claude-last-stop")

    /// "Claude ha finito" / "Claude ti aspetta" (waiting for a permission or an answer) /
    /// "Codex ha finito" / "OpenCode ha finito", with how long it worked and on which project.
    static func stretchEnded(_ id: ProviderID, after duration: TimeInterval, enabled: Bool) {
        guard enabled, duration >= longStretch,
              !agentHosts.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") else { return }
        var waiting = false
        let folder: String?
        switch id {
        case .claude:
            // A turn cut short gets no hook and only goes stale, much later: no alert for it.
            let modified = (try? claudeLastStop.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, Date().timeIntervalSince(modified) < 15,
                  let data = try? Data(contentsOf: claudeLastStop),
                  let stop = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            waiting = stop["event"] as? String == "Notification"
            folder = stop["cwd"] as? String
        case .codex:
            guard let turn = CodexActivityMonitor.lastTurn(), turn.completed else { return }
            folder = turn.folder
        case .opencode:
            folder = OpenCodeActivity.lastFolder()
        }
        let project = folder.flatMap { ProjectFolder.projects(for: [$0])[$0]?.name }.flatMap { $0 == ProjectFolder.other ? nil : $0 }
        let work = Format.duration(duration) + " di lavoro" + (project.map { " su \($0)" } ?? "")
        post(id: "stop.\(id.rawValue)",
             title: waiting ? "\(id.title) ti aspetta" : "\(id.title) ha finito",
             body: waiting ? "Dopo \(work), ha bisogno di una tua risposta." : "\(work).")
    }

    // MARK: Weekly summary

    /// Sent from Monday 9:00, or the first time LimitBar runs after that in the week.
    private static let summaryHour = 9

    private static var weekCalendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)  // weeks start on Monday
        calendar.timeZone = .current
        return calendar
    }

    /// Posts last week's summary once per week. On the very first run it only takes note of the
    /// week, so the first summary comes the next Monday rather than mid-week.
    static func weeklySummaryIfDue(costs: [String: [String: [String: Double]]], history: [ProviderID: [UsageSample]],
                                   providers: [ProviderID], enabled: Bool, now: Date = Date()) {
        guard let week = weekCalendar.dateInterval(of: .weekOfYear, for: now) else { return }
        let stamp = CostLedger.dayKey(week.start)
        let key = "weekly.sentFor"
        guard let sent = defaults.string(forKey: key) else {
            defaults.set(stamp, forKey: key)
            return
        }
        guard sent != stamp, now >= week.start.addingTimeInterval(TimeInterval(summaryHour * 3600)) else { return }
        defaults.set(stamp, forKey: key)
        guard enabled, let summary = weeklySummary(costs: costs, history: history, providers: providers,
                                                   weekStart: week.start) else { return }
        post(id: "weekly", title: summary.title, body: summary.body)
    }

    /// "52 € di lavoro a prezzi API, soprattutto su LimitBar (31 €). Picco del limite
    /// settimanale: Claude 71%, OpenCode 10%." for the week before `weekStart`; nil if there was no work.
    static func weeklySummary(costs: [String: [String: [String: Double]]], history: [ProviderID: [UsageSample]],
                              providers: [ProviderID], weekStart: Date) -> (title: String, body: String)? {
        let calendar = weekCalendar
        guard let start = calendar.date(byAdding: .day, value: -7, to: weekStart) else { return nil }
        let days = Set((0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }.map(CostLedger.dayKey))

        var projects: [String: Double] = [:]
        for id in providers {
            for (day, costs) in costs[id.rawValue] ?? [:] where days.contains(day) {
                projects.merge(costs, uniquingKeysWith: +)
            }
        }
        let total = projects.values.reduce(0, +)
        guard total > 0 else { return nil }

        var body = "\(Format.wholeEuros(fromDollars: total)) di lavoro a prezzi API"
        if let top = projects.filter({ $0.key != ProjectFolder.other }).max(by: { $0.value < $1.value }) {
            body += ", soprattutto su \(top.key) (\(Format.wholeEuros(fromDollars: top.value)))"
        }
        body += "."
        let peaks = providers.compactMap { id -> String? in
            let week = (history[id] ?? []).filter { $0.date >= start && $0.date < weekStart }.compactMap(\.week)
            return week.max().map { "\(id.title) \(Int($0.rounded()))%" }
        }
        if !peaks.isEmpty { body += " Picco del limite settimanale: \(peaks.joined(separator: ", "))." }
        return ("La settimana scorsa", body)
    }

    // MARK: Helpers

    private static func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Shows banners even while the settings window has made LimitBar the active app.
    private final class Presenter: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .sound])
        }
    }
}
