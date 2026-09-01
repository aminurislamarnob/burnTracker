import Foundation

/// Identifies the single reading the user has pinned to the menu bar — a
/// provider's current 5-hour session, or one Claude account's model-scoped
/// weekly cap (e.g. Fable).
///
/// Persisted as a flat string token (`"claude:acc_123"`, `"gemini"`,
/// `"claude-model:acc_123:Fable"`, …) so the settings file stays the simple
/// JSON shape the original Electron build wrote.
enum PinnedProvider: Equatable {
    /// A specific Claude.ai account's 5-hour session, by `Account.id`.
    case claude(String)
    /// One Claude account's weekly cap for a single model, keyed by the API's
    /// own `scope.model.display_name` (e.g. "Fable") rather than a fixed list,
    /// so a newly scoped model is pinnable without a code change.
    case claudeModelWeekly(accountId: String, model: String)
    case gemini
    case antigravity
    case commandCode

    var token: String {
        switch self {
        case .claude(let id): return "claude:\(id)"
        case .claudeModelWeekly(let id, let model): return "claude-model:\(id):\(model)"
        case .gemini:         return "gemini"
        case .antigravity:    return "antigravity"
        case .commandCode:    return "commandCode"
        }
    }

    init?(token: String) {
        // Checked before the "claude:" prefix so the longer, more specific
        // scheme wins; the model name keeps any colons it may contain.
        if token.hasPrefix("claude-model:") {
            let rest = String(token.dropFirst("claude-model:".count))
            guard let sep = rest.firstIndex(of: ":") else { return nil }
            let id = String(rest[rest.startIndex..<sep])
            let model = String(rest[rest.index(after: sep)...])
            guard !id.isEmpty, !model.isEmpty else { return nil }
            self = .claudeModelWeekly(accountId: id, model: model)
            return
        }
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
