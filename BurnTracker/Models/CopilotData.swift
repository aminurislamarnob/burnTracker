import Foundation

/// Parsed GitHub Copilot usage from `/copilot_internal/user`.
struct CopilotQuota: Equatable {
    var planName: String?
    /// Monthly AI Credits / premium interactions used percent (0…100).
    var creditsUsedPct: Int?
    var creditsEntitlement: Double?
    var creditsRemaining: Double?
    /// Premium interactions consumed beyond the included pool (only when overage is enabled).
    var overageCount: Double?
    /// Free-tier chat meter; nil on paid plans (unlimited).
    var chatUsedPct: Int?
    /// Free-tier completions meter; nil on paid plans (unlimited).
    var completionsUsedPct: Int?
    var resetAt: Date?
    /// Org-managed Business seats with no per-seat meters.
    var isOrgManagedSeat: Bool = false

    /// Primary meter for pin + alerts — Credits when present, else Chat.
    var primaryUsedPct: Int? { creditsUsedPct ?? chatUsedPct }

    var hasAnyMetric: Bool {
        creditsUsedPct != nil
            || chatUsedPct != nil
            || completionsUsedPct != nil
            || overageCount != nil
            || isOrgManagedSeat
    }
}

struct CopilotAccount {
    var token: String
    var email: String?
    var status: SyncStatus = .offline
    var quota: CopilotQuota?
    var lastFetch: Date?
    var statusMessage: String?
    var alertedHighUsage: Bool = false
}
