import Foundation

/// Shared helpers used by both `AntigravityService` (local language-server
/// probe) and `GeminiService` (Cloud Code API). Both read Google OAuth
/// credentials from `~/.gemini` and parse the same quota-bucket shapes, so the
/// common logic lives here.
///
/// The embedded Google OAuth client secrets are copied verbatim (kept
/// base64-obfuscated, never plaintext), matching the original Electron build.
enum CliQuotaSupport {

    // MARK: - Paths

    static var geminiDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini", isDirectory: true)
    }
    static var credsURL: URL { geminiDir.appendingPathComponent("oauth_creds.json") }
    static var googleAccountsURL: URL { geminiDir.appendingPathComponent("google_accounts.json") }
    static var projectsURL: URL { geminiDir.appendingPathComponent("projects.json") }

    static var hasCredentials: Bool {
        FileManager.default.fileExists(atPath: credsURL.path)
    }

    // MARK: - Email resolution

    static func resolveEmail() -> String? {
        if let ga = readJSONObject(googleAccountsURL), let active = ga["active"] as? String {
            return active
        }
        if let creds = readJSONObject(credsURL),
           let idToken = creds["id_token"] as? String,
           let payload = decodeJWTPayload(idToken),
           let email = payload["email"] as? String {
            return email
        }
        return nil
    }

    // MARK: - Bucket parsing (local language server response)

    /// Parses a `groups[]` entry from the RetrieveUserQuotaSummary response.
    static func parseBucketGroup(_ group: [String: Any]?) -> AGGroup? {
        guard let group, let buckets = group["buckets"] as? [[String: Any]], !buckets.isEmpty else { return nil }

        let weekly = buckets.first {
            ($0["window"] as? String) == "weekly" || (($0["bucketId"] as? String)?.contains("weekly") == true)
        } ?? buckets.first!

        let fiveHour = buckets.first {
            ($0["window"] as? String) == "5h" || (($0["bucketId"] as? String)?.contains("5h") == true)
        } ?? buckets.last!

        return AGGroup(
            name: group["displayName"] as? String ?? "Models",
            description: group["description"] as? String,
            weeklyPct: pct(weekly["remainingFraction"]),
            weeklyRawPct: rawPct(weekly["remainingFraction"]),
            weeklyResetsIn: weekly["resetTime"] as? String,
            fiveHourPct: pct(fiveHour["remainingFraction"]),
            fiveHourRawPct: rawPct(fiveHour["remainingFraction"]),
            fiveHourResetsIn: fiveHour["resetTime"] as? String)
    }

    // MARK: - Bucket parsing (Cloud Code response)

    /// Parses a group from the retrieveUserQuota response.
    /// NOTE: weekly values are derived from the "flash/5-hour" bucket and
    /// fiveHour values from the "pro/weekly" bucket — faithful to `main.js`.
    static func parseCloudGroup(name: String, buckets: [[String: Any]]) -> AGGroup? {
        guard !buckets.isEmpty else { return nil }

        func modelId(_ b: [String: Any]) -> String { (b["modelId"] as? String) ?? "" }
        func rf(_ b: [String: Any]) -> Double { asDouble(b["remainingFraction"]) ?? 0 }

        let proOrWeekly = buckets.filter { modelId($0).contains("pro") || modelId($0).contains("weekly") }
        let flashOrFiveHour = buckets.filter {
            let m = modelId($0)
            return m.contains("flash") || m.contains("lite") || m.contains("5hour") || m.contains("five_hour")
        }

        let lowestPro = proOrWeekly.min { rf($0) < rf($1) } ?? buckets.first!
        let lowestFlash = flashOrFiveHour.min { rf($0) < rf($1) } ?? buckets.last!

        return AGGroup(
            name: name,
            description: nil,
            weeklyPct: pct(lowestFlash["remainingFraction"]),
            weeklyRawPct: rawPct(lowestFlash["remainingFraction"]),
            weeklyResetsIn: lowestFlash["resetTime"] as? String,
            fiveHourPct: pct(lowestPro["remainingFraction"]),
            fiveHourRawPct: rawPct(lowestPro["remainingFraction"]),
            fiveHourResetsIn: lowestPro["resetTime"] as? String)
    }

    // MARK: - OAuth token refresh

    static func refreshGeminiToken(refreshToken: String, clientId: String, clientSecret: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token")
        ]
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            throw NSError(domain: "BurnTracker", code: 1, userInfo: [NSLocalizedDescriptionKey: "Token refresh failed"])
        }
        return token
    }

    // Embedded OAuth clients (base64-obfuscated, matching main.js).
    private static let oauthClients: [String: [String]] = [
        "681255809395" + "-oo8ft2oprdrnp9e3aqf6av3hmdib135j." + "apps.googleusercontent.com":
            ["R09DU1BY", "LTR1SGdNUG0tMW83U2stZ2VWNkN1NWNsWEZzeGw="],
        "884354919052" + "-36trc1jjb3tguiac32ov6cod268c5blh." + "apps.googleusercontent.com":
            ["R09DU1BY", "LUs1OEZXUjQ4NkxkTEoxbUxCOHNYQzR6NnFEQWY="],
        "1071006060591" + "-tmhssin2h21lcre235vtolojh4g403ep." + "apps.googleusercontent.com":
            ["R09DU1BY", "LTlZUVdwRjdSV0RDMFFUZGotWXhLTXdSMFp0c1g="]
    ]

    static func clientSecret(for clientId: String) -> String? {
        guard let parts = oauthClients[clientId],
              let data = Data(base64Encoded: parts.joined()) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - JSON / JWT helpers

    static func readJSONObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func asDouble(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }

    static func pct(_ remainingFraction: Any?) -> Int {
        guard let rf = asDouble(remainingFraction) else { return 100 }
        return Int((rf * 100).rounded())
    }

    static func rawPct(_ remainingFraction: Any?) -> String {
        guard let rf = asDouble(remainingFraction) else { return "100.00" }
        return String(format: "%.2f", rf * 100)
    }

    // A URLSession that trusts the self-signed cert on 127.0.0.1 only.
    static let insecureSession: URLSession = {
        URLSession(configuration: .ephemeral, delegate: LocalhostTrustDelegate(), delegateQueue: nil)
    }()
}

/// Trusts self-signed certificates, but only for connections to 127.0.0.1.
private final class LocalhostTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == "127.0.0.1",
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
