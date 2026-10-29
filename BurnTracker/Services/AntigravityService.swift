import Foundation

/// The result of one Antigravity quota fetch.
///
/// Distinguishing *why* a fetch failed is the difference between "open the app"
/// and "the app is open but refused us" — two states the card must not conflate,
/// and the ones worth knowing when Antigravity next changes this interface.
enum AntigravityFetchOutcome {
    case success(CliQuotaResult)
    /// No Antigravity server is listening at all.
    case notRunning
    /// A server answered, but rejected our credentials (no or stale CSRF token).
    case unauthorized
    /// A server answered but the response was unusable.
    case failed
}

/// Antigravity IDE usage tracker. Reads quota from the **local Antigravity
/// language server** — the `RetrieveUserQuotaSummary` endpoint exposed by the
/// running Antigravity app. The account's identity still comes from `~/.gemini`
/// (Antigravity signs in through the Gemini CLI), but the quota is read locally.
enum AntigravityService {

    private static let service = "exa.language_server_pb.LanguageServerService"
    private static let method = "RetrieveUserQuotaSummary"

    /// Client identification the language server expects on every RPC. Sent
    /// verbatim as a real client would; the server is free to validate it.
    private static let metadata: [String: String] = [
        "ideName": "antigravity",
        "extensionName": "antigravity",
        "ideVersion": "unknown",
        "locale": "en"
    ]

    // MARK: - Login

    /// Returns the linked account's email + a placeholder token, or nil if no
    /// local Google credentials exist under `~/.gemini`.
    static func login() -> (email: String, token: String)? {
        guard CliQuotaSupport.hasCredentials else { return nil }
        return (CliQuotaSupport.resolveEmail() ?? "Antigravity User", "local-creds")
    }

    // MARK: - Fetch Quota

    static func fetchQuota() async -> AntigravityFetchOutcome {
        let email = CliQuotaSupport.resolveEmail()
        let endpoints = self.endpoints()
        var sawUnauthorized = false

        // Prefer a live language server with CSRF (Antigravity app / IDE).
        for endpoint in endpoints {
            switch await call(endpoint) {
            case let .success(groups):
                return .success(quotaResult(email: email, groups: groups))
            case .unauthorized:
                sawUnauthorized = true
            case .unreachable:
                continue
            }
        }

        // Orca-compatible fallback: `agy -p=/usage` talks to Antigravity's own
        // authenticated CLI (Keychain Google credential). Token-less HTTPS to a
        // running `agy` always 401s ("missing CSRF token"), so without this leg
        // CLI-only setups — the common case — never show a card.
        if let groups = await fetchGroupsViaCLI() {
            return .success(quotaResult(email: email, groups: groups))
        }

        if endpoints.isEmpty { return .notRunning }
        return sawUnauthorized ? .unauthorized : .failed
    }

    private static func quotaResult(email: String?, groups: [[String: Any]]) -> CliQuotaResult {
        let gemini = groups.first {
            groupName($0).lowercased().contains("gemini")
        }
        let claudeGpt = groups.first {
            let name = groupName($0).lowercased()
            return name.contains("claude") || name.contains("gpt")
        }
        return CliQuotaResult(
            email: email,
            gemini: CliQuotaSupport.parseBucketGroup(gemini),
            claudeGpt: CliQuotaSupport.parseBucketGroup(claudeGpt))
    }

    private static func groupName(_ group: [String: Any]) -> String {
        (group["displayName"] as? String) ?? (group["name"] as? String) ?? ""
    }

    // MARK: - Endpoints

    private struct Endpoint {
        let scheme: String
        let port: Int
        let csrfToken: String?
    }

