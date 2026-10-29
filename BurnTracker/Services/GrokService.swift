import Foundation

/// Grok CLI shared-pool usage. Reads OAuth from `~/.grok/auth.json` and calls
/// the same billing endpoints as the Grok CLI (ported from openusage).
enum GrokService {
    private static let creditsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!
    private static let refreshURL = URL(string: "https://auth.x.ai/oauth2/token")!
    private static let tokenAuthHeader = "xai-grok-cli"
    private static let defaultClientID = "b1a00492-073a-47ea-816f-4c329264a828"
    private static let weeklyPeriodType = "USAGE_PERIOD_TYPE_WEEKLY"
    private static let refreshBuffer: TimeInterval = 5 * 60

    private struct AuthEntry: Codable {
        var key: String?
        var refreshToken: String?
        var refresh: String?
        var idToken: String?
        var expiresAt: String?
        var expires: String?
        var oidcClientID: String?

        enum CodingKeys: String, CodingKey {
            case key
            case refreshToken = "refresh_token"
            case refresh
            case idToken = "id_token"
            case expiresAt = "expires_at"
            case expires
            case oidcClientID = "oidc_client_id"
        }
    }

    private struct AuthState {
        var fileText: String
        var entryKey: String
        var entry: AuthEntry
        var token: String
    }

    enum FetchOutcome: Equatable {
        case success(email: String?, quota: GrokQuota)
        case notLoggedIn
        case unauthorized
        case failed
    }

