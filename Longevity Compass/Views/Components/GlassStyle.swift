import SwiftUI

// MARK: - Glass card / chip modifiers
//
// Thin wrappers around `.glassEffect(...)` that keep tint, corner radius,
// and edge stroke consistent across the app. The aim is to replace flat
// `tint.opacity(0.10)` fills with real liquid-glass material while
// preserving the same shapes and tints.

extension View {

    /// Liquid-glass background for prominent cards (hero panels, large summaries).
    /// Includes a subtle gradient stroke that picks up the tint along the top edge.
    func glassCard(
        tint: Color,
        cornerRadius: CGFloat = 22,
        tintOpacity: Double = 0.28
    ) -> some View {
        self
            .glassEffect(
                .regular.tint(tint.opacity(tintOpacity)),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [tint.opacity(0.55), tint.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
    }

    /// Neutral glass card for secondary surfaces (lists of contributors, info blocks).
    func glassSurface(cornerRadius: CGFloat = 14) -> some View {
        self.glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }

    /// Capsule-shaped glass chip with tint.
    func glassChip(tint: Color, tintOpacity: Double = 0.30) -> some View {
        self.glassEffect(.regular.tint(tint.opacity(tintOpacity)), in: Capsule())
    }
}

// MARK: - Glass icon tile
//
// Replaces the solid-color icon squares used in hero cards. The fill stays
// punchy (so icons read clearly) but a diagonal sheen + edge highlight give
// the tile dimensional, wet-glass character.

struct GlassIconTile: View {
    let systemName: String
    var tint: Color = .accentColor
    var size: CGFloat = 56
    var cornerRadius: CGFloat = 14

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tint)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.32), .clear, .black.opacity(0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 0.8)
            )
            .shadow(color: tint.opacity(0.25), radius: 6, x: 0, y: 3)
    }
}

// MARK: - Glass pill button style
//
// Drop-in replacement for the flat `tint.opacity(0.15)` capsule used by
// inline action buttons throughout the Track tab.

struct GlassPillButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(tint)
            .glassEffect(
                .regular.tint(tint.opacity(configuration.isPressed ? 0.40 : 0.22)),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(tint.opacity(0.30), lineWidth: 0.8)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Form primary button
//
// Full-width primary action at the end of a Form, drawn on the grouped
// background like the app's other bottom actions instead of inside a row card.

struct FormPrimaryButton: View {
    let title: String
    var systemImage: String = "checkmark"
    var isBusy: Bool = false
    let action: () -> Void

    var body: some View {
        Section {
            Button(action: action) {
                ZStack {
                    Label(title, systemImage: systemImage)
                        .opacity(isBusy ? 0 : 1)
                    if isBusy {
                        ProgressView()
                            .tint(.white)
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
            }
            .buttonStyle(.glassProminent)
            .disabled(isBusy)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }
}
