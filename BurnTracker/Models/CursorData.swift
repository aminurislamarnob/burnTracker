import Foundation

/// Parsed Cursor plan usage for the current billing cycle.
struct CursorQuota: Equatable {
    var planName: String?
    /// Total plan usage for the billing cycle (0…100), or nil on request-only plans.
    var totalUsedPct: Int?
    var autoUsedPct: Int?
    var apiUsedPct: Int?
    /// Legacy / Enterprise request counts when percent-based plan usage is unavailable.
    var requestsUsed: Int?
    var requestsLimit: Int?
    var onDemandSpentUSD: Double?
    var onDemandLimitUSD: Double?
    var creditsRemainingUSD: Double?
    var billingCycleEnd: Date?

    /// Primary meter for the card header pin and usage alerts.
    var primaryUsedPct: Int? {
        if let totalUsedPct { return totalUsedPct }
        if let requestsUsed, let requestsLimit, requestsLimit > 0 {
            return Int(min(100, max(0, Double(requestsUsed) / Double(requestsLimit) * 100)).rounded())
        }
        return nil
    }

    var hasAnyMetric: Bool {
        totalUsedPct != nil || autoUsedPct != nil || apiUsedPct != nil
            || (requestsLimit ?? 0) > 0 || (onDemandLimitUSD ?? 0) > 0
            || (onDemandSpentUSD ?? 0) > 0 || (creditsRemainingUSD ?? 0) > 0
    }
}

struct CursorAccount {
    var token: String
    var email: String?
    var status: SyncStatus = .offline
    var quota: CursorQuota?
    var lastFetch: Date?
    var statusMessage: String?
    var alertedHighUsage: Bool = false
}
