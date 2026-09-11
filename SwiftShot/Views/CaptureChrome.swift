import SwiftUI

/// UI chrome only. The bitmap renderer and screenshot views never use these
/// surfaces: rounding and material must not change captured or exported pixels.
struct CaptureChrome: ViewModifier {
    var radius: CGFloat = 28
    var capsule = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if capsule {
            surface(content, shape: Capsule())
        } else {
            surface(content, shape: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    @ViewBuilder private func surface<S: InsettableShape>(_ content: Content, shape: S) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay { shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.65 : 0.16), lineWidth: 1) }
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
                .overlay { shape.strokeBorder(.primary.opacity(0.12), lineWidth: 0.5) }
        }
    }
}

extension View {
    func captureChrome(radius: CGFloat = 28, capsule: Bool = false) -> some View {
        modifier(CaptureChrome(radius: radius, capsule: capsule))
    }

    @ViewBuilder func captureGlassGroup() -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 6) { self }
        } else { self }
    }
}

/// Color-only feedback keeps the hit target fixed, including during rapid input.
struct CaptureButtonStyle: ButtonStyle {
    var prominent = false
    var selected = false
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        ButtonContent(configuration: configuration, prominent: prominent, selected: selected,
             compact: compact, reduceMotion: reduceMotion, contrast: contrast, enabled: enabled)
    }

    private struct ButtonContent: View {
        let configuration: Configuration
        let prominent: Bool
        let selected: Bool
        let compact: Bool
        let reduceMotion: Bool
        let contrast: ColorSchemeContrast
        let enabled: Bool
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, compact ? 0 : 13)
                .frame(minWidth: compact ? 34 : nil, minHeight: 34)
                .foregroundStyle(foreground)
                .background(fill, in: Capsule())
                .overlay { if contrast == .increased { Capsule().strokeBorder(.primary.opacity(0.65), lineWidth: 1) } }
                .contentShape(Capsule())
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: hovered)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
        }

        private var fill: Color {
            if prominent { return Color.accentColor.opacity(configuration.isPressed ? 0.7 : (hovered ? 0.85 : 1)) }
            if configuration.role == .destructive {
                return Color.red.opacity(configuration.isPressed ? 0.2 : (selected ? 0.15 : (hovered ? 0.11 : 0.06)))
            }
            return Color.primary.opacity(configuration.isPressed ? 0.18 : (selected ? 0.13 : (hovered ? 0.09 : 0.045)))
        }

        private var foreground: Color {
            if configuration.role == .destructive { return .red }
            return prominent ? Color(nsColor: .selectedMenuItemTextColor) : .primary
        }
    }
}
