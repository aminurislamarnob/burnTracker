import Foundation

/// GitHub Copilot usage. Reads a local GitHub OAuth token (Copilot CLI Keychain,
/// editor config, or `gh`) and calls `GET /copilot_internal/user` — the same
/// endpoint the Copilot clients use (ported from openusage / CodexBar).
enum CopilotService {
    private static let usageURL = URL(string: "https://api.github.com/copilot_internal/user")!
    private static let userURL = URL(string: "https://api.github.com/user")!
    private static let copilotKeychainService = "github-copilot-app"
    private static let editorAppsRelative = ".config/github-copilot/apps.json"
    private static let editorHostsRelative = ".config/github-copilot/hosts.json"
    private static let ghHostsRelative = ".config/gh/hosts.yml"

    enum FetchOutcome: Equatable {
        case success(email: String?, quota: CopilotQuota)
        case notLoggedIn
        case unauthorized
        case failed
    }

    static var copilotHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot")
    }

    /// True when the Copilot CLI home exists (even before a successful login probe).
    static var hasCopilotHome: Bool {
        FileManager.default.fileExists(atPath: copilotHome.path)
    }

    static var hasCredentials: Bool {
        // Probe without Keychain UI — auto-link / has-check must never sheet.
        loadToken(allowKeychainPrompt: false) != nil || hasCopilotHome
    }

    static func login() -> (email: String, token: String)? {
        // Files or silent Keychain only. Interactive unlock happens on refresh.
        if let token = loadToken(allowKeychainPrompt: false) {
            return (cachedLoginHint(for: token) ?? "GitHub Copilot", "local-creds")
        }
        guard hasCopilotHome else { return nil }
        return ("GitHub Copilot", "local-creds")
    }

    static func fetchQuota(allowKeychainPrompt: Bool = false) async -> FetchOutcome {
        guard let token = loadToken(allowKeychainPrompt: allowKeychainPrompt) else { return .notLoggedIn }

        guard let response = await usageGET(token: token) else { return .failed }
        if response.status == 401 || response.status == 403 { return .unauthorized }
        guard (200..<300).contains(response.status) else { return .failed }
        guard let quota = decodeUsage(response.data) else { return .failed }

        let login = await fetchGitHubLogin(token: token) ?? quotaLogin(from: response.data)
        return .success(email: login, quota: quota)
    }

    // MARK: - Token discovery

    /// Prompt-free files first. Keychain only if needed — and only the Copilot
    /// CLI item (never also `gh:github.com`, which was a second password sheet).
    /// Interactive Keychain is opt-in (manual card Refresh) so launch never stacks
    /// a Copilot sheet on top of Cursor Safe Storage.
    static func loadToken(allowKeychainPrompt: Bool = false) -> String? {
        loadFromEditorConfig()
            ?? loadFromGhConfig()
            ?? loadFromCopilotKeychain(allowInteractive: allowKeychainPrompt)
    }

    private static func loadFromCopilotKeychain(allowInteractive: Bool) -> String? {
        guard let raw = KeychainAccess.readGenericPassword(
            service: copilotKeychainService,
            accounts: [nil],
            allowInteractive: allowInteractive) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func loadFromEditorConfig() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for relative in [editorAppsRelative, editorHostsRelative] {
            let url = home.appendingPathComponent(relative)
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let token = oauthToken(fromEditorJSON: text) else { continue }
            return token
        }
        return nil
    }

    private static func loadFromGhConfig() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(ghHostsRelative)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let token = yamlValue(text, key: "oauth_token") else { return nil }
        return token
    }

    private static func cachedLoginHint(for token: String) -> String? {
        // Best-effort synchronous hint for Settings / auto-link; live refresh replaces it.
        if let login = yamlValue(
            (try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(ghHostsRelative), encoding: .utf8)) ?? "",
            key: "user") {
            return login
        }
        _ = token
        return nil
    }

    // MARK: - HTTP

    private struct HTTPResult {
        var status: Int
        var data: Data
    }

    private static func usageGET(token: String) async -> HTTPResult? {
        var req = URLRequest(url: usageURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        // `/copilot_internal/user` expects the `token` scheme (not Bearer).
        req.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        req.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        req.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        req.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        return HTTPResult(status: http.statusCode, data: data)
    }

    private static func fetchGitHubLogin(token: String) async -> String? {
        var req = URLRequest(url: userURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("BurnTracker", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = (json["login"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !login.isEmpty else { return nil }
        return login
    }

    // MARK: - Decode

    private static func decodeUsage(_ data: Data) -> CopilotQuota? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return mapUsage(body: body)
    }

    private static func quotaLogin(from data: Data) -> String? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = (body["login"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !login.isEmpty else { return nil }
        return login
    }

    /// Mirrors openusage's `CopilotUsageMapper`: Credits from `premium_interactions`,
    /// Extra Usage when overage is enabled, Chat/Completions only when finite.
    static func mapUsage(body: [String: Any]) -> CopilotQuota? {
        let plan = planLabel(body["copilot_plan"])
        let resetsAt = parseResetDate(body["quota_reset_date_utc"])
            ?? parseResetDate(body["quota_reset_date"])
            ?? parseResetDate(body["limited_user_reset_date"])

        let snapshots = body["quota_snapshots"] as? [String: Any]
        let premium = snapshots?["premium_interactions"] as? [String: Any]

        var creditsPct: Int?
        var entitlement: Double?
        var remaining: Double?
        var overage: Double?

        if let line = snapshotUsedPercent(premium) {
            creditsPct = line.percent
            entitlement = line.entitlement
            remaining = line.remaining
        }
        if let premium, boolValue(premium["overage_permitted"]) == true {
            overage = max(0, asDouble(premium["overage_count"]) ?? 0)
        }

        let chatPct = snapshotUsedPercent(snapshots?["chat"] as? [String: Any])?.percent
        let completionsPct = snapshotUsedPercent(snapshots?["completions"] as? [String: Any])?.percent

        // Legacy free-tier shape when snapshots produced nothing.
        var legacyChat: Int?
        var legacyCompletions: Int?
        if creditsPct == nil, chatPct == nil, completionsPct == nil {
            let limited = body["limited_user_quotas"] as? [String: Any]
            let monthly = body["monthly_quotas"] as? [String: Any]
            legacyChat = limitedUsedPercent(remaining: limited?["chat"], total: monthly?["chat"])
            legacyCompletions = limitedUsedPercent(remaining: limited?["completions"], total: monthly?["completions"])
        }

        let hasMeter = creditsPct != nil || chatPct != nil || completionsPct != nil
            || legacyChat != nil || legacyCompletions != nil || overage != nil

        if !hasMeter {
            if boolValue(body["token_based_billing"]) == true {
                return CopilotQuota(
                    planName: plan,
                    creditsUsedPct: nil,
                    creditsEntitlement: nil,
                    creditsRemaining: nil,
                    overageCount: nil,
                    chatUsedPct: nil,
                    completionsUsedPct: nil,
                    resetAt: resetsAt,
                    isOrgManagedSeat: true)
            }
            return nil
        }

        return CopilotQuota(
            planName: plan,
            creditsUsedPct: creditsPct,
            creditsEntitlement: entitlement,
            creditsRemaining: remaining,
            overageCount: overage,
            chatUsedPct: chatPct ?? legacyChat,
            completionsUsedPct: completionsPct ?? legacyCompletions,
            resetAt: resetsAt,
            isOrgManagedSeat: false)
    }

    private struct SnapshotLine {
        var percent: Int
        var entitlement: Double?
        var remaining: Double?
    }

    private static func snapshotUsedPercent(_ snapshot: [String: Any]?) -> SnapshotLine? {
        guard let snapshot else { return nil }
        let entitlement = asDouble(snapshot["entitlement"])
        let remaining = asDouble(snapshot["remaining"]) ?? asDouble(snapshot["quota_remaining"])

        if boolValue(snapshot["unlimited"]) == true || entitlement == -1 || remaining == -1 {
            return nil
        }
        if entitlement == 0 { return nil }

        let usedPercent: Double
        if let percentRemaining = asDouble(snapshot["percent_remaining"]) {
            usedPercent = clampPercent(100 - percentRemaining)
        } else if let entitlement, entitlement > 0, let remaining {
            usedPercent = clampPercent(100 - (remaining / entitlement) * 100)
        } else {
            return nil
        }

        return SnapshotLine(
            percent: Int(usedPercent.rounded()),
            entitlement: entitlement,
            remaining: remaining)
    }

    private static func limitedUsedPercent(remaining: Any?, total: Any?) -> Int? {
        guard let total = asDouble(total), total > 0,
              let remaining = asDouble(remaining) else { return nil }
        let used = max(0, total - remaining)
        return Int(clampPercent((used / total) * 100).rounded())
    }

    // MARK: - Parsing helpers

    static func oauthToken(fromEditorJSON text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        func token(in value: Any?) -> String? {
            guard let dict = value as? [String: Any],
                  let token = (dict["oauth_token"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else { return nil }
            return token
        }

        for (key, value) in object where key == "github.com" || key.hasPrefix("github.com:") {
            if let token = token(in: value) { return token }
        }
        return nil
    }

    static func yamlValue(_ text: String, key: String, host: String = "github.com") -> String? {
        let prefix = key + ":"
        let hostHeader = host + ":"
        var inHost = false
        for line in text.split(whereSeparator: \.isNewline) {
            if let first = line.first, !first.isWhitespace {
                inHost = line.trimmingCharacters(in: .whitespaces).hasPrefix(hostHeader)
                continue
            }
            guard inHost else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return unquoted.isEmpty ? nil : unquoted
        }
        return nil
    }

    static func unwrapGoKeyring(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "go-keyring-base64:"
        if text.hasPrefix(prefix) {
            let encoded = String(text.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = Data(base64Encoded: encoded),
                  let decoded = String(data: data, encoding: .utf8) else { return nil }
            text = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    private static func planLabel(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { part -> String in
                let s = String(part)
                guard let first = s.first else { return s }
                return first.uppercased() + s.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    private static func parseResetDate(_ value: Any?) -> Date? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if let d = TimeFormat.parseDate(raw) { return d }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }

    private static func asDouble(_ value: Any?) -> Double? {
        CliQuotaSupport.asDouble(value)
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = asDouble(value) { return n != 0 }
        if let s = value as? String {
            switch s.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    private static func clampPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }

}
