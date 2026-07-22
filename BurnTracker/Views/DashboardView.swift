import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        if app.accounts.isEmpty && app.agAccount == nil {
            emptyState
        } else {
            VStack(spacing: 16) {
                if !app.accounts.isEmpty {
                    AccountCardView()
                }
                if app.agAccount != nil {
                    AntigravityCardView()
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
