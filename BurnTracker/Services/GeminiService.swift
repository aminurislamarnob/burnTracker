import Foundation

/// Gemini CLI usage tracker. Reads quota from the **Cloud Code API**
/// (`cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`), authenticating
/// with the Google OAuth credentials the Gemini CLI stores under `~/.gemini`.
/// This is a distinct provider from `AntigravityService` (which probes the
/// local Antigravity language server); they are tracked and shown separately.
enum GeminiService {

    // MARK: - Login

    /// Returns the linked account's email + a placeholder token, or nil if no
    /// Gemini CLI credentials exist under `~/.gemini`.
    static func login() -> (email: String, token: String)? {
        guard CliQuotaSupport.hasCredentials else { return nil }
        return (CliQuotaSupport.resolveEmail() ?? "Gemini User", "local-creds")
    }

    // MARK: - Fetch Quota

    static func fetchQuota() async -> CliQuotaResult? {
        guard let creds = CliQuotaSupport.readJSONObject(CliQuotaSupport.credsURL) else { return nil }
        let email = CliQuotaSupport.resolveEmail()

        var accessToken = creds["access_token"] as? String
        if let refreshToken = creds["refresh_token"] as? String,
           let idToken = creds["id_token"] as? String,
           let payload = CliQuotaSupport.decodeJWTPayload(idToken),
           let clientId = payload["azp"] as? String {
            guard let clientSecret = CliQuotaSupport.clientSecret(for: clientId) else {
                NSLog("BurnTracker: unsupported Gemini client id")
                return nil
            }
            accessToken = try? await CliQuotaSupport.refreshGeminiToken(refreshToken: refreshToken,
                                                                        clientId: clientId,
                                                                        clientSecret: clientSecret)
        }
        guard let token = accessToken else { return nil }

        // Resolve active project (first entry), if any.
        var activeProject: String?
        if let pj = CliQuotaSupport.readJSONObject(CliQuotaSupport.projectsURL),
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

        return CliQuotaResult(
            email: email,
            gemini: CliQuotaSupport.parseCloudGroup(name: "Gemini Models", buckets: fallbackBuckets),
            claudeGpt: CliQuotaSupport.parseCloudGroup(name: "Claude and GPT models", buckets: claudeGptBuckets))
    }
}
