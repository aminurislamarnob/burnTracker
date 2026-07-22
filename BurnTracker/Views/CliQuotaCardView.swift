import SwiftUI

/// A compact quota card for a linked CLI provider (Antigravity or Gemini CLI),
/// styled after the CodexBar menu: a flat header (name + email, then an
/// "Updated …" line) followed by thin brand-tinted bars showing *remaining*
/// quota with "% left" and a reset countdown.
struct CliQuotaCardView: View {
    let title: String
    let subtitle: String
    let tint: Color
    let account: CliAccount
    /// Message shown when the fetch fails (source-specific).
    let errorMessage: String
    let onRefresh: () -> Void

    var body: some View {
        Card {
            CompactCardHeader(
                title: title,
                detail: account.email,
                statusLine: statusLine,
                subtitle: subtitle,
                onRefresh: onRefresh)
                .padding(.bottom, 10)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            content
                .padding(.top, 14)
        }
    }

    private var statusLine: String {
        switch account.status {
        case .syncing: return "Updating…"
        case .error:   return "Update failed"
        default:       return "Updated \(TimeFormat.relative(account.lastFetch))"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if account.status == .error {
            stateText(errorMessage, color: Theme.error)
        } else if account.status == .syncing && rows.isEmpty {
            stateText("Syncing \(title) quotas…", color: Theme.textDimmed)
        } else if rows.isEmpty {
            stateText("No quota data available", color: Theme.textDimmed)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(rows) { row in
                    CompactQuotaRow(
                        title: row.label,
                        percent: row.percent,
                        tint: barTint(row.percent),
                        leftText: "\(row.percent)% left",
                        rightText: "Resets \(TimeFormat.compactReset(row.resetsIn))")
                }
            }
        }
    }

    private func stateText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    /// Brand tint while healthy; warns as *remaining* quota runs low.
    private func barTint(_ percent: Int) -> Color {
        if percent <= 20 { return Theme.error }
        if percent <= 50 { return Theme.warning }
        return tint
    }

    /// Flattened metric rows, in the screenshot order: 5-hour then weekly, per
    /// model family (Gemini first, then Claude/GPT).
    private var rows: [MetricRowData] {
        var out: [MetricRowData] = []
        if let g = account.gemini {
            out.append(MetricRowData(label: "Gemini 5-hour", percent: g.fiveHourPct, resetsIn: g.fiveHourResetsIn))
            out.append(MetricRowData(label: "Gemini weekly", percent: g.weeklyPct, resetsIn: g.weeklyResetsIn))
        }
        if let c = account.claudeGpt {
            out.append(MetricRowData(label: "Claude/GPT 5-hour", percent: c.fiveHourPct, resetsIn: c.fiveHourResetsIn))
            out.append(MetricRowData(label: "Claude/GPT weekly", percent: c.weeklyPct, resetsIn: c.weeklyResetsIn))
        }
        return out
    }
}

private struct MetricRowData: Identifiable {
    let label: String
    let percent: Int
    let resetsIn: String?
    var id: String { label }
}
