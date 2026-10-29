import SwiftUI

struct CopilotCardView: View {
    let account: CopilotAccount
    var isPinned: Bool = false
    var onTogglePin: (() -> Void)? = nil
    let onRefresh: () -> Void

    var body: some View {
        Card {
            CompactCardHeader(
                title: "GitHub Copilot",
                detail: account.email,
                statusLine: statusLine,
                subtitle: planLine,
                iconName: "ProviderIcon-copilot",
                iconTint: Theme.copilotTint,
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
        if let plan = account.quota?.planName { return "\(plan) · github.com" }
        return "github.com"
    }

    @ViewBuilder
    private var content: some View {
        if account.status == .error {
            stateText("Could not fetch Copilot usage (run `copilot login` and try again).",
                      color: Theme.error)
        } else if account.status == .syncing && account.quota == nil {
            stateText("Syncing Copilot usage…", color: Theme.textDimmed)
        } else if let quota = account.quota, quota.hasAnyMetric {
            if quota.isOrgManagedSeat && quota.creditsUsedPct == nil
                && quota.chatUsedPct == nil && quota.completionsUsedPct == nil {
                stateText("Org-managed seat — no per-seat quota on this plan.",
                          color: Theme.textDimmed)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    if let pct = quota.creditsUsedPct {
                        CompactQuotaRow(
                            title: "Credits",
                            percent: pct,
                            tint: usedTint(pct, base: Theme.copilotTint),
                            leftText: creditsLeftText(quota),
                            rightText: resetText(quota.resetAt))
                    }
                    if let overage = quota.overageCount {
                        Text("Extra Usage: \(formatCount(overage))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(overage > 0 ? Theme.creditTint : Theme.textDimmed)
                    }
                    if let chat = quota.chatUsedPct {
                        CompactQuotaRow(
                            title: "Chat",
                            percent: chat,
                            tint: usedTint(chat, base: Theme.info),
                            leftText: "Monthly chat",
                            rightText: resetText(quota.resetAt))
                    }
                    if let completions = quota.completionsUsedPct {
                        CompactQuotaRow(
                            title: "Completions",
                            percent: completions,
                            tint: usedTint(completions, base: Theme.success),
                            leftText: "Monthly completions",
                            rightText: resetText(quota.resetAt))
                    }
                }
            }
        } else {
            stateText("No Copilot usage data yet.", color: Theme.textDimmed)
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

    private func creditsLeftText(_ quota: CopilotQuota) -> String {
        if let remaining = quota.creditsRemaining, let entitlement = quota.creditsEntitlement,
           entitlement > 0 {
            return "\(formatCount(remaining)) left of \(formatCount(entitlement))"
        }
        return "Monthly allotment"
    }

    private func formatCount(_ value: Double) -> String {
        if value.rounded() == value { return String(Int(value)) }
        return String(format: "%.1f", value)
    }
}
