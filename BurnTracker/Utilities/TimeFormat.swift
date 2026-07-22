import Foundation

/// Port of `formatTimeUntil` from `src/renderer.js`.
/// Converts a reset-target ISO date string into a remaining-time countdown.
enum TimeFormat {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ isoString: String) -> Date? {
        if let d = isoFractional.date(from: isoString) { return d }
        if let d = iso.date(from: isoString) { return d }
        // Fall back to a lenient parser for non-standard shapes.
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return df.date(from: isoString)
    }

    static func timeUntil(_ isoString: String?) -> String {
        guard let isoString, !isoString.isEmpty else { return "--" }
        guard let target = parseDate(isoString) else { return "soon" }

        let diff = target.timeIntervalSinceNow
        if diff <= 0 { return "any moment" }

        let totalMin = Int(diff / 60)
        let hrs = totalMin / 60
        let mins = totalMin % 60

        if hrs >= 24 {
            let dayFmt = DateFormatter()
            dayFmt.locale = Locale(identifier: "en_US")
            dayFmt.dateFormat = "EEE"                    // "Mon"
            let timeFmt = DateFormatter()
            timeFmt.locale = Locale(identifier: "en_US")
            timeFmt.dateFormat = "h:mm a"                // "3:00 PM"
            return "\(dayFmt.string(from: target)) \(timeFmt.string(from: target))"
        }
        if hrs > 0 { return "in \(hrs)h \(mins)m" }
        return "in \(mins)m"
    }

    /// A compact reset countdown for the CLI quota rows, e.g. "in 5h",
    /// "in 6d 13h", "in 45m". Accepts either an ISO date or an already-formatted
    /// duration string from the upstream API (passed through as-is).
    static func compactReset(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "—" }

        // If it parses as a date, format the remaining time compactly.
        if let target = parseDate(raw) {
            let diff = target.timeIntervalSinceNow
            if diff <= 0 { return "any moment" }
            let totalMin = Int(diff / 60)
            let days = totalMin / 1440
            let hrs = (totalMin % 1440) / 60
            let mins = totalMin % 60
            if days >= 1 { return hrs > 0 ? "in \(days)d \(hrs)h" : "in \(days)d" }
            if hrs >= 1 { return "in \(hrs)h" }
            return "in \(mins)m"
        }

        // Otherwise it's already a friendly duration ("5h", "6d 13h"): keep it.
        let lower = raw.lowercased()
        if lower.hasPrefix("in ") || lower == "any moment" || lower == "soon" { return raw }
        return "in \(raw)"
    }

    /// A short "how long ago" label, e.g. "just now", "3m ago", "2h ago".
    /// Used for the compact "Updated …" line on provider cards.
    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        let secs = max(0, -date.timeIntervalSinceNow)
        if secs < 45 { return "just now" }
        let mins = Int(secs / 60)
        if mins < 60 { return "\(max(1, mins))m ago" }
        let hrs = mins / 60
        if hrs < 24 { return "\(hrs)h ago" }
        return "\(hrs / 24)d ago"
    }
}
