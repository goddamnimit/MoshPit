import SwiftUI
import UIKit

/// MoshPit design system. Every view draws exclusively from these tokens —
/// no hardcoded colors, sizes, or paddings anywhere else in the UI layer.
enum Theme {
    // MARK: 8pt spacing grid
    /// All padding/margins are multiples of 8 (half-step 4 only for icon/text gaps).
    static let g1: CGFloat = 8
    static let g2: CGFloat = 16
    static let g3: CGFloat = 24
    static let g4: CGFloat = 32
    static let g6: CGFloat = 48
    static let gHalf: CGFloat = 4

    // MARK: Geometry
    /// The one corner radius, used everywhere.
    static let radius: CGFloat = 12
    /// Exactly three button heights.
    static let buttonSmall: CGFloat = 32
    static let buttonStandard: CGFloat = 44
    static let buttonLarge: CGFloat = 56
    /// Minimum tap target — small buttons pad their hit area up to this.
    static let tapTarget: CGFloat = 44

    // MARK: Palette (floating over live video — scrims, never opaque panels)
    /// Near-black scrim #0D0D0F at overlay opacities.
    static let scrimBase = Color(red: 0x0D / 255, green: 0x0D / 255, blue: 0x0F / 255)
    static let scrim = scrimBase.opacity(0.65)
    static let scrimStrong = scrimBase.opacity(0.75)
    /// The single accent: active / selected / recording states only.
    static let accent = Color(red: 1.0, green: 0.23, blue: 0.35)
    static let textPrimary = Color.white.opacity(0.9)
    static let textSecondary = Color.white.opacity(0.6)
    /// Hairlines and inactive strokes.
    static let stroke = Color.white.opacity(0.18)
    static let disabledOpacity: Double = 0.4

    // MARK: Type — SF Pro for labels, SF Mono for numeric readouts
    static let label = Font.system(size: 13, weight: .medium)
    static let labelSmall = Font.system(size: 11, weight: .medium)
    static let mono = Font.system(size: 12, weight: .medium, design: .monospaced)
    static let monoSmall = Font.system(size: 11, weight: .regular, design: .monospaced)

    // MARK: Motion & feedback
    static let pressedScale: CGFloat = 0.97
    static let fade = Animation.easeInOut(duration: 0.25)
    /// Overlay controls fade after this many seconds without interaction.
    static let idleTimeout: TimeInterval = 4

    static func haptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - Shared modifiers

/// Translucent scrim capsule/rect that all floating controls sit on.
struct ScrimBackground: ViewModifier {
    var strong = false
    func body(content: Content) -> some View {
        content
            .background(strong ? Theme.scrimStrong : Theme.scrim)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

extension View {
    func scrim(strong: Bool = false) -> some View {
        modifier(ScrimBackground(strong: strong))
    }
}

/// The one button style: pressed = scale 0.97 + brightness dip; selected uses
/// the accent fill; disabled drops to 40% opacity.
struct MoshButtonStyle: ButtonStyle {
    enum Size { case small, standard, large }
    var size: Size = .standard
    var selected = false
    var tint: Color? = nil          // accent override (e.g. reset orange-less: still accent)
    var fillsWidth = false

    private var height: CGFloat {
        switch size {
        case .small: return Theme.buttonSmall
        case .standard: return Theme.buttonStandard
        case .large: return Theme.buttonLarge
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size == .small ? Theme.labelSmall : Theme.label)
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textPrimary)
            .padding(.horizontal, size == .small ? 0 : Theme.g2)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(height: height)
            .background(selected ? (tint ?? Theme.accent) : Theme.scrim)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: selected ? 0 : 1))
            .scaleEffect(configuration.isPressed ? Theme.pressedScale : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .contentShape(Rectangle().inset(by: -max(0, (Theme.tapTarget - height) / 2)))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Small square icon button (32pt visual, 44pt hit area).
struct IconButton: View {
    let systemName: String
    var selected = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .frame(width: Theme.buttonSmall, height: Theme.buttonSmall)
        }
        .buttonStyle(MoshButtonStyle(size: .small, selected: selected))
    }
}
