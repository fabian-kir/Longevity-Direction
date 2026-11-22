import SwiftUI
import UIKit

/// Played when barcode mode reads a code: the scanning brackets snap onto the
/// code, then its cut-out lifts off the camera picture, straightening and
/// growing into a card while the product is looked up.
struct BarcodeLiftView: View {
    struct Lifted: Identifiable, Equatable {
        let id: UUID
        let payload: String
        let image: UIImage?
        /// The camera frame it was cut from, shown frozen behind the lift.
        let frame: UIImage?
        /// Where the code sits on screen.
        let quad: Quad
    }

    let lifted: Lifted
    /// The scanning frame the brackets fly from.
    let frameRect: CGRect
    /// Centre of the finished card.
    let center: CGPoint
    let isResolving: Bool

    @State private var lock: CGFloat = 0
    @State private var lift: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let card = cardRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                Color.black
                    .modifier(ProgressOpacity(progress: lift) { 0.45 * min(max($0, 0), 1) })

                QuadBrackets(from: Quad(frameRect), to: lifted.quad, progress: lock)
                    .stroke(.yellow, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                    .modifier(ProgressOpacity(progress: lift) { 1 - min(max($0 * 3, 0), 1) })

                cutOut
                    .frame(width: card.width, height: card.height)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
                    .modifier(QuadMorph(from: lifted.quad, to: Quad(card), progress: lift))
                    // Appears the moment the lift starts, exactly over the live code.
                    .modifier(ProgressOpacity(progress: lift) { $0 > 0.001 ? 1 : 0 })

                details
                    .frame(width: card.width)
                    .position(x: card.midX, y: card.maxY + 40)
                    .modifier(ProgressOpacity(progress: lift) { min(max(($0 - 0.75) * 4, 0), 1) })
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25)) { lock = 1 }
            // Slow on purpose: the point is to watch the code come off the picture.
            withAnimation(.spring(duration: 0.9, bounce: 0.18).delay(0.3)) { lift = 1 }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Barcode \(lifted.payload)")
    }

    @ViewBuilder
    private var cutOut: some View {
        if let image = lifted.image {
            Image(uiImage: image)
                .resizable()
        } else {
            Color.white
                .overlay {
                    Image(systemName: "barcode")
                        .resizable()
                        .scaledToFit()
                        .padding(18)
                        .foregroundStyle(.black)
                }
        }
    }

    private var details: some View {
        VStack(spacing: 8) {
            Text(lifted.payload)
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
            if isResolving {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("Looking up product…")
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private func cardRect(in size: CGSize) -> CGRect {
        let width = min(size.width - 48, 380)
        let aspect = lifted.image.map { $0.size.height / max($0.size.width, 1) } ?? 0.5
        let height = width * min(max(aspect, 0.3), 0.8)
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }
}

/// Four corners, ordered top-left, top-right, bottom-right, bottom-left.
struct Quad: Equatable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    init(_ rect: CGRect) {
        topLeft = CGPoint(x: rect.minX, y: rect.minY)
        topRight = CGPoint(x: rect.maxX, y: rect.minY)
        bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)
        bottomLeft = CGPoint(x: rect.minX, y: rect.maxY)
    }

    init?(_ points: [CGPoint]) {
        guard points.count == 4 else { return nil }
        (topLeft, topRight, bottomRight, bottomLeft) = (points[0], points[1], points[2], points[3])
    }

    var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    /// Unclamped, so a spring's overshoot carries through.
    func interpolated(to other: Quad, _ t: CGFloat) -> Quad {
        func mix(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        var quad = self
        quad.topLeft = mix(topLeft, other.topLeft)
        quad.topRight = mix(topRight, other.topRight)
        quad.bottomRight = mix(bottomRight, other.bottomRight)
        quad.bottomLeft = mix(bottomLeft, other.bottomLeft)
        return quad
    }
}

extension ProjectionTransform {
    /// The perspective transform (homography) that maps `rect` onto `quad`,
    /// after Heckbert's square-to-quadrilateral construction.
    static func mapping(_ rect: CGRect, to quad: Quad) -> ProjectionTransform {
        let (x0, y0) = (quad.topLeft.x, quad.topLeft.y)
        let (x1, y1) = (quad.topRight.x, quad.topRight.y)
        let (x2, y2) = (quad.bottomRight.x, quad.bottomRight.y)
        let (x3, y3) = (quad.bottomLeft.x, quad.bottomLeft.y)

        // Unit square to quad: x' = (a u + b v + c) / (g u + h v + 1), likewise y'.
        var (g, h): (CGFloat, CGFloat) = (0, 0)
        let sx = x0 - x1 + x2 - x3
        let sy = y0 - y1 + y2 - y3
        if abs(sx) > 1e-9 || abs(sy) > 1e-9 {
            let dx1 = x1 - x2, dx2 = x3 - x2
            let dy1 = y1 - y2, dy2 = y3 - y2
            let det = dx1 * dy2 - dx2 * dy1
            if abs(det) > 1e-9 {
                g = (sx * dy2 - dx2 * sy) / det
                h = (dx1 * sy - sx * dy1) / det
            }
        }
        let a = x1 - x0 + g * x1, b = x3 - x0 + h * x3, c = x0
        let d = y1 - y0 + g * y1, e = y3 - y0 + h * y3, f = y0

        // Rows act on [u v 1] with u = (x - minX) / width, v = (y - minY) / height.
        let su = 1 / max(rect.width, 0.001), sv = 1 / max(rect.height, 0.001)
        var square = ProjectionTransform()
        square.m11 = a; square.m12 = d; square.m13 = g
        square.m21 = b; square.m22 = e; square.m23 = h
        square.m31 = c; square.m32 = f; square.m33 = 1
        let toUnit = ProjectionTransform(
            CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
                .concatenating(CGAffineTransform(scaleX: su, y: sv))
        )
        return toUnit.concatenating(square)
    }
}

/// Places a view's frame onto a quad partway between `from` and `to`.
private struct QuadMorph: GeometryEffect {
    var from: Quad
    var to: Quad
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        .mapping(CGRect(origin: .zero, size: size), to: from.interpolated(to: to, progress))
    }
}

/// Corner brackets on a quad partway between `from` and `to`.
private struct QuadBrackets: Shape {
    var from: Quad
    var to: Quad
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let corners = from.interpolated(to: to, progress).corners
        var path = Path()
        for index in corners.indices {
            let corner = corners[index]
            let previous = corners[(index + 3) % 4]
            let next = corners[(index + 1) % 4]
            let length = min(26, Self.distance(corner, previous) * 0.3, Self.distance(corner, next) * 0.3)
            path.move(to: Self.point(from: corner, toward: previous, length: length))
            path.addLine(to: corner)
            path.addLine(to: Self.point(from: corner, toward: next, length: length))
        }
        return path
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    private static func point(from a: CGPoint, toward b: CGPoint, length: CGFloat) -> CGPoint {
        let total = max(distance(a, b), 0.001)
        return CGPoint(x: a.x + (b.x - a.x) * length / total, y: a.y + (b.y - a.y) * length / total)
    }
}

/// Opacity computed from an animated progress value on every frame, so the
/// fades follow their own curves rather than the progress animation's.
private struct ProgressOpacity: ViewModifier, Animatable {
    var progress: CGFloat
    let opacity: (Double) -> Double

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.opacity(opacity(Double(progress)))
    }
}
