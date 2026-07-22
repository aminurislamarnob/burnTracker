import SwiftUI

/// One compact card per connected Claude.ai account — same design language as
/// the CLI provider cards: a header (label + masked key, then an "Updated …"
/// line), a hairline divider, then session + weekly quota bars. When the
/// account is idle (0% session), a "start a session" message box is shown.
struct ClaudeAccountCardView: View {
    @EnvironmentObject var app: AppState
    let account: Account

    @State private var sending = false

    var body: some View {
        Card {
            CompactCardHeader(
                title: account.label,
                detail: account.email ?? account.maskedKey,
                statusLine: statusLine,
                subtitle: "Claude.ai",
                iconName: "ProviderIcon-claude",
                iconTint: Theme.accent,
                onRefresh: { Task { await app.refreshAccount(id: account.id) } })
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
        default: return "Updated \(TimeFormat.relative(account.lastFetchTime))"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if account.status == .error {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sync Failed").font(.system(size: 12, weight: .bold))
                Text(account.errorMsg ?? "Unauthorized / Invalid Key")
                    .font(.system(size: 12))
            }
            .foregroundColor(Theme.error)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        } else if account.status == .syncing && account.quota == nil {
            Text("Syncing quotas…")
                .font(.system(size: 12))
                .foregroundColor(Theme.textDimmed)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            quotaBody
        }
    }

    private var quotaBody: some View {
        let quota = account.quota
        let sessionPct = quota?.sessionUtilization ?? 0
        let weeklyPct = quota?.weeklyUtilization ?? 0

        return VStack(alignment: .leading, spacing: 18) {
            CompactQuotaRow(
                title: "Current Session (5h)",
                percent: sessionPct,
                tint: usedTint(sessionPct, base: Theme.accent),
                leftText: "\(sessionPct)% used",
                rightText: quota?.sessionResetsAt != nil
                    ? "Resets \(TimeFormat.compactReset(quota?.sessionResetsAt))" : "Resets periodically")

            CompactQuotaRow(
                title: "Weekly Limit",
                percent: weeklyPct,
                tint: usedTint(weeklyPct, base: Theme.info),
                leftText: "\(weeklyPct)% used",
                rightText: quota?.weeklyResetsAt != nil
                    ? "Resets \(TimeFormat.compactReset(quota?.weeklyResetsAt))" : "Resets weekly")

            // Start-session button only when no session is currently running.
            if sessionPct == 0 {
                startButton
            }
        }
    }

    /// Used-quota semantics: neutral base tint, warns as usage climbs high.
    private func usedTint(_ percent: Int, base: Color) -> Color {
        if percent >= 95 { return Theme.error }
        if percent >= 80 { return Theme.warning }
        return base
    }

    private var startButton: some View {
        Button(sending ? "Opening…" : "Start session now") {
            sending = true
            app.startSession(account: account)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { sending = false }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(sending)
    }
}
