import Foundation

/// One rate-limit window (5-hour or weekly) from the `windowLimits` block of the
/// Command Code `/alpha/billing/credits` response. Unlike the Antigravity /
/// Gemini buckets — which report a *remaining* fraction — these report an
/// absolute `used` count against a `cap`.
struct CommandCodeWindow {
    var used: Double
    var cap: Double
    var exceeded: Bool
    /// Absolute reset time, or nil when the API reports `resetAt: 0` — meaning
    /// no window is currently running (nothing has been spent yet).
    var resetAt: Date?

    /// Usage as a percentage of the cap, clamped to 0…100.
    var usedPct: Int {
        guard cap > 0 else { return 0 }
        return Int(min(100, max(0, used / cap * 100)).rounded())
    }
}

/// A parsed Command Code quota snapshot.
///
/// Command Code bills in **credits** (dollars) against a monthly plan
/// allowance, and optionally enforces 5-hour / weekly request windows on top.
/// That is a different shape from the remaining-fraction model families used by
/// `AntigravityService` / `GeminiService`, which is why this provider has its
/// own model and card rather than reusing `AGGroup` / `CliQuotaResult`.
///
/// The credit projection (`totalPool`, `creditsUsedPct`) is a port of the CLI's
/// own `projectUsageView` — see `CommandCodeService` for the derivation.
struct CommandCodeQuota {
    /// Friendly plan name ("Go", "Pro", "Max", …), nil for an unknown plan id.
    var planName: String?
    /// Subscription status as reported by the API ("active", "canceled", …).
    var planStatus: String?
    /// End of the current billing period, when the credit allowance renews.
    var periodEnd: Date?

    // Remaining credit balances, in dollars.
    var monthlyRemaining: Double
    var purchasedRemaining: Double
    var freeRemaining: Double

    /// Total spent this billing period (`/alpha/usage/summary` → `totalCost`).
    var totalSpent: Double
    /// Number of requests this billing period, when the summary is available.
    var requestCount: Int?

    /// The full credit pool the remaining balance is measured against.
    var totalPool: Double
    /// True once there is any balance or spend to report — mirrors the CLI's
    /// `hasCreditsInfo`, which gates the whole credit meter.
    var hasCreditsInfo: Bool
    /// Percentage of `totalPool` consumed.
    var creditsUsedPct: Int

    var fiveHour: CommandCodeWindow?
    var weekly: CommandCodeWindow?

    /// Total credits still available across monthly, purchased, and free.
    var totalRemaining: Double {
        monthlyRemaining + purchasedRemaining + freeRemaining
    }

    /// Whole days until the plan renews, or nil without a known period end.
    var daysToRenewal: Int? {
        guard let periodEnd else { return nil }
        let secs = periodEnd.timeIntervalSinceNow
        return max(0, Int((secs / 86_400).rounded(.up)))
    }
}
