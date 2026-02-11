import SwiftUI

enum Theme {
    static let background = Color(red: 0.02, green: 0.02, blue: 0.03)
    static let panel = Color(red: 0.06, green: 0.06, blue: 0.08)
    static let panelAlt = Color(red: 0.09, green: 0.09, blue: 0.12)
    static let border = Color(red: 1.0, green: 0.24, blue: 0.24).opacity(0.25)
    static let accent = Color(red: 1.0, green: 0.24, blue: 0.24)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.65)
    static let muted = Color.white.opacity(0.4)

    static func statusColor(ok: Bool) -> Color {
        ok ? accent : muted
    }

    static func cardStyle() -> some ViewModifier {
        CardStyle()
    }

    private struct CardStyle: ViewModifier {
        func body(content: Content) -> some View {
            content
                .padding(12)
                .background(Theme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Theme.border, lineWidth: 1)
                        .shadow(color: Theme.accent.opacity(0.25), radius: 6)
                )
                .cornerRadius(12)
        }
    }
}

struct PrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background((isEnabled ? Theme.accent : Theme.muted).opacity(configuration.isPressed ? 0.7 : 0.9))
            .foregroundColor(isEnabled ? .white : Theme.panel)
            .clipShape(Capsule())
            .shadow(color: isEnabled ? Theme.accent.opacity(0.5) : .clear, radius: 8, x: 0, y: 2)
    }
}

struct SecondaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                (isEnabled ? Theme.accent : Theme.panelAlt)
                    .opacity(configuration.isPressed ? (isEnabled ? 0.72 : 0.8) : (isEnabled ? 0.9 : 1.0))
            )
            .foregroundColor(isEnabled ? .white : Theme.muted)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isEnabled ? Theme.accent.opacity(0.7) : Theme.border, lineWidth: 1)
            )
            .shadow(color: isEnabled ? Theme.accent.opacity(0.35) : .clear, radius: 6, x: 0, y: 2)
    }
}
