import Foundation

/// Cursor plan usage from the signed-in Cursor app. Reads OAuth tokens from
/// Cursor's local state (SQLite + Keychain), then calls the same dashboard APIs
/// as openusage's Cursor provider.
enum CursorService {
    private static let usageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
    private static let planURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo")!
    private static let refreshURL = URL(string: "https://api2.cursor.sh/oauth/token")!
    private static let creditsURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCreditGrantsBalance")!
    private static let restUsageURL = URL(string: "https://cursor.com/api/usage")!
    private static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"

    enum FetchOutcome: Equatable {
        case success(email: String?, quota: CursorQuota)
        case notLoggedIn
        case unauthorized
        case failed
    }

    static func login() -> (email: String, token: String)? {
        // Link from the Cursor state DB alone. Token reads (and the Keychain
        // prompt) happen on refresh, once the window can present UI.
        guard CursorAuthSupport.hasCursorDatabase else { return nil }
        let email = CursorAuthSupport.resolveEmail(accessToken: nil) ?? "Cursor"
        return (email, "local-creds")
    }

    static func fetchQuota() async -> FetchOutcome {
        let candidates = await MainActor.run { CursorAuthSupport.loadAuthCandidates() }
        guard !candidates.isEmpty else { return .notLoggedIn }

        var lastFailure: FetchOutcome = .notLoggedIn
        for var state in candidates {
            switch await fetchQuota(authState: &state) {
            case .success(let email, let quota):
                return .success(email: email, quota: quota)
            case .notLoggedIn:
                lastFailure = .notLoggedIn
            case .unauthorized:
                lastFailure = .unauthorized
            case .failed:
                lastFailure = .failed
            }
        }
        return lastFailure
    }

    private static func fetchQuota(authState: inout CursorAuthSupport.AuthState) async -> FetchOutcome {
        var state = authState
        defer { authState = state }

        var accessToken = state.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        if accessToken?.isEmpty != false {
            accessToken = nil
        }

        if CursorAuthSupport.needsRefresh(accessToken) {
            if let refreshed = await refreshAccessToken(state: state) {
                accessToken = refreshed
                if let updated = await MainActor.run(body: { CursorAuthSupport.loadAuthState() }) {
                    state = updated
                }
            } else if accessToken == nil {
                return .notLoggedIn
            }
        }

        guard let accessToken, !accessToken.isEmpty else { return .notLoggedIn }

        guard let usageJSON = await fetchUsageWithRetry(accessToken: accessToken, state: &state) else {
            return .unauthorized
        }

        let planName = await fetchPlanName(accessToken: state.accessToken ?? accessToken)
        let normalizedPlan = planName?.lowercased() ?? ""

        if shouldUseRequestFallback(usage: usageJSON, planName: normalizedPlan) {
            if let quota = await mapRequestFallback(accessToken: state.accessToken ?? accessToken,
                                                    planName: planName) {
                let email = CursorAuthSupport.resolveEmail(accessToken: state.accessToken ?? accessToken)
                return .success(email: email, quota: quota)
            }
            return .failed
        }

        let credits = await fetchCreditGrants(accessToken: state.accessToken ?? accessToken)
        let stripeCents = await fetchStripeBalanceCents(accessToken: state.accessToken ?? accessToken)
        guard let quota = mapUsage(usage: usageJSON, planName: planName,
                                   creditGrants: credits, stripeBalanceCents: stripeCents) else {
            return .failed
        }
        let email = CursorAuthSupport.resolveEmail(accessToken: state.accessToken ?? accessToken)
        return .success(email: email, quota: quota)
    }

    // MARK: - Mapping

