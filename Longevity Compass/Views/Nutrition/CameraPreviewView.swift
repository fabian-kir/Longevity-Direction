import AVFoundation
import SwiftUI
import UIKit

/// SwiftUI wrapper around AVCaptureVideoPreviewLayer. Owns no session; renders the
/// session passed in via the coordinator.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// Called on tap with the point in the view and the matching point in
    /// device coordinates, ready for `MealCaptureCoordinator.focus(at:)`.
    var onTap: ((_ viewPoint: CGPoint, _ devicePoint: CGPoint) -> Void)?
    var converter: PreviewPointConverter?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        converter?.layer = view.videoPreviewLayer
        view.addGestureRecognizer(UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        ))
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        // SwiftUI updates this view often (every frame of a panel drag); only
        // touch the layer's session when it actually changes.
        if uiView.videoPreviewLayer.session !== session {
            uiView.videoPreviewLayer.session = session
        }
        context.coordinator.onTap = onTap
        converter?.layer = uiView.videoPreviewLayer
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap)
    }

    final class Coordinator: NSObject {
        var onTap: ((CGPoint, CGPoint) -> Void)?

        init(onTap: ((CGPoint, CGPoint) -> Void)?) {
            self.onTap = onTap
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? PreviewView else { return }
            let point = recognizer.location(in: view)
            let devicePoint = view.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: point)
            onTap?(point, devicePoint)
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

/// Converts capture-device points (such as a barcode's corners) into the
/// preview's own coordinates, accounting for rotation and aspect fill.
@MainActor
final class PreviewPointConverter {
    fileprivate weak var layer: AVCaptureVideoPreviewLayer?

    func viewPoints(fromDevicePoints points: [CGPoint]) -> [CGPoint]? {
        guard let layer else { return nil }
        return points.map { layer.layerPointConverted(fromCaptureDevicePoint: $0) }
    }
}
