import Foundation

/// A parsed Antigravity quota group (gemini or claude/gpt). Produced by
/// `AntigravityService`, mirroring the shape built in `main.js`.
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

/// Result of an Antigravity quota fetch.
struct AntigravityResult {
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
    }
    struct PersistedAg: Codable {
        var token: String
        var email: String?
    }

    var accounts: [PersistedAccount]
    var agAccount: PersistedAg?
    var refreshMinutes: Int
    var alertThreshold: Int

    enum CodingKeys: String, CodingKey {
        case accounts, agAccount, refreshMinutes, alertThreshold
    }

    init(accounts: [PersistedAccount] = [],
         agAccount: PersistedAg? = nil,
         refreshMinutes: Int = 15,
         alertThreshold: Int = 80) {
        self.accounts = accounts
        self.agAccount = agAccount
        self.refreshMinutes = refreshMinutes
        self.alertThreshold = alertThreshold
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = (try? c.decode([PersistedAccount].self, forKey: .accounts)) ?? []
        agAccount = try? c.decode(PersistedAg.self, forKey: .agAccount)
        refreshMinutes = (try? c.decode(Int.self, forKey: .refreshMinutes)) ?? 15
        alertThreshold = (try? c.decode(Int.self, forKey: .alertThreshold)) ?? 80
    }
}
