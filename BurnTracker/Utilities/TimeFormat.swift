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
}
