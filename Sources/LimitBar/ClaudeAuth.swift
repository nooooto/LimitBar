import AppKit
import CryptoKit

/// LimitBar's own Claude login, for setups where Claude Code runs inside the desktop app and
/// its token isn't reachable. Same OAuth flow as `claude /login`: the browser shows a code the
/// user copies back. Tokens live in the login keychain and are refreshed automatically.
enum ClaudeAuth {
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let authorizeURL = "https://claude.com/cai/oauth/authorize"
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let redirectURI = "https://platform.claude.com/oauth/code/callback"
    private static let scope = "user:profile"
    private static let keychainService = "LimitBar Claude"

    struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var plan: String?
    }

    struct PendingLogin {
        let verifier: String
        let state: String
    }

    static func beginLogin() -> PendingLogin {
        let pending = PendingLogin(verifier: randomToken(), state: randomToken())
        let challenge = base64URL(Data(SHA256.hash(data: Data(pending.verifier.utf8))))
        var components = URLComponents(string: authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pending.state),
        ]
        NSWorkspace.shared.open(components.url!)
        return pending
    }

    /// `pasted` is what the callback page shows: `code#state`.
    static func completeLogin(pasted: String, pending: PendingLogin) async throws {
        let parts = pasted.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#", maxSplits: 1)
        guard let code = parts.first, !code.isEmpty else { throw ProviderError.badResponse }
        var tokens = try await tokenRequest([
            "grant_type": "authorization_code",
            "code": String(code),
            "state": parts.count > 1 ? String(parts[1]) : pending.state,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": pending.verifier,
        ], previous: nil)
        tokens.plan = await fetchPlan(accessToken: tokens.accessToken)
        save(tokens)
    }

    static var isSignedIn: Bool { load() != nil }

    static func signOut() {
        SecurityCLI.delete(service: keychainService)
        memory.set(nil)
    }

    /// Next time, read the keychain again: the server just turned the remembered token down.
    static func forgetRememberedTokens() {
        memory.set(nil)
    }

    /// Returns a usable access token, refreshing it first when it's about to expire.
    static func validTokens() async throws -> Tokens? {
        guard var tokens = load() else { return nil }
        if let expiresAt = tokens.expiresAt, expiresAt.addingTimeInterval(-120) < Date() {
            guard let refresh = tokens.refreshToken else { throw ProviderError.expired("Accesso scaduto") }
            do {
                tokens = try await tokenRequest(
                    ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID],
                    previous: tokens
                )
            } catch ProviderError.http(let code) where (400..<500).contains(code) {
                throw ProviderError.expired("Accesso scaduto")
            }
            save(tokens)
        }
        return tokens
    }

    // MARK: Requests

    private static func tokenRequest(_ body: [String: String], previous: Tokens?) async throws -> Tokens {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String
        else { throw ProviderError.badResponse }

        return Tokens(
            accessToken: access,
            refreshToken: (json["refresh_token"] as? String) ?? previous?.refreshToken,
            expiresAt: Parse.number(json["expires_in"]).map { Date().addingTimeInterval($0) },
            plan: previous?.plan
        )
    }

    private static func fetchPlan(accessToken: String) async -> String? {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        req.timeoutInterval = 15
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let org = json["organization"] as? [String: Any],
              let type = org["organization_type"] as? String
        else { return nil }
        let base = Parse.capitalizedPlan(type.replacingOccurrences(of: "claude_", with: ""))
        let tier = (org["rate_limit_tier"] as? String) ?? ""
        if tier.contains("20x") { return "\(base) 20x" }
        if tier.contains("5x") { return "\(base) 5x" }
        return base
    }

    // MARK: Storage

    /// Reading the keychain starts a `security` process, so the tokens are kept in memory after
    /// the first read; saving updates both.
    private static let memory = RememberedTokens()

    private static func load() -> Tokens? {
        if let remembered = memory.get() { return remembered }
        guard let data = SecurityCLI.read(service: keychainService) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let tokens = try? decoder.decode(Tokens.self, from: data)
        memory.set(tokens)
        return tokens
    }

    private static func save(_ tokens: Tokens) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(tokens) else { return }
        SecurityCLI.write(service: keychainService, value: String(decoding: data, as: UTF8.self))
        memory.set(tokens)
    }

    /// Fetches for different services run concurrently, so access goes through a lock.
    private final class RememberedTokens: @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: Tokens?

        func get() -> Tokens? { lock.withLock { tokens } }
        func set(_ value: Tokens?) { lock.withLock { tokens = value } }
    }

    private static func randomToken() -> String {
        base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Keychain access through `/usr/bin/security`, the same way Claude Code does it. Items created
/// this way trust the `security` tool, so rebuilding the ad-hoc signed app never re-prompts.
enum SecurityCLI {
    static func read(service: String) -> Data? {
        let (status, data) = run(["find-generic-password", "-s", service, "-w"])
        guard status == 0 else { return nil }
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Data(trimmed.utf8)
    }

    static func write(service: String, value: String) {
        _ = run(["add-generic-password", "-U", "-s", service, "-a", NSUserName(), "-w", value])
    }

    static func delete(service: String) {
        _ = run(["delete-generic-password", "-s", service])
    }

    private static func run(_ arguments: [String]) -> (Int32, Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, Data()) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
