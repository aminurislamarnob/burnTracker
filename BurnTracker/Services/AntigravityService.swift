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
        let endpoints = self.endpoints()
        guard !endpoints.isEmpty else { return .notRunning }

        let email = CliQuotaSupport.resolveEmail()
        var sawUnauthorized = false

        for endpoint in endpoints {
            switch await call(endpoint) {
            case let .success(groups):
                let gemini = groups.first { ($0["displayName"] as? String)?.lowercased().contains("gemini") == true }
                let claudeGpt = groups.first {
                    let name = ($0["displayName"] as? String)?.lowercased() ?? ""
                    return name.contains("claude") || name.contains("gpt")
                }
                return .success(CliQuotaResult(
                    email: email,
                    gemini: CliQuotaSupport.parseBucketGroup(gemini),
                    claudeGpt: CliQuotaSupport.parseBucketGroup(claudeGpt)))
            case .unauthorized:
                sawUnauthorized = true
            case .unreachable:
                continue
            }
        }

        return sawUnauthorized ? .unauthorized : .failed
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
}
