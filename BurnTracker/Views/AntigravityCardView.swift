import SwiftUI

/// The "Antigravity / Gemini CLI" card. Bars show *remaining* quota, so the
/// color scale is inverted vs the Claude cards (low = danger).
struct AntigravityCardView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        if let ag = app.agAccount {
            Card {
                HStack(spacing: 6) {
                    PulseDot(status: ag.status)
                    Text("Antigravity / Gemini CLI")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textMain)
                    if let email = ag.email {
                        Text(email)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textMuted)
                    }
                    Spacer()
                    IconButton(systemName: "arrow.clockwise", help: "Refresh Antigravity Quota", size: 14) {
                        Task { await app.refreshAntigravity() }
                    }
                }
                .padding(.bottom, 12)

                body(for: ag)
            }
        }
    }

    @ViewBuilder
    private func body(for ag: AgAccount) -> some View {
        if ag.status == .error {
            Text("Sync Failed: Could not fetch local Antigravity CLI quota")
                .font(.system(size: 12))
                .foregroundColor(Theme.error)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        } else if ag.status == .syncing && ag.gemini == nil && ag.claudeGpt == nil {
            Text("Syncing Antigravity quotas...")
                .font(.system(size: 12))
                .foregroundColor(Theme.textDimmed)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        } else if ag.gemini == nil && ag.claudeGpt == nil {
            Text("No quota data available")
                .font(.system(size: 12))
                .foregroundColor(Theme.textDimmed)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if let g = ag.gemini {
                    groupView(short: "Gemini", group: g)
                }
                if let c = ag.claudeGpt {
                    if ag.gemini != nil {
                        Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 4)
                    }
                    groupView(short: "Claude & GPT", group: c)
                }
            }
        }
    }

    /// Inverted color scale (shows remaining): ≤20 danger, ≤50 warning, else green.
    private func barStyle(_ pct: Int) -> BarStyle {
        if pct <= 20 { return .danger }
        if pct <= 50 { return .warning }
        return .green
    }

    @ViewBuilder
    private func groupView(short: String, group: AGGroup) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 4) {
                Text(group.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.accentHover)
                if let d = group.description {
                    Text("(\(d))")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textDimmed)
                }
            }

            QuotaItemView(
                title: "\(short) — Weekly Limit",
                desc: group.weeklyPct == 100 ? "100% remaining" : "\(group.weeklyRawPct)% remaining",
                footer: group.weeklyResetsIn != nil ? "Refreshes \(TimeFormat.timeUntil(group.weeklyResetsIn))" : "Quota available",
                percent: group.weeklyPct,
                style: barStyle(group.weeklyPct))

            QuotaItemView(
                title: "\(short) — Five Hour Limit",
                desc: group.fiveHourPct == 100 ? "100% remaining" : "\(group.fiveHourRawPct)% remaining",
                footer: group.fiveHourResetsIn != nil ? "Refreshes \(TimeFormat.timeUntil(group.fiveHourResetsIn))" : "Quota available",
                percent: group.fiveHourPct,
                style: barStyle(group.fiveHourPct))
        }
    }
}
