import Foundation

/// A single rate-limit window from the Claude usage payload.
/// Handles both snake_case and camelCase field naming, and either `resets_at`
/// or `resetsAt`, since the upstream private API naming is not guaranteed.
struct UsageWindow: Decodable {
    var utilization: Double
    var resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resets_at
        case resetsAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        utilization = (try? c.decode(Double.self, forKey: .utilization)) ?? 0
        if let r = try? c.decode(String.self, forKey: .resets_at) {
            resetsAt = r
        } else {
            resetsAt = try? c.decode(String.self, forKey: .resetsAt)
        }
    }
}

/// The pay-as-you-go / purchased-credit ("extra usage") block from the Claude
/// usage payload. Present only for Claude accounts; the bar is shown only when
/// `isEnabled` is true (an active extra-usage budget). Handles both snake_case
/// and camelCase, since the upstream private API naming is not guaranteed.
struct ExtraUsage: Decodable {
    var isEnabled: Bool
    var utilization: Double?
    var usedCredits: Double?
    var monthlyLimit: Double?
    var currency: String?
    var decimalPlaces: Int?
    var spendLimitReached: Bool

    enum CodingKeys: String, CodingKey {
        case is_enabled, isEnabled
        case utilization
        case used_credits, usedCredits
        case monthly_limit, monthlyLimit
        case currency
        case decimal_places, decimalPlaces
        case spend_limit_reached, spendLimitReached
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? c.decode(Bool.self, forKey: .is_enabled))
            ?? (try? c.decode(Bool.self, forKey: .isEnabled)) ?? false
        utilization = try? c.decode(Double.self, forKey: .utilization)
        usedCredits = (try? c.decode(Double.self, forKey: .used_credits))
            ?? (try? c.decode(Double.self, forKey: .usedCredits))
        monthlyLimit = (try? c.decode(Double.self, forKey: .monthly_limit))
            ?? (try? c.decode(Double.self, forKey: .monthlyLimit))
        currency = try? c.decode(String.self, forKey: .currency)
        decimalPlaces = (try? c.decode(Int.self, forKey: .decimal_places))
            ?? (try? c.decode(Int.self, forKey: .decimalPlaces))
        spendLimitReached = (try? c.decode(Bool.self, forKey: .spend_limit_reached))
            ?? (try? c.decode(Bool.self, forKey: .spendLimitReached)) ?? false
    }

    /// Percentage of the monthly extra-usage budget consumed (0–100), preferring
    /// the API's own `utilization`, falling back to used/limit.
    var utilizationPct: Int {
        if let u = utilization { return Int(u.rounded()) }
        if let used = usedCredits, let limit = monthlyLimit, limit > 0 {
            return Int((used / limit * 100).rounded())
        }
        return 0
    }

    /// A "$3.20 of $10.00"-style label when amounts + currency are known, else
    /// nil (callers fall back to the percentage). `decimalPlaces` is the display
    /// precision; amounts are treated as major units in the given currency.
    var amountLabel: String? {
        guard let used = usedCredits, let limit = monthlyLimit else { return nil }
        let symbol = Self.currencySymbol(currency)
        let places = decimalPlaces ?? 2
        return "\(symbol)\(Self.format(used, places: places)) of \(symbol)\(Self.format(limit, places: places))"
    }

    private static func format(_ value: Double, places: Int) -> String {
        String(format: "%.\(max(0, places))f", value)
    }

    private static func currencySymbol(_ code: String?) -> String {
        switch code?.uppercased() {
        case "USD", nil: return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        case "JPY": return "¥"
        default: return "\(code ?? "") "
        }
    }
}

/// The rate-limit payload from `GET /api/organizations/{orgId}/usage`.
/// Preserves the dual snake_case/camelCase handling from `src/renderer.js`.
struct QuotaData: Decodable {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    var extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case five_hour
        case fiveHour
        case seven_day
        case sevenDay
        case extra_usage
        case extraUsage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = (try? c.decode(UsageWindow.self, forKey: .five_hour))
            ?? (try? c.decode(UsageWindow.self, forKey: .fiveHour))
        sevenDay = (try? c.decode(UsageWindow.self, forKey: .seven_day))
            ?? (try? c.decode(UsageWindow.self, forKey: .sevenDay))
        extraUsage = (try? c.decode(ExtraUsage.self, forKey: .extra_usage))
            ?? (try? c.decode(ExtraUsage.self, forKey: .extraUsage))
    }

    /// Current 5-hour session utilization as a rounded percentage.
    var sessionUtilization: Int {
        guard let u = fiveHour?.utilization else { return 0 }
        return Int(u.rounded())
    }

    var sessionResetsAt: String? { fiveHour?.resetsAt }

    var weeklyUtilization: Int {
        guard let u = sevenDay?.utilization else { return 0 }
        return Int(u.rounded())
    }

    var weeklyResetsAt: String? { sevenDay?.resetsAt }
}