    private static func mapUsage(usage: [String: Any],
                                 planName: String?,
                                 creditGrants: [String: Any]?,
                                 stripeBalanceCents: Double) -> CursorQuota? {
        guard usage["enabled"] as? Bool != false,
              let planUsage = usage["planUsage"] as? [String: Any] else { return nil }

        let limit = asDouble(planUsage["limit"])
        let totalPercent = asDouble(planUsage["totalPercentUsed"])
        guard limit != nil || totalPercent != nil else { return nil }

        let planUsedCents = asDouble(planUsage["totalSpend"])
            ?? ((limit ?? 0) - (asDouble(planUsage["remaining"]) ?? 0))
        let computedPercent = limit.flatMap { l -> Double? in
            guard l > 0 else { return nil }
            return planUsedCents / l * 100
        } ?? 0
        let totalPct = Int(min(100, max(0, (totalPercent ?? computedPercent)).rounded()))

        let cycleEnd = billingCycleEnd(from: usage)
        var creditsRemaining: Double?
        let hasGrants = creditGrants?["hasCreditGrants"] as? Bool == true
        let grantTotal = hasGrants ? (asDouble(creditGrants?["totalCents"]) ?? 0) : 0
        let grantUsed = hasGrants ? (asDouble(creditGrants?["usedCents"]) ?? 0) : 0
        let combinedTotal = (grantTotal > 0 ? grantTotal : 0) + stripeBalanceCents
        if combinedTotal > 0 {
            let remainingCents = max(0, combinedTotal - (grantTotal > 0 ? grantUsed : 0))
            creditsRemaining = remainingCents / 100
        }

        var onDemandSpent: Double?
        var onDemandLimit: Double?
        if let spend = usage["spendLimitUsage"] as? [String: Any] {
            let limitCents = asDouble(spend["individualLimit"]) ?? asDouble(spend["pooledLimit"]) ?? 0
            let remainingCents = asDouble(spend["individualRemaining"]) ?? asDouble(spend["pooledRemaining"]) ?? 0
            let spentCents = max(0, limitCents - remainingCents)
            if limitCents > 0 {
                onDemandLimit = limitCents / 100
                onDemandSpent = spentCents / 100
            } else if spentCents > 0 {
                onDemandSpent = spentCents / 100
            }
        }

        let normalizedPlan = planName?.lowercased() ?? ""
        let spendLimit = usage["spendLimitUsage"] as? [String: Any]
        let isTeam = normalizedPlan == "team"
            || (spendLimit?["limitType"] as? String)?.lowercased() == "team"
            || (asDouble(spendLimit?["pooledLimit"]) ?? 0) > 0

        var totalUsedPct: Int? = totalPct
        if isTeam, let limit = limit, limit > 0 {
            totalUsedPct = Int(min(100, max(0, (planUsedCents / limit * 100).rounded())))
        }

        return CursorQuota(
            planName: planName,
            totalUsedPct: totalUsedPct,
            autoUsedPct: asDouble(planUsage["autoPercentUsed"]).map { Int(min(100, max(0, $0)).rounded()) },
            apiUsedPct: asDouble(planUsage["apiPercentUsed"]).map { Int(min(100, max(0, $0)).rounded()) },
            onDemandSpentUSD: onDemandSpent,
            onDemandLimitUSD: onDemandLimit,
            creditsRemainingUSD: creditsRemaining,
            billingCycleEnd: cycleEnd)
    }

    private static func mapRequestFallback(accessToken: String, planName: String?) async -> CursorQuota? {
        guard let session = cursorSession(accessToken: accessToken) else { return nil }
        var comps = URLComponents(url: restUsageURL, resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "user", value: session.userID)]
        guard let url = comps?.url else { return nil }
        guard let json = await cookieGET(url: url, sessionToken: session.sessionToken) else { return nil }