    static var authPath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/auth.json")
    }

    static var hasCredentials: Bool {
        loadCandidates().first != nil
    }

    /// True when the Grok CLI config dir exists, even before `grok login`.
    static var hasGrokHome: Bool {
        FileManager.default.fileExists(atPath: authPath.deletingLastPathComponent().path)
    }

    static func login() -> (email: String, token: String)? {
        if let state = loadCandidates().first {
            return (displayName(for: state), "local-creds")
        }
        // Still surface a card so the missing login is visible.
        guard hasGrokHome else { return nil }
        return ("Grok", "local-creds")
    }

    static func fetchQuota() async -> FetchOutcome {
        var candidates = loadCandidates()
        guard !candidates.isEmpty else { return .notLoggedIn }

        var sawExpired = false
        for var state in candidates {
            var token = state.token
            if needsRefresh(entry: state.entry, token: token) {
                if let refreshed = await refreshToken(state: &state) {
                    token = refreshed
                } else if isExpired(entry: state.entry, token: token) {
                    sawExpired = true
                    continue
                }
            }
            switch await probe(state: state, accessToken: token) {
            case .success(let quota):
                return .success(email: displayName(for: state), quota: quota)
            case .unauthorized:
                sawExpired = true
            case .failed:
                continue
            }
        }
        return sawExpired ? .unauthorized : .failed
    }

    private enum ProbeResult {
        case success(GrokQuota)
        case unauthorized
        case failed
    }

    private static func probe(state: AuthState, accessToken: String) async -> ProbeResult {
        guard let response = await fetchCreditsWithRetry(state: state, accessToken: accessToken) else {
            return .failed
        }
        guard (200..<300).contains(response.status) else {
            if response.status == 401 || response.status == 403 { return .unauthorized }
            return .failed
        }
        guard let quota = decodeCredits(response.data) else { return .failed }
        var result = quota
        if let plan = await fetchPlanName(accessToken: accessToken) {
            result.planName = plan
        }
        return .success(result)
    }

    private static func decodeCredits(_ data: Data) -> GrokQuota? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = body["config"] as? [String: Any],
              let period = config["currentPeriod"] as? [String: Any],
              let periodType = (period["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !periodType.isEmpty,
              let start = parseDate(period["start"]),
              let end = parseDate(period["end"]),
              end > start else { return nil }

        let percent: Double
        if let raw = config["creditUsagePercent"] {
            guard let number = CliQuotaSupport.asDouble(raw), number.isFinite else { return nil }
            percent = number
        } else {
            percent = 0
        }

        let onDemandCap: Double
        if let capObject = config["onDemandCap"] as? [String: Any] {
            guard let cap = CliQuotaSupport.asDouble(capObject["val"] ?? 0), cap.isFinite else { return nil }
            onDemandCap = cap
        } else {
            onDemandCap = 0
        }

        var weeklyPct: Int?
        if periodType == weeklyPeriodType {
            weeklyPct = Int(min(100, max(0, percent)).rounded())
        }
        return GrokQuota(planName: nil, weeklyUsedPct: weeklyPct, weeklyPeriodEnd: end, onDemandCap: onDemandCap)
    }

    // MARK: - Auth file

    private static func loadCandidates() -> [AuthState] {
        guard let text = try? String(contentsOf: authPath, encoding: .utf8),
              let data = text.data(using: .utf8),
              let auth = try? JSONDecoder().decode([String: AuthEntry].self, from: data) else { return [] }
        return auth.compactMap { key, entry in
            guard let token = entry.key?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
                return nil
            }
            return AuthState(fileText: text, entryKey: key, entry: entry, token: token)
        }
    }

    private static func displayName(for state: AuthState) -> String {
        if state.entryKey.contains("@") { return state.entryKey }
        if let email = CliQuotaSupport.decodeJWTPayload(state.token)?["email"] as? String, !email.isEmpty {
            return email
        }
        return "Grok"
    }

    private static func refreshToken(for entry: AuthEntry) -> String? {
        let rt = entry.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rt, !rt.isEmpty { return rt }
        let legacy = entry.refresh?.trimmingCharacters(in: .whitespacesAndNewlines)
        return legacy?.isEmpty == false ? legacy : nil
    }

    private static func clientID(entryKey: String, entry: AuthEntry) -> String {
        if let id = entry.oidcClientID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return id
        }
        let parts = entryKey.split(separator: "::", omittingEmptySubsequences: false)
        if let last = parts.last {
            let value = String(last).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return defaultClientID
    }

    private static func needsRefresh(entry: AuthEntry, token: String) -> Bool {
        if let exp = tokenExpiresAt(token), exp.timeIntervalSinceNow <= refreshBuffer { return true }
        if let exp = entryExpiresAt(entry), exp.timeIntervalSinceNow <= refreshBuffer { return true }
        return false
    }

    private static func isExpired(entry: AuthEntry, token: String) -> Bool {
        let now = Date()
        if let exp = tokenExpiresAt(token), now >= exp { return true }
        if let exp = entryExpiresAt(entry), now >= exp { return true }
        return false
    }

    private static func tokenExpiresAt(_ token: String) -> Date? {
        guard let exp = CliQuotaSupport.decodeJWTPayload(token)?["exp"],
              let seconds = CliQuotaSupport.asDouble(exp) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func entryExpiresAt(_ entry: AuthEntry) -> Date? {
        if let raw = entry.expiresAt, let d = TimeFormat.parseDate(raw) { return d }
        if let raw = entry.expires, let d = TimeFormat.parseDate(raw) { return d }
        return nil
    }

    private static func refreshToken(state: inout AuthState) async -> String? {
        guard let refresh = refreshToken(for: state.entry) else { return nil }
        let clientID = clientID(entryKey: state.entryKey, entry: state.entry)
        var req = URLRequest(url: refreshURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=refresh_token"
            + "&client_id=\(clientID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? clientID)"
            + "&refresh_token=\(refresh.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? refresh)"
        req.httpBody = Data(body.utf8)

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = (json["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !access.isEmpty else { return nil }

        state.token = access
        state.entry.key = access
        if let newRefresh = (json["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !newRefresh.isEmpty {
            state.entry.refreshToken = newRefresh
        }
        if let idToken = (json["id_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !idToken.isEmpty {
            state.entry.idToken = idToken
        }
        if let expiresIn = CliQuotaSupport.asDouble(json["expires_in"]), expiresIn > 0 {
            let expires = Date().addingTimeInterval(expiresIn)
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            state.entry.expiresAt = fmt.string(from: expires)
        }
        _ = persistAuth(state)
        return access
    }

    private static func persistAuth(_ state: AuthState) -> Bool {
        guard var root = try? JSONSerialization.jsonObject(with: Data(state.fileText.utf8)) as? [String: Any] else {
            return false
        }
        guard var entryObj = root[state.entryKey] as? [String: Any] else { return false }
        entryObj["key"] = state.entry.key
        if let rt = state.entry.refreshToken { entryObj["refresh_token"] = rt }
        if let id = state.entry.idToken { entryObj["id_token"] = id }
        if let exp = state.entry.expiresAt { entryObj["expires_at"] = exp }
        root[state.entryKey] = entryObj
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return false }
        do {
            try data.write(to: authPath, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private struct HTTPResult {
        var status: Int
        var data: Data
    }

    private static func fetchCreditsWithRetry(state: AuthState, accessToken: String) async -> HTTPResult? {
        if let first = await creditsGET(accessToken: accessToken) {
            if (200..<300).contains(first.status) { return first }
            if first.status == 401 || first.status == 403 {
                var mutable = state
                if let refreshed = await refreshToken(state: &mutable),
                   let retry = await creditsGET(accessToken: refreshed),
                   (200..<300).contains(retry.status) {
                    return retry
                }
            }
        }
        return nil
    }

    private static func creditsGET(accessToken: String) async -> HTTPResult? {
        var req = URLRequest(url: creditsURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(tokenAuthHeader, forHTTPHeaderField: "X-XAI-Token-Auth")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("BurnTracker", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        return HTTPResult(status: http.statusCode, data: data)
    }

    private static func fetchPlanName(accessToken: String) async -> String? {
        var req = URLRequest(url: settingsURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(tokenAuthHeader, forHTTPHeaderField: "X-XAI-Token-Auth")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plan = (json["subscription_tier_display"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty else { return nil }
        return plan
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let raw = value as? String else { return nil }
        return TimeFormat.parseDate(raw)
    }
}
