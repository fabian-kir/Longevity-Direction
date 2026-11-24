import IntervalEngine
import SwiftUI

/// A restrained, shared palette for the interval experience. The colors remain
/// semantic without competing with each other when two phases are visible.
public enum N4x4Palette {
    public static let accent = Color(red: 0.10, green: 0.44, blue: 0.50)
    public static let warmUp = Color(red: 0.20, green: 0.42, blue: 0.62)
    public static let effort = Color(red: 0.76, green: 0.24, blue: 0.22)
    public static let recovery = Color(red: 0.14, green: 0.50, blue: 0.40)
    public static let workload = Color(red: 0.72, green: 0.48, blue: 0.16)
}

public extension RingColor {
    var swiftUIColor: Color {
        switch self {
        case .blue:  return N4x4Palette.warmUp
        case .red:   return N4x4Palette.effort
        case .green: return N4x4Palette.recovery
        case .amber: return N4x4Palette.workload
        }
    }
}

private enum PhaseFlowVisualStyle {
    case legacy
    case glassMarble
}

/// A full-bleed phase backdrop whose current-phase disc shrinks while the next
/// phase color grows inward from the screen edges.
public struct PhaseFlowView<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Keep the previous rendering path intact so this visual experiment can be
    // reverted without reconstructing the old circle and backdrop.
    private let visualStyle: PhaseFlowVisualStyle = .glassMarble

    private let progress: Double
    private let color: Color
    private let nextColor: Color?
    private let backgroundColor: Color
    private let minimumCoreRadius: CGFloat
    private let shadowRadius: CGFloat
    private let animatesProgress: Bool
    private let showsSpecularHighlight: Bool
    private let content: () -> Content

    public init(
        progress: Double,
        color: Color,
        nextColor: Color?,
        backgroundColor: Color,
        minimumCoreRadius: CGFloat,
        shadowRadius: CGFloat = 0,
        animatesProgress: Bool = true,
        showsSpecularHighlight: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.progress = progress
        self.color = color
        self.nextColor = nextColor
        self.backgroundColor = backgroundColor
        self.minimumCoreRadius = minimumCoreRadius
        self.shadowRadius = shadowRadius
        self.animatesProgress = animatesProgress
        self.showsSpecularHighlight = showsSpecularHighlight
        self.content = content
    }

    public var body: some View {
        GeometryReader { geometry in
            let maximumRadius = hypot(geometry.size.width, geometry.size.height) / 2 * 1.05
            let clampedProgress = min(max(progress, 0), 1)
            let discRadius = max(minimumCoreRadius, maximumRadius * (1 - clampedProgress))
            let phaseAnimation: Animation? = reduceMotion || !animatesProgress ? nil : .smooth(duration: 0.9)

            ZStack {
                backgroundColor

                if let nextColor {
                    incomingPhaseBackdrop(
                        color: nextColor,
                        discRadius: discRadius,
                        maximumRadius: maximumRadius,
                        size: geometry.size,
                        progress: clampedProgress
                    )
                    .animation(phaseAnimation, value: clampedProgress)
                }

                phaseDisc(radius: discRadius, animation: phaseAnimation)

                content()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func incomingPhaseBackdrop(
        color: Color,
        discRadius: CGFloat,
        maximumRadius: CGFloat,
        size: CGSize,
        progress: Double
    ) -> some View {
        switch visualStyle {
        case .legacy:
            ZStack {
                color.opacity(0.24 + 0.38 * progress)
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: color.opacity(0.02), location: 0),
                        .init(color: color.opacity(0.42 + 0.28 * progress), location: 0.72),
                        .init(color: color.opacity(0.78), location: 1),
                    ]),
                    center: .center,
                    startRadius: discRadius * 0.78,
                    endRadius: maximumRadius
                )
            }

        case .glassMarble:
            let clearBuffer = max(28, min(size.width, size.height) * 0.09)
            let revealStart = discRadius + clearBuffer
            let revealEnd = max(revealStart + 1, maximumRadius * 1.16)

            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.08),
                    .init(color: color.opacity(0.05), location: 0.24),
                    .init(color: color.opacity(0.14), location: 0.42),
                    .init(color: color.opacity(0.28), location: 0.60),
                    .init(color: color.opacity(0.48), location: 0.78),
                    .init(color: color.opacity(0.72), location: 1),
                ]),
                center: .center,
                startRadius: revealStart,
                endRadius: revealEnd
            )
        }
    }

    @ViewBuilder
    private func phaseDisc(radius: CGFloat, animation: Animation?) -> some View {
        switch visualStyle {
        case .legacy:
            legacyPhaseDisc(radius: radius, animation: animation)
        case .glassMarble:
            glassMarblePhaseDisc(radius: radius, animation: animation)
        }
    }

    private func legacyPhaseDisc(radius: CGFloat, animation: Animation?) -> some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: color.opacity(0.82), location: 0),
                            .init(color: color, location: 0.54),
                            .init(color: color.opacity(0.76), location: 1),
                        ]),
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: radius * 1.65
                    )
                )
                .overlay {
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.44), .white.opacity(0.04), .black.opacity(0.18)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.25
                        )
                }

            if showsSpecularHighlight {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.18), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: radius * 0.78
                        )
                    )
                    .frame(width: radius * 0.92, height: radius * 0.92)
                    .offset(x: -radius * 0.28, y: -radius * 0.30)
                    .blur(radius: max(4, radius * 0.08))
            }
        }
        .frame(width: radius * 2, height: radius * 2)
        .shadow(color: color.opacity(shadowRadius > 0 ? 0.48 : 0), radius: shadowRadius)
        .shadow(color: .black.opacity(0.14), radius: 10, y: 6)
        .allowsHitTesting(false)
        .animation(animation, value: radius)
    }

    private func glassMarblePhaseDisc(radius: CGFloat, animation: Animation?) -> some View {
        let rimWidth = max(1.25, min(3.5, radius * 0.018))

        return ZStack {
            Circle()
                .fill(color)

            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: .white.opacity(0.52), location: 0),
                            .init(color: color.opacity(0.90), location: 0.18),
                            .init(color: color.opacity(0.96), location: 0.52),
                            .init(color: .black.opacity(0.34), location: 0.82),
                            .init(color: .black.opacity(0.72), location: 1),
                        ]),
                        center: UnitPoint(x: 0.27, y: 0.22),
                        startRadius: 0,
                        endRadius: radius * 2.25
                    )
                )

            Circle()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.24), .clear, .black.opacity(0.28)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blendMode(.softLight)

            if showsSpecularHighlight {
                Ellipse()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.72), .white.opacity(0.12), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: radius * 0.92, height: radius * 0.34)
                    .rotationEffect(.degrees(-24))
                    .offset(x: -radius * 0.24, y: -radius * 0.42)
                    .blur(radius: max(1.5, radius * 0.018))

                Circle()
                    .trim(from: 0.56, to: 0.82)
                    .stroke(
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.48), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: max(1.5, radius * 0.025), lineCap: .round)
                    )
                    .padding(radius * 0.09)
                    .rotationEffect(.degrees(18))
                    .blur(radius: max(0.6, radius * 0.006))

                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.32), color.opacity(0.10), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: radius * 0.58
                        )
                    )
                    .frame(width: radius * 1.10, height: radius * 0.36)
                    .offset(x: radius * 0.18, y: radius * 0.54)
                    .blur(radius: max(2, radius * 0.035))
                    .blendMode(.screen)
            }

            #if os(iOS)
            if #available(iOS 26.0, *) {
                Circle()
                    .fill(.clear)
                    .glassEffect(.clear.tint(color.opacity(0.10)), in: Circle())
            }
            #endif
        }
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.76),
                            .white.opacity(0.16),
                            .black.opacity(0.42),
                            .white.opacity(0.24),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: rimWidth
                )
        }
        .overlay {
            Circle()
                .inset(by: rimWidth * 1.8)
                .stroke(.white.opacity(0.10), lineWidth: max(0.6, rimWidth * 0.45))
        }
        .frame(width: radius * 2, height: radius * 2)
        .shadow(color: color.opacity(shadowRadius > 0 ? 0.36 : 0), radius: shadowRadius * 0.8)
        .shadow(color: .black.opacity(0.30), radius: 14, y: 9)
        .allowsHitTesting(false)
        .animation(animation, value: radius)
    }
}