        var used: Int?
        var limit: Int?
        if let gpt4 = json["gpt-4"] as? [String: Any],
           let maxReq = asDouble(gpt4["maxRequestUsage"]), maxReq > 0 {
            used = Int(asDouble(gpt4["numRequests"]) ?? 0)
            limit = Int(maxReq)
        }
        guard limit != nil else { return nil }
        return CursorQuota(planName: planName, requestsUsed: used, requestsLimit: limit)
    }

    private static func shouldUseRequestFallback(usage: [String: Any], planName: String) -> Bool {
        guard usage["enabled"] as? Bool != false else { return false }
        let planUsage = usage["planUsage"] as? [String: Any]
        let hasPlan = planUsage != nil
        let limit = planUsage.flatMap { asDouble($0["limit"]) }
        let totalPct = planUsage.flatMap { asDouble($0["totalPercentUsed"]) }
        if !hasPlan || limit == nil {
            if planName == "enterprise" || planName == "team" { return true }
            if limit == nil && totalPct == nil && planName.isEmpty { return true }
        }
        let spend = usage["spendLimitUsage"] as? [String: Any]
        let isTeamShape = (spend?["limitType"] as? String)?.lowercased() == "team"
            || (asDouble(spend?["pooledLimit"]) ?? 0) > 0
        if isTeamShape && limit == nil { return true }
        return false
    }

    // MARK: - HTTP

    private static func fetchUsageWithRetry(accessToken: String,
                                            state: inout CursorAuthSupport.AuthState) async -> [String: Any]? {
        let first = await connectPOST(usageURL, accessToken: accessToken)
        if let first, (200..<300).contains(first.status) {
            return first.json
        }
        if bodyIsAuthError(first),
           let refreshed = await refreshAccessToken(state: state),
           let retry = await connectPOST(usageURL, accessToken: refreshed),
           (200..<300).contains(retry.status) {
            return retry.json
        }
        return nil
    }

    private struct HTTPBody {
        var status: Int
        var json: [String: Any]?
    }

    private static func connectPOST(_ url: URL, accessToken: String) async -> HTTPBody? {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)
        req.timeoutInterval = 15
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return HTTPBody(status: http.statusCode, json: json)
    }

    private static func bodyIsAuthError(_ body: HTTPBody?) -> Bool {
        guard let body else { return false }
        return body.status == 401 || body.status == 403
    }

    private static func refreshAccessToken(state: CursorAuthSupport.AuthState) async -> String? {
        guard let refresh = state.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !refresh.isEmpty else { return nil }
        var req = URLRequest(url: refreshURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refresh
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["shouldLogout"] as? Bool != true,
              let access = (body["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !access.isEmpty else { return nil }
        _ = CursorAuthSupport.saveAccessToken(access, source: state.source)
        return access
    }

    private static func fetchPlanName(accessToken: String) async -> String? {
        guard let body = await connectPOST(planURL, accessToken: accessToken),
              (200..<300).contains(body.status),
              let planInfo = body.json?["planInfo"] as? [String: Any],
              let name = (planInfo["planName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    private static func fetchCreditGrants(accessToken: String) async -> [String: Any]? {
        guard let body = await connectPOST(creditsURL, accessToken: accessToken),
              (200..<300).contains(body.status) else { return nil }
        return body.json
    }

    private static func fetchStripeBalanceCents(accessToken: String) async -> Double {
        guard let session = cursorSession(accessToken: accessToken),
              let url = URL(string: "https://cursor.com/api/auth/stripe"),
              let json = await cookieGET(url: url, sessionToken: session.sessionToken),
              let balance = asDouble(json["customerBalance"]), balance < 0 else { return 0 }
        return abs(balance)
    }

    private struct CursorSession {
        var userID: String
        var sessionToken: String
    }

    private static func cursorSession(accessToken: String) -> CursorSession? {
        guard let subject = CursorAuthSupport.tokenSubject(accessToken) else { return nil }
        let parts = subject.split(separator: "|", omittingEmptySubsequences: false)
        let userID = String(parts.count > 1 ? parts[1] : parts[0])
        guard !userID.isEmpty else { return nil }
        return CursorSession(userID: userID, sessionToken: "\(userID)%3A%3A\(accessToken)")
    }

    private static func cookieGET(url: URL, sessionToken: String) async -> [String: Any]? {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("WorkosCursorSessionToken=\(sessionToken)", forHTTPHeaderField: "Cookie")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    private static func billingCycleEnd(from usage: [String: Any]) -> Date? {
        if let end = asDouble(usage["billingCycleEnd"]), end > 0 {
            return Date(timeIntervalSince1970: end / 1000)
        }
        return nil
    }

    private static func asDouble(_ value: Any?) -> Double? {
        CliQuotaSupport.asDouble(value)
    }
}
