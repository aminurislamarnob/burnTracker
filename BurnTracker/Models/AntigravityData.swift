import Foundation

/// A parsed CLI quota group (a model family: gemini or claude/gpt). Produced by
/// `AntigravityService` / `GeminiService`, mirroring the shape built in `main.js`.
struct AGGroup {
    var name: String
    var description: String?
    var weeklyPct: Int
    var weeklyRawPct: String
    var weeklyResetsIn: String?
    var fiveHourPct: Int
    var fiveHourRawPct: String
    var fiveHourResetsIn: String?
}

/// Result of a CLI quota fetch (Antigravity or Gemini CLI).
struct CliQuotaResult {
    var email: String?
    var gemini: AGGroup?
    var claudeGpt: AGGroup?
}

/// The persisted Tracker settings file schema — kept drop-in compatible with
/// the JSON written by the original Electron build (`tracker-settings.json`).
struct TrackerSettings: Codable {
    struct PersistedAccount: Codable {
        var id: String
        var label: String
        var sessionKey: String
        /// Cached account email (optional; older files omit it — remains
        /// drop-in compatible since unknown/missing keys are tolerated).
        var email: String?
    }
    struct PersistedAg: Codable {
        var token: String
        var email: String?
    }

    var accounts: [PersistedAccount]
    /// The linked Antigravity IDE account (local language-server source).
    var agAccount: PersistedAg?
    /// The linked Gemini CLI account (Cloud Code API source).
    var geminiAccount: PersistedAg?
    var refreshMinutes: Int
    var alertThreshold: Int

    enum CodingKeys: String, CodingKey {
        case accounts, agAccount, geminiAccount, refreshMinutes, alertThreshold
    }

    init(accounts: [PersistedAccount] = [],
         agAccount: PersistedAg? = nil,
         geminiAccount: PersistedAg? = nil,
         refreshMinutes: Int = 15,
         alertThreshold: Int = 80) {
        self.accounts = accounts
        self.agAccount = agAccount
        self.geminiAccount = geminiAccount
        self.refreshMinutes = refreshMinutes
        self.alertThreshold = alertThreshold
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = (try? c.decode([PersistedAccount].self, forKey: .accounts)) ?? []
        agAccount = try? c.decode(PersistedAg.self, forKey: .agAccount)
        geminiAccount = try? c.decode(PersistedAg.self, forKey: .geminiAccount)
        refreshMinutes = (try? c.decode(Int.self, forKey: .refreshMinutes)) ?? 15
        alertThreshold = (try? c.decode(Int.self, forKey: .alertThreshold)) ?? 80
    }
}
