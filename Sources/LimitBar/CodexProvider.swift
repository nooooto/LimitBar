import Foundation

/// Uses the ChatGPT login stored by the Codex CLI. Falls back to the rate-limit snapshot
/// Codex writes into its session logs when the API isn't reachable.
enum CodexProvider {
    private static var home: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    static func fetch() async throws -> ProviderSnapshot {
        do {
            return try await fetchFromAPI()
        } catch {
            // Rate limiting has to reach the store so it backs off; old logs wouldn't help anyway.
            if case ProviderError.rateLimited = error { throw error }
            if var snapshot = try? fetchFromSessionLogs() {
                if case ProviderError.expired = error {
                    snapshot.note = L("From the last session · open Codex to refresh")
                } else {
                    snapshot.note = L("From the last Codex session")
                }
                return snapshot
            }
            throw error
        }
    }

    // MARK: API

    static func fetchFromAPI() async throws -> ProviderSnapshot {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ProviderError.notSignedIn(L("Not signed in · run codex login")) }
        guard let tokens = auth["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String
        else { throw ProviderError.notSignedIn(L("API key login · no plan limits")) }

        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.timeoutInterval = 15
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let account = tokens["account_id"] as? String {
            req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")

        let (body, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderError.expired(L("Sign-in expired · open Codex"))
        }
        if http.statusCode == 429 { throw ProviderError.rateLimited(retryAfter: Parse.retryAfter(http)) }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let limits = json["rate_limit"] as? [String: Any]
        else { throw ProviderError.badResponse }

        func window(_ any: Any?) -> UsageWindow? {
            guard let d = any as? [String: Any], let used = Parse.number(d["used_percent"]) else { return nil }
            let reset = Parse.number(d["reset_at"]).map { Date(timeIntervalSince1970: $0) }
                ?? Parse.number(d["reset_after_seconds"]).map { Date().addingTimeInterval($0) }
            let minutes = Parse.number(d["limit_window_seconds"]).map { Int($0 / 60) }
            return UsageWindow(usedPercent: used, resetsAt: reset, windowMinutes: minutes)
        }

        var snapshot = ProviderSnapshot(
            plan: (json["plan_type"] as? String).map(planName),
            updatedAt: Date(),
            source: "api"
        )
        assign([window(limits["primary_window"]), window(limits["secondary_window"])], to: &snapshot)
        snapshot.note = creditsNote(json["credits"])
        return snapshot
    }

    // MARK: Session logs

    private static func fetchFromSessionLogs() throws -> ProviderSnapshot {
        let sessions = home.appendingPathComponent("sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: sessions, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { throw ProviderError.badResponse }

        var files: [(url: URL, date: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            files.append((url, date))
        }

        for file in files.sorted(by: { $0.date > $1.date }).prefix(5) {
            guard let text = tail(of: file.url) else { continue }
            for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      let limits = payload["rate_limits"] as? [String: Any]
                else { continue }
                let stamp = (obj["timestamp"] as? String).flatMap(Parse.isoDate) ?? file.date

                func window(_ any: Any?) -> UsageWindow? {
                    guard let d = any as? [String: Any], let used = Parse.number(d["used_percent"]) else { return nil }
                    let reset = Parse.number(d["resets_at"]).map { Date(timeIntervalSince1970: $0) }
                        ?? Parse.number(d["resets_in_seconds"]).map { stamp.addingTimeInterval($0) }
                    let minutes = Parse.number(d["window_minutes"]).map { Int($0) }
                    return UsageWindow(usedPercent: used, resetsAt: reset, windowMinutes: minutes)
                }

                var snapshot = ProviderSnapshot(
                    plan: (limits["plan_type"] as? String).map(planName),
                    updatedAt: stamp,
                    source: "logs"
                )
                assign([window(limits["primary"]), window(limits["secondary"])], to: &snapshot)
                return snapshot
            }
        }
        throw ProviderError.badResponse
    }

    // MARK: Helpers

    /// The last part of a session log: the newest rate limits are near the end, and whole logs
    /// can run to megabytes. The first, probably cut, line is dropped.
    static func tail(of url: URL, bytes: UInt64 = 1 << 20) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > bytes ? size - bytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard start > 0, let firstBreak = text.firstIndex(of: "\n") else { return text }
        return String(text[text.index(after: firstBreak)...])
    }

    /// Windows are placed by their length rather than by primary/secondary order.
    private static func assign(_ windows: [UsageWindow?], to snapshot: inout ProviderSnapshot) {
        for (index, window) in windows.enumerated() {
            guard let window else { continue }
            let isShort = window.windowMinutes.map { $0 <= 24 * 60 } ?? (index == 0)
            if isShort { snapshot.fiveHour = window } else { snapshot.week = window }
        }
    }

    private static func creditsNote(_ any: Any?) -> String? {
        guard let credits = any as? [String: Any], credits["has_credits"] as? Bool == true else { return nil }
        if credits["unlimited"] as? Bool == true { return "Crediti illimitati" }
        guard let balance = Parse.number(credits["balance"]), balance > 0 else { return nil }
        return L("%d credits available", Int(balance))
    }

    /// Just the tier ("Free", "Plus", "Pro", …): next to "Codex", "ChatGPT" would only repeat itself.
    private static func planName(_ raw: String) -> String {
        Parse.capitalizedPlan(raw)
    }
}
