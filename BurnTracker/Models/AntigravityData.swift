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
    /// The linked Command Code account (`cmd` CLI, commandcode.ai API).
    var commandCodeAccount: PersistedAg?
    /// Token of the provider pinned to the menu bar (see `PinnedProvider`).
    var pinnedProvider: String?
    var refreshMinutes: Int
    var alertThreshold: Int
    var cardOrder: [String]?

    enum CodingKeys: String, CodingKey {
        case accounts, agAccount, geminiAccount, commandCodeAccount, pinnedProvider
        case refreshMinutes, alertThreshold, cardOrder
    }

    init(accounts: [PersistedAccount] = [],
         agAccount: PersistedAg? = nil,
         geminiAccount: PersistedAg? = nil,
         commandCodeAccount: PersistedAg? = nil,
         pinnedProvider: String? = nil,
         refreshMinutes: Int = 15,
         alertThreshold: Int = 80,
         cardOrder: [String]? = nil) {
        self.accounts = accounts
        self.agAccount = agAccount
        self.geminiAccount = geminiAccount
        self.commandCodeAccount = commandCodeAccount
        self.pinnedProvider = pinnedProvider
        self.refreshMinutes = refreshMinutes
        self.alertThreshold = alertThreshold
        self.cardOrder = cardOrder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = (try? c.decode([PersistedAccount].self, forKey: .accounts)) ?? []
        agAccount = try? c.decode(PersistedAg.self, forKey: .agAccount)
        geminiAccount = try? c.decode(PersistedAg.self, forKey: .geminiAccount)
        commandCodeAccount = try? c.decode(PersistedAg.self, forKey: .commandCodeAccount)
        pinnedProvider = try? c.decode(String.self, forKey: .pinnedProvider)
        refreshMinutes = (try? c.decode(Int.self, forKey: .refreshMinutes)) ?? 15
        alertThreshold = (try? c.decode(Int.self, forKey: .alertThreshold)) ?? 80
        cardOrder = try? c.decode([String].self, forKey: .cardOrder)
    }
}
