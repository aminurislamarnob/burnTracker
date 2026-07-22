import Foundation

/// Antigravity / Gemini CLI usage tracker. Faithful port of the
/// `antigravity:login` and `antigravity:fetchQuota` handlers in `main.js`.
///
/// The embedded Google OAuth client secrets are copied verbatim (kept
/// base64-obfuscated, never plaintext), matching the original build.
enum AntigravityService {

    // MARK: - Paths

    private static var geminiDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini", isDirectory: true)
    }
    private static var credsURL: URL { geminiDir.appendingPathComponent("oauth_creds.json") }
    private static var googleAccountsURL: URL { geminiDir.appendingPathComponent("google_accounts.json") }
    private static var projectsURL: URL { geminiDir.appendingPathComponent("projects.json") }

    // MARK: - Login

    /// Returns the linked account's email + a placeholder token, or nil if no
    /// local creds exist.
    static func login() -> (email: String, token: String)? {
        guard FileManager.default.fileExists(atPath: credsURL.path) else { return nil }
        return (resolveEmail() ?? "Antigravity User", "local-creds")
    }

    private static func resolveEmail() -> String? {
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

    // MARK: - Fetch Quota

    static func fetchQuota() async -> AntigravityResult? {
        guard FileManager.default.fileExists(atPath: credsURL.path) else { return nil }
        let email = resolveEmail()

        // Strategy 1: local Antigravity LanguageServerService.
        if let local = await fetchFromLocalLanguageServer(email: email) {
            return local
        }

        // Strategy 2: Cloud Code API fallback.
        return await fetchFromCloudCode(email: email)
    }

    // MARK: - Strategy 1 (local language server)

    private static func fetchFromLocalLanguageServer(email: String?) async -> AntigravityResult? {
        let ports = listeningAntigravityPorts()
        for port in ports {
            guard let url = URL(string: "https://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary") else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = "{}".data(using: .utf8)
            req.timeoutInterval = 5

            guard let (data, resp) = try? await insecureSession.data(for: req),
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = json["response"] as? [String: Any],
                  let groups = response["groups"] as? [[String: Any]] else { continue }

            let gemini = groups.first { ($0["displayName"] as? String)?.lowercased().contains("gemini") == true }
            let claudeGpt = groups.first {
                let name = ($0["displayName"] as? String)?.lowercased() ?? ""
                return name.contains("claude") || name.contains("gpt")
            }

            return AntigravityResult(
                email: email,
                gemini: parseBucketGroup(gemini),
                claudeGpt: parseBucketGroup(claudeGpt))
        }
        return nil
    }

    /// Parses a group from the RetrieveUserQuotaSummary response.
    private static func parseBucketGroup(_ group: [String: Any]?) -> AGGroup? {
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

    // MARK: - Strategy 2 (Cloud Code API)

    private static func fetchFromCloudCode(email: String?) async -> AntigravityResult? {
        guard let creds = readJSONObject(credsURL) else { return nil }

        var accessToken = creds["access_token"] as? String
        if let refreshToken = creds["refresh_token"] as? String,
           let idToken = creds["id_token"] as? String,
           let payload = decodeJWTPayload(idToken),
           let clientId = payload["azp"] as? String {
            guard let clientSecret = clientSecret(for: clientId) else {
                NSLog("BurnTracker: unsupported Antigravity client id")
                return nil
            }
            accessToken = try? await refreshGeminiToken(refreshToken: refreshToken,
                                                         clientId: clientId,
                                                         clientSecret: clientSecret)
        }
        guard let token = accessToken else { return nil }

        // Resolve active project (first entry), if any.
        var activeProject: String?
        if let pj = readJSONObject(projectsURL),
           let projects = pj["projects"] as? [String: Any],
           let firstKey = projects.keys.first,
           let value = projects[firstKey] as? String {
            activeProject = value
        }

        let reqBody: [String: Any] = activeProject.map { ["project": $0] } ?? [:]

        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: reqBody)

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = json["buckets"] as? [[String: Any]] else {
            return nil
        }

        let geminiBuckets = buckets.filter { ($0["modelId"] as? String)?.contains("gemini") == true }
        let claudeGptBuckets = buckets.filter {
            let m = ($0["modelId"] as? String) ?? ""
            return m.contains("claude") || m.contains("gpt")
        }
        let fallbackBuckets = geminiBuckets.isEmpty ? buckets : geminiBuckets

        return AntigravityResult(
            email: email,
            gemini: parseCloudGroup(name: "Gemini Models", buckets: fallbackBuckets),
            claudeGpt: parseCloudGroup(name: "Claude and GPT models", buckets: claudeGptBuckets))
    }

    /// Parses a group from the retrieveUserQuota response.
    /// NOTE: weekly values are derived from the "flash/5-hour" bucket and
    /// fiveHour values from the "pro/weekly" bucket — faithful to `main.js`.
    private static func parseCloudGroup(name: String, buckets: [[String: Any]]) -> AGGroup? {
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

    private static func refreshGeminiToken(refreshToken: String, clientId: String, clientSecret: String) async throws -> String {
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

    private static func clientSecret(for clientId: String) -> String? {
        guard let parts = oauthClients[clientId],
              let data = Data(base64Encoded: parts.joined()) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Local port discovery

    private static func listeningAntigravityPorts() -> [Int] {
        let lsof = "/usr/sbin/lsof"
        guard FileManager.default.isExecutableFile(atPath: lsof) else { return [] }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: lsof)
        task.arguments = ["-iTCP", "-sTCP:LISTEN", "-P", "-n"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do { try task.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var ports: [Int] = []
        for line in output.split(separator: "\n") {
            let lower = line.lowercased()
            guard lower.contains("agy") || lower.contains("antigravity") || lower.contains("language_server") else { continue }
            // Extract the port from ":<port> (LISTEN)".
            if let range = line.range(of: #":(\d+)\s+\(LISTEN\)"#, options: .regularExpression) {
                let match = line[range]
                let digits = match.drop { $0 == ":" }.prefix { $0.isNumber }
                if let p = Int(digits), !ports.contains(p) { ports.append(p) }
            }
        }
        return ports
    }

    // MARK: - JSON / JWT helpers

    private static func readJSONObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func asDouble(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func pct(_ remainingFraction: Any?) -> Int {
        guard let rf = asDouble(remainingFraction) else { return 100 }
        return Int((rf * 100).rounded())
    }

    private static func rawPct(_ remainingFraction: Any?) -> String {
        guard let rf = asDouble(remainingFraction) else { return "100.00" }
        return String(format: "%.2f", rf * 100)
    }

    // A URLSession that trusts the self-signed cert on 127.0.0.1 only.
    private static let insecureSession: URLSession = {
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
