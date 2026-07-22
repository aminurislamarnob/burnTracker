import Foundation

enum NumberFormat {
    /// Compact token counts: 812, 21.1K, 21.1M, 2.8B.
    static func tokens(_ n: Int) -> String {
        let v = Double(n)
        switch abs(v) {
        case 1_000_000_000...: return trim(v / 1_000_000_000) + "B"
        case 1_000_000...:     return trim(v / 1_000_000) + "M"
        case 1_000...:         return trim(v / 1_000) + "K"
        default:               return "\(n)"
        }
    }

    /// Compact spend: $0.08, $15.78, $101.49, $2.5K.
    static func dollars(_ v: Double) -> String {
        if abs(v) >= 1_000 { return "$" + trim(v / 1_000) + "K" }
        return String(format: "$%.2f", v)
    }

    /// One decimal, but drop a trailing ".0" (21.0 → "21", 21.1 → "21.1").
    private static func trim(_ v: Double) -> String {
        let s = String(format: "%.1f", v)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
}
