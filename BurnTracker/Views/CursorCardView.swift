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
            // Same field → label mapping as Orca: auto → Cursor Models, api → Other Models,
            // total → Plan. Numbers come from GetCurrentPeriodUsage.planUsage.
            VStack(alignment: .leading, spacing: 18) {
                if let auto = quota.autoUsedPct {
                    usedRow(title: "Cursor Models", percent: auto, reset: quota.billingCycleEnd,
                            tint: Theme.cursorTint)
                }
                if let api = quota.apiUsedPct {
                    usedRow(title: "Other Models", percent: api, reset: quota.billingCycleEnd,
                            tint: Theme.info)
                }
                if let pct = quota.totalUsedPct {
                    usedRow(title: "Plan", percent: pct, reset: quota.billingCycleEnd,
                            tint: Theme.cursorTint)
                } else if let used = quota.requestsUsed, let limit = quota.requestsLimit, limit > 0 {
                    let pct = Int(min(100, Double(used) / Double(limit) * 100).rounded())
                    CompactQuotaRow(
                        title: "Requests",
                        percent: pct,
                        tint: usedTint(pct, base: Theme.cursorTint),
                        leftText: "\(pct)% used",
                        rightText: "\(used) of \(limit)")
                }
                if let limit = quota.onDemandLimitUSD, limit > 0, let spent = quota.onDemandSpentUSD {
                    let pct = Int(min(100, spent / limit * 100).rounded())
                    CompactQuotaRow(
                        title: "On-demand",
                        percent: pct,
                        tint: usedTint(pct, base: Theme.creditTint),
                        leftText: "\(pct)% used",
                        rightText: "\(NumberFormat.dollars(spent)) of \(NumberFormat.dollars(limit))")
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

    private func usedRow(title: String, percent: Int, reset: Date?, tint: Color) -> CompactQuotaRow {
        CompactQuotaRow(
            title: title,
            percent: percent,
            tint: usedTint(percent, base: tint),
            leftText: "\(percent)% used",
            rightText: "Resets \(resetText(reset))")
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
