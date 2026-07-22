import SwiftUI

// MARK: - Compact quota row (shared by Claude + CLI provider cards)

/// A thin, fully-rounded solid-tint bar (no gradient/glow), used in the compact
/// CodexBar-style cards.
struct CompactBar: View {
    let percent: Int
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, Double(percent) / 100.0)) * geo.size.width)
                    .animation(.easeInOut(duration: 0.4), value: percent)
            }
        }
        .frame(height: 6)
    }
}

/// A compact metric row: bold title, thin bar, and a left/right footer
/// (e.g. "42% used" · "Resets in 5h").
struct CompactQuotaRow: View {
    let title: String
    let percent: Int
    let tint: Color
    let leftText: String
    let rightText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textMain)

            CompactBar(percent: percent, tint: tint)

            HStack(alignment: .firstTextBaseline) {
                Text(leftText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textMain)
                Spacer()
                Text(rightText)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textMuted)
            }
        }
    }
}

/// A compact card header: bold title + optional trailing detail on line 1,
/// then an "Updated …" status line + optional subtitle on line 2.
struct CompactCardHeader: View {
    let title: String
    let detail: String?
    let statusLine: String
    let subtitle: String?
    /// Optional provider glyph (asset name) shown as a tinted badge before the title.
    var iconName: String? = nil
    var iconTint: Color = Theme.textMain
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let iconName {
                    ProviderIconBadge(name: iconName, tint: iconTint)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
                }
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.textMain)
                Spacer(minLength: 8)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                IconButton(systemName: "arrow.clockwise", help: "Refresh \(title)", size: 12, action: onRefresh)
            }
            HStack(spacing: 8) {
                Text(statusLine)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textDimmed)
                Spacer(minLength: 8)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textDimmed)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// A small tinted provider glyph badge (rounded tile) shown in a card header.
struct ProviderIconBadge: View {
    let name: String
    let tint: Color

    var body: some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 13, height: 13)
            .foregroundColor(tint)
            .frame(width: 22, height: 22)
            .background(tint.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// A frosted-glass card container: a within-window vibrancy material tinted with
/// a faint white lift, a bright hairline stroke, and a soft drop shadow so it
/// floats above the popover's window glass (CodexBar-style).
struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(16)
            .background {
                ZStack {
                    VisualEffectView(material: .menu, blending: .withinWindow)
                    Theme.cardGlass
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.glassBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
    }
}

/// Small circular icon button used in the header and card headers.
struct IconButton: View {
    let systemName: String
    let help: String
    var size: CGFloat = 16
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.8, weight: .semibold))
                .foregroundColor(Theme.textMuted)
                .frame(width: size + 12, height: size + 12)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Button styles

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(configuration.isPressed ? Theme.accentHover : Theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Theme.textMain)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(configuration.isPressed ? Theme.cardGlassHover : Theme.cardGlass)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.glassBorder, lineWidth: 1))
    }
}

struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Theme.error)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(configuration.isPressed ? Theme.error.opacity(0.2) : Theme.error.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// A compact square SF Symbol action button (used for row Edit / Remove).
/// `danger` renders it in the destructive red treatment.
struct IconActionButtonStyle: ButtonStyle {
    var danger: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(danger ? Theme.error : Theme.textMain)
            .frame(width: 30, height: 28)
            .background(
                danger
                    ? Theme.error.opacity(pressed ? 0.22 : 0.1)
                    : (pressed ? Theme.cardGlassHover : Theme.cardGlass))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(danger ? Color.clear : Theme.glassBorder, lineWidth: 1))
    }
}
