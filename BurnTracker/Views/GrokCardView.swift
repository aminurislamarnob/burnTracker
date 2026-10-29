import SwiftUI

struct GrokCardView: View {
    let account: GrokAccount
    var isPinned: Bool = false
    var onTogglePin: (() -> Void)? = nil
    let onRefresh: () -> Void

    var body: some View {
        Card {
            CompactCardHeader(
                title: "Grok",
                detail: account.email,
                statusLine: statusLine,
                subtitle: planLine,
                iconName: "ProviderIcon-grok",
                iconTint: Theme.grokTint,
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
        if let msg = account.statusMessage { return msg }
        switch account.status {
        case .syncing where account.quota == nil: return "Updating…"
        case .error: return "Update failed"
        default: return "Updated \(TimeFormat.relative(account.lastFetch))"
        }
    }

    private var planLine: String {
        if let plan = account.quota?.planName { return "\(plan) · grok.com" }
        return "grok.com"
    }

    @ViewBuilder
    private var content: some View {
        if account.status == .error {
            stateText("Could not fetch Grok usage (run `grok login` and try again).",
                      color: Theme.error)
        } else if account.status == .syncing && account.quota == nil {
            stateText("Syncing Grok usage…", color: Theme.textDimmed)
        } else if let quota = account.quota, quota.hasAnyMetric {
            VStack(alignment: .leading, spacing: 18) {
                if let weekly = quota.weeklyUsedPct {
                    CompactQuotaRow(
                        title: "Weekly Limit",
                        percent: weekly,
                        tint: usedTint(weekly, base: Theme.grokTint),
                        leftText: "Shared pool",
                        rightText: resetText(quota.weeklyPeriodEnd))
                }
                if let cap = quota.onDemandCap, cap > 0 {
                    Text("Pay as you go: \(formatCap(cap)) cap")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.success)
                } else {
                    Text("Pay as you go: Disabled")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.textDimmed)
                }
            }
        } else {
            stateText("No weekly pool on this account (or billing shape changed).",
                      color: Theme.textDimmed)
        }
    }

    private func stateText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func usedTint(_ pct: Int, base: Color) -> Color {
        pct >= 90 ? Theme.error : (pct >= 75 ? Theme.warning : base)
    }

    private func resetText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return TimeFormat.compactReset(date)
    }

    private func formatCap(_ value: Double) -> String {
        if value.rounded() == value { return String(Int(value)) }
        return String(value)
    }
}
