import Foundation

/// Normalized token counts for one Claude usage line (or an aggregate).
struct TokenBreakdown: Equatable {
    var input = 0
    var output = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var cacheRead = 0

    /// All tokens, including cache reads/writes — matches ccusage's "tokens" total.
    var total: Int { input + output + cacheWrite5m + cacheWrite1h + cacheRead }

    static func + (a: TokenBreakdown, b: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(
            input: a.input + b.input,
            output: a.output + b.output,
            cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m,
            cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h,
            cacheRead: a.cacheRead + b.cacheRead)
    }
}

/// Aggregated usage for a single local calendar day.
struct DayUsage: Identifiable, Equatable {
    let day: Date        // start of the local day
    var tokens: Int
    var cost: Double
    var id: Date { day }
}

/// The Claude Code usage trend (from scanning local session logs), shared across
/// all Claude cards. `days` is ascending by date.
struct ClaudeUsageTrend: Equatable {
    var days: [DayUsage]
    var generatedAt: Date

    private static var cal: Calendar { Calendar.current }

    /// Totals for the local day containing `date`.
    private func total(on date: Date) -> DayUsage? {
        let start = Self.cal.startOfDay(for: date)
        return days.first { Self.cal.isDate($0.day, inSameDayAs: start) }
    }

    var today: DayUsage? { total(on: Date()) }

    var yesterday: DayUsage? {
        guard let y = Self.cal.date(byAdding: .day, value: -1, to: Date()) else { return nil }
        return total(on: y)
    }

    /// Sum over the whole scanned window (up to ~30 days).
    var last30: DayUsage {
        let tokens = days.reduce(0) { $0 + $1.tokens }
        let cost = days.reduce(0.0) { $0 + $1.cost }
        return DayUsage(day: Date(), tokens: tokens, cost: cost)
    }

    /// A dense trailing series of `count` days (oldest→newest) ending today, with
    /// zero-filled gaps — used to draw the sparkline bars.
    func series(count: Int) -> [DayUsage] {
        let cal = Self.cal
        let todayStart = cal.startOfDay(for: Date())
        var byDay: [Date: DayUsage] = [:]
        for d in days { byDay[cal.startOfDay(for: d.day)] = d }

        return (0..<count).reversed().compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: -offset, to: todayStart) else { return nil }
            return byDay[day] ?? DayUsage(day: day, tokens: 0, cost: 0)
        }
    }
}
