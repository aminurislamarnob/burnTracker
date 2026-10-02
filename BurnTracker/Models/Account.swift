import Foundation

enum SyncStatus: String {
    case offline
    case syncing
    case online
    case error
}

enum GlobalStatus: String {
    case offline
    case syncing
    case online
    case warning
    case error
}

/// How a Claude account is connected.
enum ClaudeAccountSource {
    /// A claude.ai `sessionKey` cookie the user pasted in.
    case sessionKey
    /// The login Claude Code (the `claude` CLI) holds on this Mac. At most one;
    /// it always has `Account.claudeCodeId` and an empty `sessionKey`.
    case claudeCode
}

/// A single Claude account. Persisted fields are `id`, `label`, `sessionKey`;
/// the rest are transient runtime state (stripped before writing to disk).
///
/// The Claude Code account lives in `AppState.accounts` alongside the
/// session-key ones, so cards, pins, alerts and ordering treat it as any other
/// Claude account — but it is persisted under its own `claudeCodeAccount` key,
/// never in `accounts`, so the Electron build never sees a keyless account.
struct Account: Identifiable {
    /// The fixed id of the Claude Code account (pin token `claude:claude-code`).
    static let claudeCodeId = "claude-code"

    let id: String
    var label: String
    var sessionKey: String
    var source: ClaudeAccountSource = .sessionKey

    /// The account's email address, fetched from `/api/bootstrap` and cached to
    /// disk so it shows immediately on the next launch.
    var email: String?

    // Transient runtime state
    var status: SyncStatus = .offline
    var quota: QuotaData?
    var lastFetchTime: Date?
    var errorMsg: String?
    var alertedHighUsage: Bool = false
    /// Edge-trigger latches for the model-scoped weekly caps, keyed by the API's
    /// model display name — one latch per cap, so Fable crossing the threshold
    /// never disarms a later alert for another scoped model.
    var alertedModelWeekly: Set<String> = []
    /// Claude Code only: the signed-in account's uuid, so a `claude login` as
    /// someone else can be told apart from a normal refresh.
    var accountUuid: String?
    /// Claude Code only: a non-fatal notice (rate limiting) shown in place of
    /// the "Updated …" line while the last good quota stays on screen.
    var noticeMsg: String?

    var isClaudeCode: Bool { source == .claudeCode }

    init(id: String = "acc_\(Int(Date().timeIntervalSince1970 * 1000))",
         label: String,
         sessionKey: String,
         email: String? = nil,
         status: SyncStatus = .offline) {
        self.id = id
        self.label = label
        self.sessionKey = sessionKey
        self.email = email
        self.status = status
    }

    /// Masked session key for display in settings (mirrors `buildAccountViewRow`).
    var maskedKey: String {
        let key = sessionKey
        if key.count > 20 {
            let prefix = key.prefix(12)
            let suffix = key.suffix(6)
            return "\(prefix)...\(suffix)"
        }
        return "••••••••••••"
    }
}

/// A linked CLI quota account — used for both the Antigravity IDE and the
/// Gemini CLI providers. Holds the transient per-provider quota state.
struct CliAccount {
    var token: String
    var email: String?
    var status: SyncStatus = .offline
    var gemini: AGGroup?
    var claudeGpt: AGGroup?
    var lastFetch: Date?
    /// Why the last fetch failed, when the provider can say something more
    /// useful than the card's generic message. Cleared on success.
    var statusMessage: String?
    /// Edge-trigger latch for the 5-hour usage alert (mirrors `Account`).
    var alertedHighUsage: Bool = false
}

/// A linked Command Code account (the `cmd` CLI). Its quota is credit-based
/// rather than the remaining-fraction model families the other CLI providers
/// expose, so it carries a `CommandCodeQuota` instead of `AGGroup`s.
struct CommandCodeAccount {
    var token: String
    var email: String?
    var status: SyncStatus = .offline
    var quota: CommandCodeQuota?
    var lastFetch: Date?
    /// Edge-trigger latch for the 5-hour usage alert (mirrors `Account`).
    var alertedHighUsage: Bool = false
}