    /// Every callable endpoint, richest first.
    ///
    /// The IDE's language server comes first (it carries a CSRF token and is the
    /// current source), then its extension server, and only then a token-less
    /// probe of the `agy` CLI. That last leg is kept for older CLI builds which
    /// accept token-less calls — the only configuration earlier versions of this
    /// app could ever talk to — so ordering it last never prefers it over a
    /// working token-bearing server.
    private static func endpoints() -> [Endpoint] {
        let servers = LanguageServerDiscovery.discover()
        var languageServer: [Endpoint] = []
        var extensionServer: [Endpoint] = []
        var cli: [Endpoint] = []

        for server in servers {
            switch server.kind {
            case .languageServer:
                // HTTPS only: the server presents a self-signed cert that
                // `CliQuotaSupport.insecureSession` trusts for 127.0.0.1, so an
                // HTTP leg would only leak the token in cleartext for nothing.
                languageServer += server.ports.map {
                    Endpoint(scheme: "https", port: $0, csrfToken: server.csrfToken)
                }
                if let port = server.extensionPort {
                    // The extension server is plain HTTP by design.
                    extensionServer.append(
                        Endpoint(scheme: "http", port: port, csrfToken: server.extensionCSRFToken))
                }
            case .cli:
                cli += server.ports.map {
                    Endpoint(scheme: "https", port: $0, csrfToken: server.csrfToken)
                }
            }
        }

        return languageServer + extensionServer + cli
    }

    // MARK: - RPC

    private enum CallResult {
        case success([[String: Any]])
        case unauthorized
        /// Nothing usable here — wrong port, transport error, or an unparseable body.
        case unreachable
    }

    private static func call(_ endpoint: Endpoint) async -> CallResult {
        guard let url = URL(string: "\(endpoint.scheme)://127.0.0.1:\(endpoint.port)/\(service)/\(method)") else {
            return .unreachable
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if let token = endpoint.csrfToken {
            req.setValue(token, forHTTPHeaderField: "x-codeium-csrf-token")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["metadata": metadata])
        req.timeoutInterval = 5

        guard let (data, resp) = try? await CliQuotaSupport.insecureSession.data(for: req),
              let http = resp as? HTTPURLResponse else { return .unreachable }

        if http.statusCode == 401 || http.statusCode == 403 { return .unauthorized }

        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? [String: Any],
              let groups = response["groups"] as? [[String: Any]] else { return .unreachable }

        return .success(groups)
    }

    // MARK: - CLI `/usage` (Orca path)

    /// Runs `agy --output-format json --print-timeout 20s -p=/usage` and returns
    /// the `command.data.groups` array from a SUCCESS usage envelope. Nil when
    /// `agy` is missing, unsigned-in, too old, or answers `/usage` as a prompt.
    private static func fetchGroupsViaCLI() async -> [[String: Any]]? {
        guard let binary = resolveAgyBinary() else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runAgyUsage(binary: binary))
            }
        }
    }

    private static func resolveAgyBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
            "\(home)/.local/bin/agy",
            "\(home)/.agy/bin/agy"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Last resort: ask the user's login PATH via /usr/bin/which.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["agy"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    private static func runAgyUsage(binary: String) -> [[String: Any]]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        // `-p=/usage` (attached) is required on agy 1.4.x; a bare `-p /usage`
        // lets later flags get eaten as the prompt. Never pass
        // `--disable-slash-commands` — that turns `/usage` into a billed turn.
        task.arguments = [
            "--output-format", "json",
            "--print-timeout", "20s",
            "-p=/usage"
        ]
        var env = ProcessInfo.processInfo.environment
        env["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
        task.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr

        do { try task.run() } catch { return nil }

        // Bound wait so a hung print-mode session cannot stall refresh forever.
        let deadline = DispatchTime.now() + .seconds(30)
        while task.isRunning {
            if DispatchTime.now() > deadline {
                task.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        task.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return parseCLIUsageGroups(from: output)
    }

    /// Scans stdout for a SUCCESS `/usage` JSON envelope (agy may print log
    /// lines around it). Returns nil on ERROR envelopes or model-turn replies.
    static func parseCLIUsageGroups(from stdout: String) -> [[String: Any]]? {
        for line in stdout.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"),
                  let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // A billed model turn means this agy treats `/usage` as a prompt —
            // stop rather than spend quota on every refresh.
            if let turns = CliQuotaSupport.asDouble(json["num_turns"]), turns > 0 { return nil }
            if let conversation = json["conversation_id"] as? String, !conversation.isEmpty { return nil }

            guard (json["status"] as? String) == "SUCCESS",
                  let command = json["command"] as? [String: Any],
                  (command["name"] as? String) == "usage",
                  let dataObj = command["data"] as? [String: Any],
                  let groups = dataObj["groups"] as? [[String: Any]]
            else { continue }

            return groups
        }
        return nil
    }
}
