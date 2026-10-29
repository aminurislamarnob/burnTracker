import Foundation

/// Parsed Grok shared-pool usage from the CLI billing credits endpoint.
struct GrokQuota: Equatable {
    var planName: String?
    /// Weekly shared pool usage (0…100). Nil when the account is not on weekly billing.
    var weeklyUsedPct: Int?
    var weeklyPeriodEnd: Date?
    /// Pay-as-you-go cap in credits; nil or 0 means disabled.
    var onDemandCap: Double?

    var hasAnyMetric: Bool {
        weeklyUsedPct != nil || (onDemandCap ?? 0) > 0
    }
}

struct GrokAccount {
    var token: String
    var email: String?
    var status: SyncStatus = .offline
    var quota: GrokQuota?
    var lastFetch: Date?
    var statusMessage: String?
    var alertedHighUsage: Bool = false
}
