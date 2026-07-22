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

/// The rate-limit payload from `GET /api/organizations/{orgId}/usage`.
/// Preserves the dual snake_case/camelCase handling from `src/renderer.js`.
struct QuotaData: Decodable {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?

    enum CodingKeys: String, CodingKey {
        case five_hour
        case fiveHour
        case seven_day
        case sevenDay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = (try? c.decode(UsageWindow.self, forKey: .five_hour))
            ?? (try? c.decode(UsageWindow.self, forKey: .fiveHour))
        sevenDay = (try? c.decode(UsageWindow.self, forKey: .seven_day))
            ?? (try? c.decode(UsageWindow.self, forKey: .sevenDay))
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
