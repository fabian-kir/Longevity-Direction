import SwiftUI

extension MealCaptureCoordinator.Mode {
    var title: String {
        switch self {
        case .meal:    "Meal"
        case .barcode: "Barcode"
        }
    }

    var systemImage: String {
        switch self {
        case .meal:    "fork.knife"
        case .barcode: "barcode.viewfinder"
        }
    }
}

/// Glass segmented switch between meal photos and barcode scanning, drawn for
/// the dark camera background.
struct CaptureModePicker: View {
    @Binding var selection: MealCaptureCoordinator.Mode
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MealCaptureCoordinator.Mode.allCases, id: \.self) { mode in
                let isSelected = selection == mode
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = mode }
                } label: {
                    Label(mode.title, systemImage: mode.systemImage)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(isSelected ? .black : .white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(.white)
                                    .matchedGeometryEffect(id: "selection", in: highlight)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .glassEffect(.regular.tint(.black.opacity(0.45)), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.20), lineWidth: 0.6))
    }
}

/// Barcode mode's visual cue: dims the preview around a scanning frame.
/// Purely visual; codes are read anywhere in the picture.
struct BarcodeReticleOverlay: View {
    /// Where the frame sits, in this view's coordinates.
    var center: CGPoint
    /// Hidden while a detected code is lifted out; its brackets take over.
    var showsFrame = true

    private static let cornerRadius: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let rect = Self.frameRect(center: center, in: geo.size)
            ZStack {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geo.size))
                    path.addRoundedRect(
                        in: rect,
                        cornerSize: CGSize(width: Self.cornerRadius, height: Self.cornerRadius),
                        style: .continuous
                    )
                }
                .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))

                ReticleCorners(radius: Self.cornerRadius)
                    .stroke(.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .opacity(showsFrame ? 1 : 0)
            }
        }
        .allowsHitTesting(false)
    }

    static func frameRect(center: CGPoint, in size: CGSize) -> CGRect {
        let width = min(size.width * 0.72, 300)
        let height = width * 0.42
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }
}

/// Four rounded corner brackets, like a camera viewfinder.
private struct ReticleCorners: Shape {
    var radius: CGFloat
    var length: CGFloat = 26

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let corners: [(corner: CGPoint, horizontal: CGFloat, vertical: CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
            (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
        ]
        for (corner, dx, dy) in corners {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * length))
            path.addArc(
                tangent1End: corner,
                tangent2End: CGPoint(x: corner.x + dx * length, y: corner.y),
                radius: radius
            )
            path.addLine(to: CGPoint(x: corner.x + dx * length, y: corner.y))
        }
        return path
    }
}

/// Brief square where the user tapped to focus.
struct FocusIndicator: View {
    @State private var settled = false

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(.white, lineWidth: 1.5)
            .frame(width: 68, height: 68)
            .scaleEffect(settled ? 1 : 1.25)
            .shadow(color: .black.opacity(0.3), radius: 2)
            .onAppear {
                withAnimation(.snappy(duration: 0.2)) { settled = true }
            }
            .allowsHitTesting(false)
    }
}
