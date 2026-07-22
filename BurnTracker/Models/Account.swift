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

/// A single Claude.ai account. Persisted fields are `id`, `label`, `sessionKey`;
/// the rest are transient runtime state (stripped before writing to disk).
struct Account: Identifiable {
    let id: String
    var label: String
    var sessionKey: String

    /// The account's email address, fetched from `/api/bootstrap` and cached to
    /// disk so it shows immediately on the next launch.
    var email: String?

    // Transient runtime state
    var status: SyncStatus = .offline
    var quota: QuotaData?
    var lastFetchTime: Date?
    var errorMsg: String?
    var alertedHighUsage: Bool = false

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
    /// Edge-trigger latch for the 5-hour usage alert (mirrors `Account`).
    var alertedHighUsage: Bool = false
}
