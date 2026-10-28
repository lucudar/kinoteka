import SwiftUI

// MARK: - Liquid Glass
//
// On iOS 26 the controls of the app are drawn with Liquid Glass; on iOS 18–25 the same views
// get a material. The compiler check keeps the project buildable with Xcode 16 (iOS 18 SDK):
// there the material is used everywhere.

enum GlassStyle {
    /// Controls and panels over the content.
    case regular
    /// More transparent glass for controls over video and pictures.
    case clear
}

enum LiquidGlassSupport {
    /// The system draws Liquid Glass (iOS 26 and the app built with its SDK).
    static var isAvailable: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }
}

#if compiler(>=6.2)
@available(iOS 26.0, *)
private enum LiquidGlass {
    static func make(_ style: GlassStyle, tint: Color?, interactive: Bool) -> Glass {
        var glass: Glass = style == .clear ? .clear : .regular
        if let tint = tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}
#endif

extension View {
    /// Liquid Glass of the given shape behind the view (a material before iOS 26).
    /// `tint` colours the glass (a selected chip, the main action); `interactive` makes it
    /// react to touches like a system button.
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S, style: GlassStyle = .regular, tint: Color? = nil,
                                interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(LiquidGlass.make(style, tint: tint, interactive: interactive), in: shape)
        } else {
            self.modifier(MaterialGlass(shape: shape, style: style, tint: tint))
        }
        #else
        self.modifier(MaterialGlass(shape: shape, style: style, tint: tint))
        #endif
    }

    /// The main action of a screen: tinted Liquid Glass on iOS 26, a filled accent shape before.
    @ViewBuilder
    func primaryActionStyle() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
                .tint(Theme.accent)
        } else {
            self.buttonStyle(FilledActionButtonStyle())
        }
        #else
        self.buttonStyle(FilledActionButtonStyle())
        #endif
    }

    /// A compact accent button (a dialog, a prompt): tinted Liquid Glass on iOS 26,
    /// a filled system button before.
    @ViewBuilder
    func prominentButtonStyle() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
                .tint(Theme.accent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
        #else
        self.buttonStyle(.borderedProminent)
        #endif
    }

    /// A secondary action next to the main one: Liquid Glass on iOS 26, a bordered button before.
    @ViewBuilder
    func secondaryActionStyle() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
        #else
        self.buttonStyle(.bordered)
        #endif
    }

    /// The tab bar shrinks to the selected tab while a list scrolls down (iOS 26).
    @ViewBuilder
    func tabBarMinimizesOnScroll() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// Glass shapes inside blend together and morph into each other on iOS 26 (and are drawn in
/// one pass, which is cheaper than separate glass views).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat?
    let content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// The look of glass before iOS 26: a material with a thin light edge.
private struct MaterialGlass<S: Shape>: ViewModifier {
    let shape: S
    let style: GlassStyle
    let tint: Color?

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if style == .clear {
                        shape.fill(.ultraThinMaterial)
                    } else {
                        shape.fill(.thinMaterial)
                    }
                    if let tint = tint {
                        shape.fill(tint.opacity(0.85))
                    }
                }
            }
            .overlay {
                shape.stroke(Color.white.opacity(0.14), lineWidth: 0.75)
            }
    }
}

/// The main action before iOS 26: the accent colour in a rounded rectangle.
struct FilledActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// A button drawn as a glass shape. The whole shape takes the tap: an interactive glass effect
/// inside a button label catches the touches around the glyph on iOS 26, so a small button
/// (the cross of the player) reacted only to a precise tap. The press is shown by the button itself.
struct GlassShapeButtonStyle<S: Shape>: ButtonStyle {
    let shape: S
    var style: GlassStyle = .regular
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(shape)
            .glassSurface(shape, style: style, tint: tint)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(duration: 0.22), value: configuration.isPressed)
    }
}

extension View {
    /// A button with a glass background of the given shape that reacts to a tap anywhere on it.
    func glassButton<S: Shape>(_ shape: S, style: GlassStyle = .regular, tint: Color? = nil) -> some View {
        buttonStyle(GlassShapeButtonStyle(shape: shape, style: style, tint: tint))
    }
}
