import SwiftUI

struct CursorCardView: View {
    let account: CursorAccount
    var isPinned: Bool = false
    var onTogglePin: (() -> Void)? = nil
    let onRefresh: () -> Void

    var body: some View {
        Card {
            CompactCardHeader(
                title: "Cursor",
                detail: account.email,
                statusLine: statusLine,
                subtitle: planLine,
                iconName: "ProviderIcon-cursor",
                iconTint: Theme.cursorTint,
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
        if let plan = account.quota?.planName { return "\(plan) plan · cursor.com" }
        return "cursor.com"
    }

    @ViewBuilder
    private var content: some View {
        if account.status == .error {
            stateText("Could not fetch Cursor usage (is the Cursor app signed in?)",
                      color: Theme.error)
        } else if account.status == .syncing && account.quota == nil {
            stateText("Syncing Cursor usage…", color: Theme.textDimmed)
        } else if let quota = account.quota, quota.hasAnyMetric {
            VStack(alignment: .leading, spacing: 18) {
                if let pct = quota.totalUsedPct {
                    CompactQuotaRow(
                        title: "Total Usage",
                        percent: pct,
                        tint: usedTint(pct, base: Theme.cursorTint),
                        leftText: "Billing cycle",
                        rightText: resetText(quota.billingCycleEnd))
                } else if let used = quota.requestsUsed, let limit = quota.requestsLimit, limit > 0 {
                    let pct = Int(min(100, Double(used) / Double(limit) * 100).rounded())
                    CompactQuotaRow(
                        title: "Requests",
                        percent: pct,
                        tint: usedTint(pct, base: Theme.cursorTint),
                        leftText: "\(used) of \(limit) requests",
                        rightText: "—")
                }
                if let auto = quota.autoUsedPct {
                    CompactQuotaRow(
                        title: "Auto Usage",
                        percent: auto,
                        tint: usedTint(auto, base: Theme.info),
                        leftText: "Auto model pool",
                        rightText: resetText(quota.billingCycleEnd))
                }
                if let api = quota.apiUsedPct {
                    CompactQuotaRow(
                        title: "API Usage",
                        percent: api,
                        tint: usedTint(api, base: Theme.warning),
                        leftText: "API pool",
                        rightText: resetText(quota.billingCycleEnd))
                }
                if let limit = quota.onDemandLimitUSD, limit > 0, let spent = quota.onDemandSpentUSD {
                    let pct = Int(min(100, spent / limit * 100).rounded())
                    CompactQuotaRow(
                        title: "Extra Usage",
                        percent: pct,
                        tint: usedTint(pct, base: Theme.creditTint),
                        leftText: "\(NumberFormat.dollars(limit - spent)) left of \(NumberFormat.dollars(limit))",
                        rightText: "On-demand")
                }
                if let credits = quota.creditsRemainingUSD, credits > 0 {
                    Text("Credits: \(NumberFormat.dollars(credits)) remaining")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.textMuted)
                }
            }
        } else {
            stateText("No Cursor usage data yet.", color: Theme.textDimmed)
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
}
