import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var app: AppState

    /// Vertical gap between cards. The reorder maths converts measured card
    /// heights into slot positions, so it needs the spacing as a constant.
    private static let cardSpacing: CGFloat = 16

    private static let shuffleAnimation = Animation.spring(response: 0.26, dampingFraction: 0.86)
    private static let settleAnimation = Animation.spring(response: 0.3, dampingFraction: 0.82)
    private static let liftAnimation = Animation.easeOut(duration: 0.16)

    /// A drag in progress.
    ///
    /// The card order is deliberately **not** touched while the drag is running.
    /// Reordering the `ForEach` mid-gesture re-parents every card — each of which
    /// hosts an `NSVisualEffectView` — and pits the layout animation against the
    /// offset that keeps the dragged card under the pointer; that combination is
    /// what made the cards blink. Instead this snapshot stays fixed and only
    /// `.offset` values change (a pure render transform), with the real order
    /// committed exactly once, on release.
    private struct DragSession {
        let id: String
        let order: [String]
        let heights: [String: CGFloat]
        let startIndex: Int
        var translation: CGFloat = 0
        var targetIndex: Int

        /// The vertical space the dragged card occupies, i.e. exactly how far
        /// every card it has moved past must shuffle to open the gap for it.
        var slotHeight: CGFloat { (heights[id] ?? 0) + DashboardView.cardSpacing }

        /// Where `other` sits while the dragged card hovers over its slot.
        func shift(for other: String) -> CGFloat {
            guard other != id, let index = order.firstIndex(of: other) else { return 0 }
            if index > startIndex, index <= targetIndex { return -slotHeight }
            if index < startIndex, index >= targetIndex { return slotHeight }
            return 0
        }

        /// The order the drag resolves to if released now.
        var resolvedOrder: [String] {
            var next = order
            next.remove(at: startIndex)
            next.insert(id, at: targetIndex)
            return next
        }
    }

    @State private var drag: DragSession?
    @State private var heights: [String: CGFloat] = [:]
    /// Post-release state: the new order is already committed and the dropped
    /// card is springing from `settleOffset` back into its slot.
    @State private var settleID: String?
    @State private var settleOffset: CGFloat = 0
    /// Suppresses animation for the single update that commits the new order —
    /// see `commit(_:)`.
    @State private var isCommitting = false

    var body: some View {
        if !app.hasAnyAccount {
            emptyState
        } else {
            VStack(spacing: Self.cardSpacing) {
                ForEach(app.visibleCardIDs, id: \.self) { cardId in
                    let offset = offset(for: cardId)
                    let lifted = isLifted(cardId)
                    cardView(for: cardId)
                        .background(CardHeightReporter(id: cardId))
                        .scaleEffect(lifted ? 1.015 : 1)
                        .shadow(color: .black.opacity(lifted ? 0.4 : 0), radius: 14, y: 6)
                        .animation(isCommitting ? nil : Self.liftAnimation, value: lifted)
                        .offset(y: offset)
                        .animation(animation(for: cardId), value: offset)
                        .zIndex(lifted ? 1 : 0)
                        .gesture(reorderGesture(for: cardId))
                }
            }
            .onPreferenceChange(CardHeightKey.self) { heights = $0 }
        }
    }

    // MARK: - Drag-to-reorder

    private func isLifted(_ id: String) -> Bool {
        drag?.id == id || (settleID == id && settleOffset != 0)
    }

    private func offset(for id: String) -> CGFloat {
        if let drag {
            return drag.id == id ? drag.translation : drag.shift(for: id)
        }
        return settleID == id ? settleOffset : 0
    }

    /// The dragged card gets no animation at all so it tracks the pointer exactly;
    /// the cards shuffling around it get a spring.
    private func animation(for id: String) -> Animation? {
        if isCommitting { return nil }
        if drag?.id == id { return nil }
        if settleID == id { return Self.settleAnimation }
        return Self.shuffleAnimation
    }

    private func reorderGesture(for id: String) -> some Gesture {
        // A minimum distance keeps clicks on the cards' own buttons intact; on
        // macOS a ScrollView is driven by the wheel/trackpad rather than by
        // dragging its content, so this cannot steal scrolling either.
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { value in
                if drag?.id != id {
                    let order = app.visibleCardIDs
                    guard order.count > 1, let index = order.firstIndex(of: id) else { return }
                    settleID = nil
                    settleOffset = 0
                    drag = DragSession(id: id, order: order, heights: heights,
                                       startIndex: index, targetIndex: index)
                }
                drag?.translation = value.translation.height
                if let drag { self.drag?.targetIndex = targetIndex(for: drag) }
            }
            .onEnded { _ in
                if let drag { commit(drag) }
            }
    }

    /// Index the dragged card lands on, i.e. the furthest neighbour whose
    /// midpoint it has crossed. Measured against the *snapshot* layout, so the
    /// result never depends on the shuffling the answer itself causes.
    private func targetIndex(for drag: DragSession) -> Int {
        let center = Self.slotOrigin(of: drag.id, in: drag.order, heights: drag.heights)
            + (drag.heights[drag.id] ?? 0) / 2 + drag.translation

        var result = drag.startIndex
        for (i, other) in drag.order.enumerated() where other != drag.id {
            let midpoint = Self.slotOrigin(of: other, in: drag.order, heights: drag.heights)
                + (drag.heights[other] ?? 0) / 2
            if i < drag.startIndex, center < midpoint { result = min(result, i) }
            if i > drag.startIndex, center > midpoint { result = max(result, i) }
        }
        return result
    }

    /// Adopts the dragged order. The commit itself must not animate: the layout
    /// slots change and every card's offset changes by the same amount at the
    /// same time, so with animation suppressed the frame is pixel-identical to
    /// the one before it. Only then is the dropped card's leftover displacement
    /// sprung back to zero, which is the movement the user actually sees.
    private func commit(_ drag: DragSession) {
        let next = drag.resolvedOrder
        let startY = Self.slotOrigin(of: drag.id, in: drag.order, heights: drag.heights)
        let endY = Self.slotOrigin(of: drag.id, in: next, heights: drag.heights)

        isCommitting = true
        settleID = drag.id
        settleOffset = drag.translation - (endY - startY)
        self.drag = nil
        app.setCardOrder(next)
        app.saveToDisk()

        DispatchQueue.main.async {
            isCommitting = false
            settleOffset = 0
        }
    }

    /// Top edge of `id`'s slot in a stack laid out in `order` with `heights`.
    private static func slotOrigin(of id: String, in order: [String], heights: [String: CGFloat]) -> CGFloat {
        var y: CGFloat = 0
        for other in order {
            if other == id { break }
            y += (heights[other] ?? 0) + cardSpacing
        }
        return y
    }

    @ViewBuilder
    private func cardView(for cardId: String) -> some View {
        if cardId.hasPrefix("claude_"), 
           let account = app.accounts.first(where: { $0.id == String(cardId.dropFirst("claude_".count)) }) {
            ClaudeAccountCardView(account: account)
        } else if cardId == "claudeTrend", let trend = app.claudeUsageTrend, !trend.days.isEmpty {
            Card {
                UsageTrendSection(
                    trend: trend,
                    tint: Theme.accent,
                    title: "Claude Usage Trend")
            }
        } else if cardId == "gemini", let gemini = app.geminiAccount {
            CliQuotaCardView(
                title: "Gemini CLI",
                subtitle: "Gemini Code Assist",
                tint: Theme.geminiTint,
                iconName: "ProviderIcon-gemini",
                account: gemini,
                errorMessage: "Could not fetch Gemini CLI quota",
                isPinned: app.isPinned(.gemini),
                onTogglePin: { app.togglePin(.gemini) },
                onRefresh: { Task { await app.refreshGemini() } })
        } else if cardId == "commandCode", let cmd = app.commandCodeAccount {
            CommandCodeCardView(
                account: cmd,
                isPinned: app.isPinned(.commandCode),
                onTogglePin: { app.togglePin(.commandCode) },
                onRefresh: { Task { await app.refreshCommandCode() } })
        } else if cardId == "antigravity", let ag = app.agAccount {
            CliQuotaCardView(
                title: "Antigravity",
                subtitle: "Antigravity IDE",
                tint: Theme.antigravityTint,
                iconName: "ProviderIcon-antigravity",
                account: ag,
                errorMessage: "Could not fetch local Antigravity quota (is the Antigravity app running?)",
                isPinned: app.isPinned(.antigravity),
                onTogglePin: { app.togglePin(.antigravity) },
                onRefresh: { Task { await app.refreshAntigravity() } })
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

// MARK: - Card height measurement

/// Reports each card's laid-out height, keyed by card id, so the reorder maths
/// can work out slot positions without a second layout pass.
private struct CardHeightKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct CardHeightReporter: View {
    let id: String
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: CardHeightKey.self, value: [id: geo.size.height])
        }
    }
}
