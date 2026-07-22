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

    // Transient runtime state
    var status: SyncStatus = .offline
    var quota: QuotaData?
    var lastFetchTime: Date?
    var errorMsg: String?
    var alertedHighUsage: Bool = false

    init(id: String = "acc_\(Int(Date().timeIntervalSince1970 * 1000))",
         label: String,
         sessionKey: String,
         status: SyncStatus = .offline) {
        self.id = id
        self.label = label
        self.sessionKey = sessionKey
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

/// The Antigravity / Gemini CLI linked account.
struct AgAccount {
    var token: String
    var email: String?
    var status: SyncStatus = .offline
    var gemini: AGGroup?
    var claudeGpt: AGGroup?
}
