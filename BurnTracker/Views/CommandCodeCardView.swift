import SwiftUI

/// The quota card for the linked Command Code account (`cmd` CLI). Same design
/// language as the other provider cards, but the metrics differ: Command Code
/// bills in credits, so the primary bar is the monthly credit pool, followed by
/// its 5-hour / weekly request windows when the plan enforces them.
///
/// All bars here read as ***used*** (like the Claude card), not remaining like
/// `CliQuotaCardView` — the API reports spend and usage counts directly.
struct CommandCodeCardView: View {
    let account: CommandCodeAccount
    var isPinned: Bool = false
    var onTogglePin: (() -> Void)? = nil
    let onRefresh: () -> Void

    var body: some View {
        Card {
            CompactCardHeader(
                title: "Command Code",
                detail: account.email,
                statusLine: statusLine,
                subtitle: planLine,
                iconName: "ProviderIcon-commandcode",
                iconTint: Theme.commandCodeTint,
                isPinned: isPinned,
                onTogglePin: onTogglePin,
                onRefresh: onRefresh)
                .padding(.bottom, 10)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            content
                .padding(.top, 14)
        }
    }

    private var statusLine: String {
        switch account.status {
        case .syncing where account.quota == nil: return "Updating…"
        case .error: return "Update failed"
        default: return "Updated \(TimeFormat.relative(account.lastFetch))"
        }
    }

    /// Plan name, plus the period's request count once the summary is in.
    private var planLine: String {
        var parts: [String] = []
        if let plan = account.quota?.planName { parts.append("\(plan) plan") }
        if let count = account.quota?.requestCount {
            parts.append("\(count) request\(count == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "commandcode.ai" : parts.joined(separator: " · ")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if account.status == .error {
            stateText("Could not fetch Command Code quota (is the `cmd` CLI signed in?)",
                      color: Theme.error)
        } else if account.status == .syncing && account.quota == nil {
            stateText("Syncing Command Code quotas…", color: Theme.textDimmed)
        } else if let quota = account.quota, hasAnyMetric(quota) {
            VStack(alignment: .leading, spacing: 18) {
                if quota.hasCreditsInfo {
                    CompactQuotaRow(
                        title: "Monthly Credits",
                        percent: quota.creditsUsedPct,
                        tint: usedTint(quota.creditsUsedPct, base: Theme.commandCodeTint),
                        leftText: "\(NumberFormat.dollars(quota.totalRemaining)) left of \(NumberFormat.dollars(quota.totalPool))",
                        rightText: renewalText(quota))
                }
                if let five = quota.fiveHour {
                    windowRow("5-Hour Limit", five, base: Theme.commandCodeTint)
                }
                if let weekly = quota.weekly {
                    windowRow("Weekly Limit", weekly, base: Theme.info)
                }
            }
        } else {
            stateText("No quota data available", color: Theme.textDimmed)
        }
    }

    private func hasAnyMetric(_ quota: CommandCodeQuota) -> Bool {
        quota.hasCreditsInfo || quota.fiveHour != nil || quota.weekly != nil
    }

    private func windowRow(_ title: String, _ window: CommandCodeWindow, base: Color) -> CompactQuotaRow {
        CompactQuotaRow(
            title: title,
            percent: window.usedPct,
            tint: usedTint(window.usedPct, base: base),
            leftText: "\(count(window.used)) of \(count(window.cap)) used",
            rightText: resetText(window))
    }

    /// A window with no `resetAt` has not started yet — nothing has been spent
    /// against it, so there is no countdown to show.
    private func resetText(_ window: CommandCodeWindow) -> String {
        if window.exceeded && window.resetAt == nil { return "Limit reached" }
        guard let resetAt = window.resetAt else { return "Not started" }
        return "Resets \(TimeFormat.compactReset(resetAt))"
    }

    private func renewalText(_ quota: CommandCodeQuota) -> String {
        guard let days = quota.daysToRenewal else { return "Monthly" }
        if days == 0 { return "Renews today" }
        return "Renews in \(days) day\(days == 1 ? "" : "s")"
    }

    /// Window counts are whole requests in practice; drop a pointless ".0".
    private func count(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    /// Used-quota semantics: brand tint, warning as usage climbs high.
    private func usedTint(_ percent: Int, base: Color) -> Color {
        if percent >= 95 { return Theme.error }
        if percent >= 80 { return Theme.warning }
        return base
    }

    private func stateText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }
}
