import Foundation

/// Reads the OAuth token Claude Code stores in the login keychain and asks the same
/// usage endpoint that powers `/usage` inside Claude Code.
enum ClaudeProvider {
    private struct Credentials {
        let token: String
        let expiresAt: Date?
        let plan: String?
    }

    static func fetch() async throws -> ProviderSnapshot {
        let creds: Credentials
        if let own = try await ClaudeAuth.validTokens() {
            creds = Credentials(token: own.accessToken, expiresAt: nil, plan: own.plan)
        } else {
            creds = try loadCLICredentials()
            if let exp = creds.expiresAt, exp < Date() {
                throw ProviderError.expired("Accesso a Claude Code scaduto")
            }
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.timeoutInterval = 15
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("LimitBar/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
        if ProcessInfo.processInfo.environment["LIMITBAR_DEBUG"] != nil {
            // Never includes the request's Authorization header.
            let headers = http.allHeaderFields
                .map { "\($0.key): \($0.value)" }
                .filter { $0.lowercased().contains("ratelimit") || $0.lowercased().hasPrefix("retry") }
            print("claude usage HTTP \(http.statusCode)\n\(headers.joined(separator: "\n"))")
            print(String(decoding: data.prefix(600), as: UTF8.self))
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            ClaudeAuth.forgetRememberedTokens()
            throw ProviderError.expired("Accesso scaduto")
        }
        if http.statusCode == 429 { throw ProviderError.rateLimited(retryAfter: Parse.retryAfter(http)) }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.badResponse
        }
        return snapshot(usage: json, plan: creds.plan, at: Date())
    }

    /// The windows' lengths, which Anthropic doesn't send; the pace (see Pace) needs them.
    static let fiveHourMinutes = 5 * 60
    static let weekMinutes = 7 * 24 * 60

    /// The usage endpoint's reply as a snapshot.
    static func snapshot(usage json: [String: Any], plan: String?, at date: Date) -> ProviderSnapshot {
        func window(_ any: Any?, minutes: Int) -> UsageWindow? {
            guard let d = any as? [String: Any], let used = Parse.number(d["utilization"]) else { return nil }
            return UsageWindow(usedPercent: used, resetsAt: (d["resets_at"] as? String).flatMap(Parse.isoDate), windowMinutes: minutes)
        }

        // Model-specific weekly buckets (seven_day_opus, seven_day_sonnet, ...) show up as extra rows.
        var extras: [ExtraLimit] = []
        for key in json.keys.sorted() where key.hasPrefix("seven_day_") && key != "seven_day_oauth_apps" {
            guard let w = window(json[key], minutes: weekMinutes) else { continue }
            let name = Parse.capitalizedPlan(String(key.dropFirst("seven_day_".count)))
            extras.append(ExtraLimit(label: "Settimana \(name)", window: w))
        }
        if let extra = json["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
           let used = Parse.number(extra["utilization"]) {
            extras.append(ExtraLimit(label: "Uso extra", window: UsageWindow(usedPercent: used)))
        }

        return ProviderSnapshot(
            plan: plan,
            fiveHour: window(json["five_hour"], minutes: fiveHourMinutes),
            week: window(json["seven_day"], minutes: weekMinutes),
            extras: extras,
            updatedAt: date,
            source: "api"
        )
    }

    /// Where scripts/claude-statusline.sh saves the limits Claude Code passes to its status line.
    static let statusFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LimitBar/claude-status.json")

    /// The limits as last seen by Claude Code in a terminal, without asking the server.
    /// A window Claude Code leaves out has already reset, so `previous` fills it in
    /// (its `resetsAt` has passed, so it reads as 0%).
    static func localSnapshot(previous: ProviderSnapshot?) -> ProviderSnapshot? {
        guard let data = try? Data(contentsOf: statusFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = json["rate_limits"] as? [String: Any],
              let updated = Parse.number(json["updated_at"])
        else { return nil }

        func window(_ any: Any?, minutes: Int) -> UsageWindow? {
            guard let d = any as? [String: Any], let used = Parse.number(d["used_percentage"]) else { return nil }
            return UsageWindow(usedPercent: used, resetsAt: Parse.number(d["resets_at"]).map(Date.init(timeIntervalSince1970:)),
                               windowMinutes: minutes)
        }
        let fiveHour = window(limits["five_hour"], minutes: fiveHourMinutes), week = window(limits["seven_day"], minutes: weekMinutes)
        guard fiveHour != nil || week != nil else { return nil }

        return ProviderSnapshot(
            plan: previous?.plan,
            fiveHour: fiveHour ?? previous?.fiveHour,
            week: week ?? previous?.week,
            extras: previous?.extras ?? [],
            updatedAt: Date(timeIntervalSince1970: updated),
            source: "statusline"
        )
    }

    /// Credentials written by the standalone Claude Code CLI (`claude /login`).
    private static func loadCLICredentials() throws -> Credentials {
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let raw = SecurityCLI.read(service: "Claude Code-credentials") ?? (try? Data(contentsOf: fileURL)),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { throw ProviderError.notSignedIn("Accesso non effettuato") }

        let expiresAt = Parse.number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Credentials(token: token, expiresAt: expiresAt, plan: planName(oauth))
    }

    private static func planName(_ oauth: [String: Any]) -> String? {
        guard let sub = oauth["subscriptionType"] as? String else { return nil }
        let tier = (oauth["rateLimitTier"] as? String) ?? ""
        let base = Parse.capitalizedPlan(sub)
        if tier.contains("20x") { return "\(base) 20x" }
        if tier.contains("5x") { return "\(base) 5x" }
        return base
    }
}
