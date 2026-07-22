import SwiftUI

/// The "Claude.ai Accounts" card: one section per account with session +
/// weekly quota bars and, when idle, a message-to-start-a-session box.
struct AccountCardView: View {
    @EnvironmentObject var app: AppState

    private var aggregateStatus: SyncStatus {
        if app.accounts.contains(where: { $0.status == .error }) { return .error }
        if app.accounts.contains(where: { $0.status == .syncing }) { return .syncing }
        return .online
    }

    var body: some View {
        Card {
            HStack {
                PulseDot(status: aggregateStatus)
                Text("Claude.ai Accounts")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textMain)
                Spacer()
                IconButton(systemName: "arrow.clockwise", help: "Refresh All Claude Accounts", size: 14) {
                    Task { await app.refreshAll() }
                }
            }
            .padding(.bottom, 12)

            ForEach(Array(app.accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 {
                    Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 16)
                }
                AccountSectionView(account: account)
            }
        }
    }
}

private struct AccountSectionView: View {
    @EnvironmentObject var app: AppState
    let account: Account

    @State private var draftMessage: String = ""
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                PulseDot(status: account.status)
                Text(account.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.accentHover)
                Spacer()
                IconButton(systemName: "arrow.clockwise", help: "Refresh Account", size: 12) {
                    Task { await app.refreshAccount(id: account.id) }
                }
            }
            .padding(.bottom, 12)

            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if account.status == .error {
            VStack(spacing: 2) {
                Text("Sync Failed:").font(.system(size: 12, weight: .bold))
                Text(account.errorMsg ?? "Unauthorized / Invalid Key")
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
            }
            .foregroundColor(Theme.error)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        } else if account.status == .syncing && account.quota == nil {
            Text("Syncing quotas...")
                .font(.system(size: 12))
                .foregroundColor(Theme.textDimmed)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        } else {
            quotaBody
        }
    }

    private var quotaBody: some View {
        let quota = account.quota
        let sessionPct = quota?.sessionUtilization ?? 0
        let weeklyPct = quota?.weeklyUtilization ?? 0
        let sessionReset = quota?.sessionResetsAt
        let weeklyReset = quota?.weeklyResetsAt

        let sessionStyle: BarStyle = sessionPct >= 95 ? .danger : sessionPct >= 80 ? .warning : .accent
        let weeklyStyle: BarStyle = weeklyPct >= 95 ? .danger : weeklyPct >= 80 ? .warning : .weekly

        return VStack(alignment: .leading, spacing: 24) {
            QuotaItemView(
                title: "Current Session (5h Window)",
                desc: "\(sessionPct)% used",
                footer: sessionReset != nil ? "Resets \(TimeFormat.timeUntil(sessionReset))" : "Resets periodically",
                percent: sessionPct,
                style: sessionStyle)

            QuotaItemView(
                title: "Weekly Account Limits",
                desc: "\(weeklyPct)% used",
                footer: weeklyReset != nil ? "Resets \(TimeFormat.timeUntil(weeklyReset))" : "Resets weekly",
                percent: weeklyPct,
                style: weeklyStyle)

            // Messaging box only when no session is currently running.
            if sessionPct == 0 {
                VStack(spacing: 8) {
                    TextEditor(text: $draftMessage)
                        .font(.system(size: 12))
                        .frame(height: 44)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                        .overlay(alignment: .topLeading) {
                            if draftMessage.isEmpty {
                                Text("Message Claude...")
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.textDimmed)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 12)
                                    .allowsHitTesting(false)
                            }
                        }

                    Button(sending ? "Starting..." : "Start session now") {
                        let prompt = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !prompt.isEmpty else { return }
                        sending = true
                        app.startSession(account: account, prompt: prompt)
                        draftMessage = ""
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { sending = false }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(sending)
                }
            }
        }
    }
}
