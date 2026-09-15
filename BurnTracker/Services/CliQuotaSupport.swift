import Foundation

/// Credential and quota-bucket helpers for `AntigravityService`.
///
/// Antigravity signs in through the Gemini CLI, so its account identity still
/// comes from `~/.gemini` — these helpers read that directory but never speak
/// OAuth to Google. (A separate Gemini CLI provider used to share this file;
/// it was removed once Google stopped licensing Code Assist for the account
/// tiers it served.)
enum CliQuotaSupport {

    // MARK: - Paths

    static var geminiDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini", isDirectory: true)
    }
    static var credsURL: URL { geminiDir.appendingPathComponent("oauth_creds.json") }
    static var googleAccountsURL: URL { geminiDir.appendingPathComponent("google_accounts.json") }

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
