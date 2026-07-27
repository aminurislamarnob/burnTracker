import Foundation

/// Identifies the single provider the user has pinned to the menu bar for an
/// at-a-glance read of its current 5-hour session.
///
/// Persisted as a flat string token (`"claude:acc_123"`, `"gemini"`, …) so the
/// settings file stays the simple JSON shape the original Electron build wrote.
enum PinnedProvider: Equatable {
    /// A specific Claude.ai account, by `Account.id`.
    case claude(String)
    case gemini
    case antigravity
    case commandCode

    var token: String {
        switch self {
        case .claude(let id): return "claude:\(id)"
        case .gemini:         return "gemini"
        case .antigravity:    return "antigravity"
        case .commandCode:    return "commandCode"
        }
    }

    init?(token: String) {
        if token.hasPrefix("claude:") {
            let id = String(token.dropFirst("claude:".count))
            guard !id.isEmpty else { return nil }
            self = .claude(id)
            return
        }
        switch token {
        case "gemini":      self = .gemini
        case "antigravity": self = .antigravity
        case "commandCode": self = .commandCode
        default:            return nil
        }
    }
}

/// What the menu bar renders for the pinned provider: a short name and the
/// current 5-hour usage percentage.
struct PinnedSummary: Equatable {
    var label: String
    var percent: Int
}
