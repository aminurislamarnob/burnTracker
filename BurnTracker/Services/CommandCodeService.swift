import Foundation

/// Command Code usage tracker (the `cmd` CLI). Reads quota from the
/// **commandcode.ai API**, authenticating with the API key the CLI stores in
/// `~/.commandcode/auth.json`.
///
/// This is a third, independent CLI provider alongside `AntigravityService` and
/// `GeminiService`. Its quota model is credit-based (dollars against a monthly
/// plan allowance) with optional 5-hour / weekly request windows, so it has its
/// own model (`CommandCodeQuota`) and card rather than reusing `AGGroup`.
///
/// The request sequence and the credit projection below are ports of the CLI's
/// own `fetchUsageData` / `projectUsageView` — **keep them in step**, since the
/// pool math (in particular the `max(planAllowance, monthlyRemaining)` term) is
/// what makes the reported percentage match `cmd`'s `/usage` view.
enum CommandCodeService {

    // MARK: - Paths & auth

    static var configDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".commandcode", isDirectory: true)
    }
    static var authURL: URL { configDir.appendingPathComponent("auth.json") }

    static var hasCredentials: Bool {
        FileManager.default.fileExists(atPath: authURL.path)
    }

    /// Reads the CLI's stored API key. Read fresh on every fetch (never copied
    /// into `tracker-settings.json`) so re-running `cmd login` is picked up and
    /// the key lives in exactly one place on disk.
    private static func readAuth() -> (apiKey: String, userName: String?)? {
        guard let json = CliQuotaSupport.readJSONObject(authURL),
              let apiKey = json["apiKey"] as? String, !apiKey.isEmpty else { return nil }
        return (apiKey, json["userName"] as? String)
    }

    // MARK: - Login

    /// Returns the linked account's display name + a placeholder token, or nil
    /// when the `cmd` CLI has no stored credentials.
    static func login() -> (email: String, token: String)? {
        guard let auth = readAuth() else { return nil }
        return (auth.userName ?? "Command Code User", "local-creds")
    }

    // MARK: - Fetch Quota

    private static let apiBase = "https://api.commandcode.ai"

    /// Monthly credit allowance per plan id, and the friendly plan names —
    /// copied verbatim from the CLI (it derives the pool locally; the API does
    /// not return the allowance).
    private static let planCredits: [String: Double] = [
        "individual-go": 10,
        "individual-pro": 30,
        "individual-provider": 15,
        "individual-max": 150,
        "individual-ultra": 300,
        "teams-pro": 40
    ]
    private static let planNames: [String: String] = [
        "individual-go": "Go",
        "individual-pro": "Pro",
        "individual-provider": "Provider",
        "individual-max": "Max",
        "individual-ultra": "Ultra",
        "teams-pro": "Teams Pro"
    ]

    /// Resolves a plan id ("individual-go", "individual_go_v2", …) to its
    /// friendly name and monthly allowance. Matches the longest known prefix.
    private static func planInfo(_ planId: String?) -> (name: String, monthlyCredits: Double)? {
        guard let planId, !planId.isEmpty else { return nil }
        let normalized = planId.lowercased().replacingOccurrences(of: "_", with: "-")
        let keys = planCredits.keys.sorted { $0.count > $1.count }
        guard let key = keys.first(where: { normalized.hasPrefix($0) }),
              let credits = planCredits[key] else { return nil }
        return (planNames[key] ?? key, credits)
    }

    /// Fetches the current quota, or nil when unauthenticated / unreachable.
    static func fetchQuota() async -> (email: String?, quota: CommandCodeQuota)? {
        guard let auth = readAuth() else { return nil }
        let key = auth.apiKey

        // whoami resolves the account email and the org scope every other call
        // is filtered by (nil for personal accounts, which omits the param).
        guard let whoami = await get("/alpha/whoami", apiKey: key) else { return nil }
        let email = (whoami["user"] as? [String: Any])?["email"] as? String
        let orgId = (whoami["org"] as? [String: Any])?["id"] as? String

        async let creditsCall = get("/alpha/billing/credits", apiKey: key, params: ["orgId": orgId])
        async let subscriptionCall = get("/alpha/billing/subscriptions", apiKey: key, params: ["orgId": orgId])
        let (creditsJSON, subscriptionJSON) = await (creditsCall, subscriptionCall)

        // Credits carry the balances and the window limits — without them there
        // is nothing to show, so treat a failure here as a failed sync.
        guard let creditsJSON else { return nil }

        let subscription = subscriptionJSON?["data"] as? [String: Any]
        let periodStart = subscription?["currentPeriodStart"] as? String

        // Spend is scoped to the current billing period, matching the balances.
        let summary = await get("/alpha/usage/summary", apiKey: key,
                                params: ["orgId": orgId, "since": periodStart])

        let quota = project(credits: creditsJSON, subscription: subscription, summary: summary)
        return (email, quota)
    }

    // MARK: - Projection (port of the CLI's `projectUsageView`)

    private static func project(credits creditsJSON: [String: Any],
                                subscription: [String: Any]?,
                                summary: [String: Any]?) -> CommandCodeQuota {
        let credits = creditsJSON["credits"] as? [String: Any]
        func amount(_ field: String) -> Double {
            max(0, CliQuotaSupport.asDouble(credits?[field]) ?? 0)
        }

        let monthly = amount("monthlyCredits")
        let purchased = amount("purchasedCredits")
        let free = amount("freeCredits")
        let remaining = monthly + purchased + free
        let spent = max(0, CliQuotaSupport.asDouble(summary?["totalCost"]) ?? 0)

        let planId = subscription?["planId"] as? String
        let status = subscription?["status"] as? String
        let plan = planInfo(planId)

        // The plan allowance only counts while the subscription is active;
        // otherwise the pool is just what has been spent plus what is left.
        let allowance: Double? = (status == "active") ? plan?.monthlyCredits : nil
        let pool = allowance.map { max($0, monthly) + purchased + free } ?? (spent + remaining)

        let hasCreditsInfo = remaining > 0 || spent > 0
        let usedPct = hasCreditsInfo && pool > 0
            ? Int(min(100, (pool - remaining) / pool * 100).rounded())
            : 0

        let windows = creditsJSON["windowLimits"] as? [String: Any]
        // `limited: false` means the plan enforces no request windows at all.
        let limited = (windows?["limited"] as? Bool) ?? false

        return CommandCodeQuota(
            planName: plan?.name,
            planStatus: status,
            periodEnd: (subscription?["currentPeriodEnd"] as? String).flatMap(TimeFormat.parseDate),
            monthlyRemaining: monthly,
            purchasedRemaining: purchased,
            freeRemaining: free,
            totalSpent: spent,
            requestCount: (CliQuotaSupport.asDouble(summary?["totalCount"])).map { Int($0) },
            totalPool: pool,
            hasCreditsInfo: hasCreditsInfo,
            creditsUsedPct: usedPct,
            fiveHour: limited ? window(windows?["fiveHour"]) : nil,
            weekly: limited ? window(windows?["weekly"]) : nil)
    }

    /// Parses one `windowLimits` entry. `resetAt` is epoch **milliseconds**, and
    /// `0` means no window is currently running.
    private static func window(_ raw: Any?) -> CommandCodeWindow? {
        guard let dict = raw as? [String: Any] else { return nil }
        let cap = CliQuotaSupport.asDouble(dict["cap"]) ?? 0
        guard cap > 0 else { return nil }

        let resetMillis = CliQuotaSupport.asDouble(dict["resetAt"]) ?? 0
        return CommandCodeWindow(
            used: max(0, CliQuotaSupport.asDouble(dict["used"]) ?? 0),
            cap: cap,
            exceeded: (dict["exceeded"] as? Bool) ?? false,
            resetAt: resetMillis > 0 ? Date(timeIntervalSince1970: resetMillis / 1000) : nil)
    }

    // MARK: - HTTP

    /// GETs a JSON endpoint with the CLI's bearer auth. Nil-valued params are
    /// omitted, matching the CLI's `buildUsageEndpoint`.
    private static func get(_ path: String,
                            apiKey: String,
                            params: [String: String?] = [:]) async -> [String: Any]? {
        guard var comps = URLComponents(string: apiBase + path) else { return nil }
        let items = params.compactMap { name, value in
            value.map { URLQueryItem(name: name, value: $0) }
        }
        if !items.isEmpty { comps.queryItems = items.sorted { $0.name < $1.name } }
        guard let url = comps.url else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }
}
