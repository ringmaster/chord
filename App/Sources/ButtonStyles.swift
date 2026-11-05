import SwiftUI

// Chord's button styles. Every button shows that it is a button: it brightens
// when the pointer is over it, darkens and shrinks a little while pressed, and
// fades when disabled. The changes are not animated, so they cannot stall.

/// A rounded button with a soft fill, used instead of the stock bordered style.
struct QuietButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        QuietButton(configuration: configuration, prominent: prominent)
    }
}

private struct QuietButton: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule().fill(fill))
            .foregroundStyle(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
    }

    private var fill: Color {
        let state = !isEnabled ? 0 : configuration.isPressed ? 2 : hovering ? 1 : 0
        if prominent {
            return Color.accentColor.opacity([0.2, 0.3, 0.4][state])
        }
        return Color.primary.opacity([0.07, 0.13, 0.19][state])
    }
}

/// A style for icon buttons, rows, and cards that draw their own label. It adds
/// a highlight in `shape` behind the label on hover and a stronger one on press.
struct ChromeButtonStyle: ButtonStyle {
    enum Shape {
        case roundedRectangle(cornerRadius: CGFloat)
        case capsule
        case circle
    }

    var shape: Shape

    func makeBody(configuration: Configuration) -> some View {
        ChromeButton(configuration: configuration, shape: shape)
    }
}

private struct ChromeButton: View {
    let configuration: ButtonStyleConfiguration
    let shape: ChromeButtonStyle.Shape
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .background { highlight }
            .scaleEffect(configuration.isPressed && isEnabled ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 }
    }

    private var amount: Double {
        guard isEnabled else { return 0 }
        return configuration.isPressed ? 0.16 : hovering ? 0.09 : 0
    }

    @ViewBuilder private var highlight: some View {
        switch shape {
        case .roundedRectangle(let radius):
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.primary.opacity(amount))
        case .capsule:
            Capsule().fill(.primary.opacity(amount))
        case .circle:
            Circle().fill(.primary.opacity(amount))
        }
    }
}
