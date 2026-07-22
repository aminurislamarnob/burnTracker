import SwiftUI
import AppKit

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)

            ScrollView {
                Group {
                    switch app.activeView {
                    case .dashboard: DashboardView()
                    case .settings:  SettingsView()
                    }
                }
                .padding(16)
            }
            .scrollContentBackground(.hidden)

            Divider().overlay(Theme.border)
            footer
        }
        .frame(width: 400, height: 620)
        .background(Theme.bg)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if let icon = NSImage(named: "AppIconImage") {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "flame.fill").foregroundColor(Theme.accent)
            }
            Text("BurnTracker")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Theme.textMain)
            Spacer()
            IconButton(systemName: "house", help: "Home") { app.activeView = .dashboard }
            IconButton(systemName: "arrow.clockwise", help: "Refresh All Accounts") {
                Task { await app.refreshAll() }
            }
            IconButton(systemName: "gearshape", help: "Settings") {
                app.activeView = app.activeView == .settings ? .dashboard : .settings
            }
            IconButton(systemName: "power", help: "Quit BurnTracker") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                Circle().fill(footerColor).frame(width: 8, height: 8)
                    .shadow(color: footerColor.opacity(0.7), radius: 3)
                Text(footerText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textMuted)
            }
            Spacer()
            Text(lastSyncText)
                .font(.system(size: 10))
                .foregroundColor(Theme.textDimmed)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var footerColor: Color {
        if !app.hasAnyAccount { return Theme.error }
        switch app.globalStatus {
        case .online:  return Theme.success
        case .syncing, .warning: return Theme.warning
        default: return Theme.error
        }
    }

    private var footerText: String {
        if !app.hasAnyAccount { return "No Accounts Connected" }
        switch app.globalStatus {
        case .syncing: return "Syncing..."
        case .online:  return "Synced"
        case .warning: return "Sync issues"
        default:       return "Offline / Error"
        }
    }

    private var lastSyncText: String {
        guard let t = app.lastSyncTime else { return "Last Sync: --" }
        let f = DateFormatter()
        f.dateFormat = "hh:mm:ss a"
        return "Last Sync: \(f.string(from: t))"
    }
}
