import SwiftUI

/// The "Usage Trend" accordion for a Claude card. Collapsed: just the label +
/// caret. Expanded: an interactive daily-token bar chart (hover a day to
/// highlight it and read its date · spend · tokens), a date axis, and the
/// Today / Yesterday / Last 30 Days totals. Mirrors OpenUsage's hover-reveal.
struct UsageTrendSection: View {
    let trend: ClaudeUsageTrend
    var tint: Color = Theme.info

    @State private var expanded = false
    @State private var activeIndex: Int?

    private static let chartHeight: CGFloat = 60

    private var series: [DayUsage] { trend.series(count: 30) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    readout
                    chart
                    axis
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                        .padding(.vertical, 4)
                    totals
                }
                .padding(.top, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
        } label: {
            HStack {
                Text("Usage Trend")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textMain)
                Spacer()
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Chart

    /// The hovered day, or the busiest day when nothing is hovered.
    private var readout: some View {
        let idx = activeIndex ?? peakIndex
        let day = idx.flatMap { series.indices.contains($0) ? series[$0] : nil }
        let prefix = activeIndex == nil ? "Peak" : Self.dateLabel(day?.day)
        return HStack(spacing: 6) {
            Text(prefix)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textMuted)
            Text(valueText(day))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundColor(Theme.textMain)
            Spacer()
        }
        .frame(height: 14)
    }

    private var chart: some View {
        let maxTokens = max(1, series.map(\.tokens).max() ?? 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(series.indices, id: \.self) { i in
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.chartHeight)
                    // Full column is the hit target so short/zero bars are easy to hover.
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(series[i].tokens == 0 ? tint.opacity(0.18) : tint)
                            .frame(height: barHeight(series[i].tokens, max: maxTokens))
                            .opacity(activeIndex == nil || activeIndex == i ? 1 : 0.35)
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active = phase { activeIndex = i }
                    }
            }
        }
        .frame(height: Self.chartHeight)
        .onContinuousHover { phase in if case .ended = phase { activeIndex = nil } }
        .animation(.easeOut(duration: 0.12), value: activeIndex)
    }

    private var axis: some View {
        HStack {
            Text(Self.dateLabel(series.first?.day))
            Spacer()
            Text(Self.dateLabel(series.last?.day))
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundColor(Theme.textDimmed)
    }

    // MARK: - Totals

    private var totals: some View {
        VStack(spacing: 8) {
            totalRow("Today", trend.today)
            totalRow("Yesterday", trend.yesterday)
            totalRow("Last 30 Days", trend.last30)
        }
    }

    private func totalRow(_ label: String, _ usage: DayUsage?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.textMain)
            Spacer(minLength: 12)
            Text(valueText(usage))
                .font(.system(size: 13))
                .foregroundColor(Theme.textMuted)
        }
    }

    // MARK: - Helpers

    private var peakIndex: Int? {
        series.indices.max { series[$0].tokens < series[$1].tokens }
    }

    private func barHeight(_ tokens: Int, max maxTokens: Int) -> CGFloat {
        guard tokens > 0 else { return 2 }
        let ratio = min(1, Double(tokens) / Double(maxTokens))
        return max(Self.chartHeight * 0.06, Self.chartHeight * ratio)
    }

    private func valueText(_ usage: DayUsage?) -> String {
        guard let u = usage, u.tokens > 0 else { return "—" }
        return "\(NumberFormat.dollars(u.cost)) · \(NumberFormat.tokens(u.tokens)) tokens"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static func dateLabel(_ date: Date?) -> String {
        guard let date else { return "" }
        return dateFormatter.string(from: date)
    }
}
