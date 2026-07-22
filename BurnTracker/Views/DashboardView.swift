import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        if !app.hasAnyAccount {
            emptyState
        } else {
            VStack(spacing: 16) {
                // One card per connected Claude account.
                ForEach(app.accounts) { account in
                    ClaudeAccountCardView(account: account)
                }
                // Each CLI provider in its own card.
                if let gemini = app.geminiAccount {
                    CliQuotaCardView(
                        title: "Gemini CLI",
                        subtitle: "Gemini Code Assist",
                        tint: Theme.geminiTint,
                        account: gemini,
                        errorMessage: "Could not fetch Gemini CLI quota",
                        onRefresh: { Task { await app.refreshGemini() } })
                }
                if let ag = app.agAccount {
                    CliQuotaCardView(
                        title: "Antigravity",
                        subtitle: "Antigravity IDE",
                        tint: Theme.antigravityTint,
                        account: ag,
                        errorMessage: "Could not fetch local Antigravity quota (is the Antigravity app running?)",
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
