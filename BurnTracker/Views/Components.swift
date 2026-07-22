import SwiftUI

/// Progress-bar fill styles, matching the `.progress-bar-fill` variants in styles.css.
enum BarStyle {
    case accent    // default (session, normal)
    case weekly    // info blue (weekly, normal)
    case warning
    case danger
    case green     // success

    var gradient: LinearGradient {
        let colors: [Color]
        switch self {
        case .accent:  colors = [Theme.accent, Theme.accentHover]
        case .weekly:  colors = [Theme.info, Color(hex: 0x30B0FF)]
        case .warning: colors = [Color(hex: 0xFF9F0A), Color(hex: 0xFFD60A)]
        case .danger:  colors = [Theme.error, Color(hex: 0xFF6B6B)]
        case .green:   colors = [Theme.success, Color(hex: 0x30D158)]
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    var glow: Color {
        switch self {
        case .accent:  return Theme.accent
        case .weekly:  return Theme.info
        case .warning: return Color(hex: 0xFF9F0A)
        case .danger:  return Theme.error
        case .green:   return Theme.success
        }
    }
}

struct ProgressBar: View {
    let percent: Int          // 0...100
    let style: BarStyle

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border, lineWidth: 1))
                RoundedRectangle(cornerRadius: 5)
                    .fill(style.gradient)
                    .shadow(color: style.glow.opacity(0.6), radius: 4)
                    .frame(width: max(0, min(1, Double(percent) / 100.0)) * geo.size.width)
                    .animation(.easeInOut(duration: 0.5), value: percent)
            }
        }
        .frame(height: 10)
    }
}

/// A status dot (green/orange/red).
struct PulseDot: View {
    let status: SyncStatus

    private var color: Color {
        switch status {
        case .online:  return Theme.success
        case .syncing: return Theme.warning
        case .error:   return Theme.error
        case .offline: return Theme.textDimmed
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.7), radius: 3)
    }
}

/// A single labelled quota row: title + description, a bar, and a footer.
struct QuotaItemView: View {
    let title: String
    let desc: String
    let footer: String
    let percent: Int
    let style: BarStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                Spacer()
                Text(desc)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textMain)
            }
            ProgressBar(percent: percent, style: style)
            Text(footer)
                .font(.system(size: 10))
                .foregroundColor(Theme.textDimmed)
        }
    }
}

/// A card container with the surface background and border.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(16)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
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
            .background(configuration.isPressed ? Theme.cardHover : Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
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
