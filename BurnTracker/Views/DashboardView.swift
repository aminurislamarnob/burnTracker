import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        if !app.hasAnyAccount {
            emptyState
        } else {
            VStack(spacing: 16) {
                if !app.accounts.isEmpty {
                    AccountCardView()
                }
                if let gemini = app.geminiAccount {
                    CliQuotaCardView(
                        title: "Gemini CLI",
                        account: gemini,
                        errorMessage: "Sync Failed: Could not fetch Gemini CLI quota",
                        onRefresh: { Task { await app.refreshGemini() } })
                }
                if let ag = app.agAccount {
                    CliQuotaCardView(
                        title: "Antigravity",
                        account: ag,
                        errorMessage: "Sync Failed: Could not fetch local Antigravity quota (is the Antigravity app running?)",
                        onRefresh: { Task { await app.refreshAntigravity() } })
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.rectangle")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(Theme.textDimmed)
            Text("No Accounts Connected")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.textMain)
            Text("Click the settings gear icon in the top right to configure your sessionKey cookies and start tracking quotas.")
                .font(.system(size: 12))
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.center)
            Button("Configure Settings") {
                app.activeView = .settings
            }
            .buttonStyle(PrimaryButtonStyle())
            .fixedSize()
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 20)
    }
}
