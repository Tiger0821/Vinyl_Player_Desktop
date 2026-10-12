import SwiftUI

/// The window's colours, taken from the turntable: cream label print, walnut-dark ink, a warm lamp.
enum Theme {
    static let cream = Color(red: 1.0, green: 0.93, blue: 0.82)
    /// Text on a cream fill.
    static let ink = Color(red: 0.14, green: 0.085, blue: 0.05)
    static let ember = Color(red: 0.96, green: 0.5, blue: 0.22)
    static let hairline = Color.white.opacity(0.09)
    static let well = Color.white.opacity(0.07)
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(1.6)
            .foregroundStyle(Theme.cream.opacity(0.58))
    }
}

/// A switch drawn to match the window. The whole row is the click target.
struct SwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                configuration.isOn.toggle()
            }
        } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 8)
                Capsule()
                    .fill(configuration.isOn ? Theme.ember : Color.white.opacity(0.16))
                    .frame(width: 36, height: 21)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(Theme.cream)
                            .padding(2.5)
                            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// A round, icon-only button that lights up under the pointer.
struct RoundIconButton: View {
    let symbol: String
    let label: String
    var isProminent = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let diameter: CGFloat = isProminent ? 42 : 34

        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: isProminent ? 17 : 14, weight: .semibold))
                .foregroundStyle(isProminent ? Theme.ink : Theme.cream.opacity(0.92))
                .frame(width: diameter, height: diameter)
                .background {
                    Circle().fill(
                        isProminent
                            ? Theme.cream.opacity(isHovered ? 1 : 0.92)
                            : Color.white.opacity(isHovered ? 0.14 : 0)
                    )
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// A small text button for actions that should stay out of the way.
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.cream.opacity(!isEnabled ? 0.28 : isHovered ? 1 : 0.68))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(Color.white.opacity(isEnabled && isHovered ? 0.1 : 0)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

/// A cream pill for the one action a section wants you to take.
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(Capsule().fill(Theme.cream.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Capsule())
    }
}
