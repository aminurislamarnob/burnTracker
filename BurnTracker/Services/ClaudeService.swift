import Foundation

/// Fetches real-time quota limits from Claude's private web APIs.
/// Runs natively (no CORS/cookie restrictions), mirroring `fetchLiveLimits`
/// in the original `main.js`.
enum ClaudeService {
    enum FetchError: LocalizedError {
        case emptyKey
        case unauthorized
        case status(Int)
        case noOrganizations
        case connection(String)

        var errorDescription: String? {
            switch self {
            case .emptyKey: return "Session key is empty."
            case .unauthorized: return "Unauthorized. The sessionKey might be invalid or expired."
            case .status(let code): return "Server returned status \(code)"
            case .noOrganizations: return "No organizations found on this account."
            case .connection(let m): return "Connection failed: \(m)"
            }
        }
    }

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// A URLSession that does not manage cookies, so our manual `Cookie`
    /// header is sent verbatim.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    private struct OrgStub: Decodable { let uuid: String }

    static func fetchLiveLimits(sessionKey: String) async -> Result<QuotaData, FetchError> {
        guard !sessionKey.isEmpty else { return .failure(.emptyKey) }

        do {
            // 1. Resolve the first organization's uuid.
            let orgsReq = makeRequest(url: URL(string: "https://claude.ai/api/organizations")!,
                                      sessionKey: sessionKey)
            let (orgsData, orgsResp) = try await session.data(for: orgsReq)
            guard let orgsHTTP = orgsResp as? HTTPURLResponse else {
                return .failure(.connection("No HTTP response"))
            }
            if orgsHTTP.statusCode == 401 || orgsHTTP.statusCode == 403 {
                return .failure(.unauthorized)
            }
            guard orgsHTTP.statusCode == 200 else {
                return .failure(.status(orgsHTTP.statusCode))
            }

            let orgs = (try? JSONDecoder().decode([OrgStub].self, from: orgsData)) ?? []
            guard let orgId = orgs.first?.uuid else {
                return .failure(.noOrganizations)
            }

            // 2. Fetch the rate-limit payload.
            let usageReq = makeRequest(
                url: URL(string: "https://claude.ai/api/organizations/\(orgId)/usage")!,
                sessionKey: sessionKey)
            let (usageData, usageResp) = try await session.data(for: usageReq)
            guard let usageHTTP = usageResp as? HTTPURLResponse, usageHTTP.statusCode == 200 else {
                let code = (usageResp as? HTTPURLResponse)?.statusCode ?? -1
                return .failure(.status(code))
            }

            let quota = try JSONDecoder().decode(QuotaData.self, from: usageData)
            return .success(quota)
        } catch {
            return .failure(.connection(error.localizedDescription))
        }
    }

    private struct Bootstrap: Decodable {
        struct Account: Decodable { let email_address: String? }
        let account: Account?
    }

    /// Fetches the account's email address from `/api/bootstrap`
    /// (`account.email_address`). Returns nil on any failure — the email is a
    /// nice-to-have label and must never block the quota path.
    static func fetchAccountEmail(sessionKey: String) async -> String? {
        guard !sessionKey.isEmpty else { return nil }
        let req = makeRequest(url: URL(string: "https://claude.ai/api/bootstrap")!, sessionKey: sessionKey)
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let boot = try? JSONDecoder().decode(Bootstrap.self, from: data),
              let email = boot.account?.email_address, !email.isEmpty else {
            return nil
        }
        return email
    }

    private static func makeRequest(url: URL, sessionKey: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }
}
