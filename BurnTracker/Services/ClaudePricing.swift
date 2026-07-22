import Foundation

/// Estimates the USD cost of Claude token usage, since Claude Code's session
/// logs no longer carry `costUSD`. Rates are Anthropic's published per-model
/// prices (USD per million tokens); cache writes bill at 1.25× (5-minute) and
/// 2× (1-hour) the input rate, cache reads at 0.1×.
///
/// This mirrors what `ccusage` / OpenUsage do: dollar figures are *estimates*,
/// close to but not guaranteed to match claude.ai billing. Unknown models
/// return nil (their tokens are left unpriced rather than guessed).
enum ClaudePricing {
    /// Per-token rates (already divided from the per-million published prices).
    struct Rate {
        let input: Double
        let output: Double
        let cacheWrite5m: Double
        let cacheWrite1h: Double
        let cacheRead: Double

        /// Build from per-million input/output prices using Anthropic's standard
        /// cache multipliers (5m = 1.25×in, 1h = 2×in, read = 0.1×in).
        init(inputPerM: Double, outputPerM: Double) {
            input = inputPerM / 1_000_000
            output = outputPerM / 1_000_000
            cacheWrite5m = inputPerM * 1.25 / 1_000_000
            cacheWrite1h = inputPerM * 2.0 / 1_000_000
            cacheRead = inputPerM * 0.1 / 1_000_000
        }
    }

    private static let opus = Rate(inputPerM: 15, outputPerM: 75)
    private static let sonnet = Rate(inputPerM: 3, outputPerM: 15)
    private static let haiku = Rate(inputPerM: 0.80, outputPerM: 4)     // Haiku 3.5 / 4.x
    private static let haiku3 = Rate(inputPerM: 0.25, outputPerM: 1.25) // legacy Haiku 3

    /// Resolve a model slug (e.g. "claude-opus-4-8", "claude-3-5-haiku-...") to a rate.
    static func rate(for model: String) -> Rate? {
        let m = model.lowercased()
        if m.contains("opus") { return opus }
        if m.contains("sonnet") { return sonnet }
        if m.contains("haiku") {
            return (m.contains("claude-3-haiku") || m.contains("-3-haiku")) ? haiku3 : haiku
        }
        return nil
    }

    /// Estimated USD cost for one line's tokens, or nil for an unknown model.
    static func cost(model: String, tokens: TokenBreakdown) -> Double? {
        guard let r = rate(for: model) else { return nil }
        return Double(tokens.input) * r.input
            + Double(tokens.output) * r.output
            + Double(tokens.cacheWrite5m) * r.cacheWrite5m
            + Double(tokens.cacheWrite1h) * r.cacheWrite1h
            + Double(tokens.cacheRead) * r.cacheRead
    }
}
