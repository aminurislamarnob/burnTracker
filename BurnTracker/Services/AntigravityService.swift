import Foundation

/// Antigravity IDE usage tracker. Reads quota from the **local Antigravity
/// language server** — the `RetrieveUserQuotaSummary` endpoint exposed by the
/// running Antigravity app. This is a distinct provider from `GeminiService`
/// (which uses the Cloud Code API); they are tracked and shown separately.
enum AntigravityService {

    // MARK: - Login

    /// Returns the linked account's email + a placeholder token, or nil if no
    /// local Google credentials exist under `~/.gemini`.
    static func login() -> (email: String, token: String)? {
        guard CliQuotaSupport.hasCredentials else { return nil }
        return (CliQuotaSupport.resolveEmail() ?? "Antigravity User", "local-creds")
    }

    // MARK: - Fetch Quota

    /// Fetches Antigravity quota from the local language server. Returns nil if
    /// no Antigravity language server is currently listening (e.g. the app is
    /// not running).
    static func fetchQuota() async -> CliQuotaResult? {
        let email = CliQuotaSupport.resolveEmail()
        let ports = listeningAntigravityPorts()

        for port in ports {
            guard let url = URL(string: "https://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary") else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = "{}".data(using: .utf8)
            req.timeoutInterval = 5

            guard let (data, resp) = try? await CliQuotaSupport.insecureSession.data(for: req),
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = json["response"] as? [String: Any],
                  let groups = response["groups"] as? [[String: Any]] else { continue }

            let gemini = groups.first { ($0["displayName"] as? String)?.lowercased().contains("gemini") == true }
            let claudeGpt = groups.first {
                let name = ($0["displayName"] as? String)?.lowercased() ?? ""
                return name.contains("claude") || name.contains("gpt")
            }

            return CliQuotaResult(
                email: email,
                gemini: CliQuotaSupport.parseBucketGroup(gemini),
                claudeGpt: CliQuotaSupport.parseBucketGroup(claudeGpt))
        }
        return nil
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
}
