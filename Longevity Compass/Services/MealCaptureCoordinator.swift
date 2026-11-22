import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

@Observable
@MainActor
final class MealCaptureCoordinator: NSObject {

    /// `@unchecked`: the snapshot is an immutable image handed over once from
    /// the session queue.
    struct BarcodeDetection: Identifiable, Equatable, @unchecked Sendable {
        let id: UUID
        let payload: String
        let detectedAt: Date
        /// The code's outline in capture-device coordinates, ordered top-left,
        /// top-right, bottom-right, bottom-left as seen on a portrait screen.
        var corners: [CGPoint] = []
        /// The code cut out of the camera frame and straightened. Barcode mode only.
        var snapshot: UIImage?
        /// The whole frame the code was cut from, upright for a portrait screen.
        /// Shown in place of the live preview so the picture freezes on detection.
        var frame: UIImage?
    }

    enum Authorization {
        case undetermined
        case granted
        case denied
        case restricted
    }

    /// The two jobs need opposite camera settings. Meal photos want 1× zoom,
    /// full-range focus and the best image quality; barcodes want close-range
    /// zoom and focus so a small code decodes at a natural distance.
    enum Mode: String, CaseIterable, Sendable {
        case meal
        case barcode
    }

    private(set) var authorization: Authorization = .undetermined
    private(set) var isSessionRunning: Bool = false
    private(set) var captureError: String?
    private(set) var mode: Mode
    /// Barcode mode: a code to look up straight away.
    private(set) var detectedBarcode: BarcodeDetection?
    /// Meal mode: a code that happened to be readable. Offered as a hint rather
    /// than opened, so a package next to the plate doesn't interrupt the photo.
    private(set) var suggestedBarcode: BarcodeDetection?

    private static let modeDefaultsKey = "nutrition.captureMode"

    nonisolated(unsafe) let session: AVCaptureSession = AVCaptureSession()
    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) private let metadataOutput = AVCaptureMetadataOutput()
    /// Only enabled in barcode mode, to cut the detected code out of a frame.
    nonisolated(unsafe) private let videoOutput = AVCaptureVideoDataOutput()
    /// No intermediate caching: it could hold on to the camera's own frame
    /// buffers, which the capture pipeline needs back.
    nonisolated private let ciContext = CIContext(options: [.cacheIntermediates: false])
    nonisolated private let sessionQueue = DispatchQueue(label: "meal.capture.session")
    @ObservationIgnored
    nonisolated(unsafe) private var didConfigure = false
    @ObservationIgnored
    nonisolated(unsafe) private var isBarcodeDetectionEnabled = true
    @ObservationIgnored
    nonisolated(unsafe) private var barcodeStabilizer = LiveBarcodeStabilizer()
    /// `mode` as seen by the session queue.
    @ObservationIgnored
    nonisolated(unsafe) private var sessionMode: Mode
    /// Zoom that lets a small barcode fill the frame at the minimum focus distance.
    @ObservationIgnored
    nonisolated(unsafe) private var barcodeZoomFactor: CGFloat = 1.0
    @ObservationIgnored
    nonisolated(unsafe) private var device: AVCaptureDevice?
    /// A barcode-mode detection waiting for the next video frame to cut it out of.
    @ObservationIgnored
    nonisolated(unsafe) private var pendingDetection: (payload: String, corners: [CGPoint])?
    @ObservationIgnored
    nonisolated(unsafe) private var didWarmUpCoreImage = false

    private var captureContinuation: CheckedContinuation<UIImage, Error>?

    override init() {
        let saved = UserDefaults.standard.string(forKey: Self.modeDefaultsKey)
        let mode = saved.flatMap(Mode.init(rawValue:)) ?? .meal
        self.mode = mode
        self.sessionMode = mode
        super.init()
        refreshAuthorization()
    }

    func refreshAuthorization() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: authorization = .undetermined
        case .authorized:    authorization = .granted
        case .denied:        authorization = .denied
        case .restricted:    authorization = .restricted
        @unknown default:    authorization = .denied
        }
    }

    func requestAuthorization() async {
        if authorization == .undetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            authorization = granted ? .granted : .denied
        }
    }

    func start() async {
        await requestAuthorization()
        guard authorization == .granted else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                guard let self else { cont.resume(); return }
                self.configureIfNeeded()
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                Task { @MainActor in
                    self.isSessionRunning = self.session.isRunning
                    cont.resume()
                }
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            Task { @MainActor in
                self.isSessionRunning = false
            }
        }
    }

    func capturePhoto() async throws -> UIImage {
        guard authorization == .granted else {
            throw CaptureError.notAuthorized
        }
        return try await withCheckedThrowingContinuation { cont in
            captureContinuation = cont
            sessionQueue.async { [weak self] in
                guard let self else { return }
                let settings = AVCapturePhotoSettings()
                // The extra processing takes a moment but keeps the food detail
                // the AI relies on.
                settings.photoQualityPrioritization = self.photoOutput.maxPhotoQualityPrioritization
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        detectedBarcode = nil
        suggestedBarcode = nil
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.modeDefaultsKey)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.sessionMode = newMode
            // A code already offered as a hint should open at once in barcode
            // mode, not wait until it has left the frame.
            self.barcodeStabilizer = LiveBarcodeStabilizer()
            if let device = self.device { self.applyMode(newMode, to: device, animated: true) }
        }
    }

    /// Focuses and exposes for a point in device coordinates (0...1, landscape).
    func focus(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let device = self?.device,
                  (try? device.lockForConfiguration()) != nil
            else { return }
            defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .autoExpose
            }
            // Hand control back to continuous focus once the scene changes.
            device.isSubjectAreaChangeMonitoringEnabled = true
        }
    }

    /// Meal mode: opens the suggested code the same way barcode mode would.
    func acceptSuggestedBarcode() {
        guard let suggestion = suggestedBarcode else { return }
        suggestedBarcode = nil
        detectedBarcode = suggestion
    }

    func consumeBarcodeDetection(id: UUID) {
        guard detectedBarcode?.id == id else { return }
        suspendBarcodeDetection()
    }

    func suspendBarcodeDetection() {
        detectedBarcode = nil
        suggestedBarcode = nil
        sessionQueue.async { [weak self] in
            self?.isBarcodeDetectionEnabled = false
        }
    }

    /// Re-enables live recognition after product lookup or confirmation finishes.
    /// The stabilizer intentionally keeps the last delivered code suppressed until
    /// that code leaves the frame, preventing an immediate re-open.
    func resumeBarcodeDetection() {
        detectedBarcode = nil
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.isBarcodeDetectionEnabled = true
            self.barcodeStabilizer.restartAbsenceClock()
            if self.sessionMode == .barcode {
                self.videoOutput.connection(with: .video)?.isEnabled = true
            }
        }
    }

    enum CaptureError: LocalizedError {
        case notAuthorized
        case captureFailed(String)
        case noImageData

        var errorDescription: String? {
            switch self {
            case .notAuthorized:        return "Camera access is not authorized."
            case .captureFailed(let m): return "Capture failed: \(m)"
            case .noImageData:          return "Capture returned no image."
            }
        }
    }

    nonisolated private func configureIfNeeded() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard !didConfigure else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo

        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        if let device,
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        } else {
            Task { @MainActor in self.captureError = "No back camera available." }
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            // Capture settings may not ask for more than this; the default is `.balanced`.
            photoOutput.maxPhotoQualityPrioritization = .quality
        }

        // Preview-sized frames are plenty to freeze and cut from; full-size
        // ones would move tens of megabytes per frame for nothing.
        videoOutput.automaticallyConfiguresOutputBufferDimensions = false
        videoOutput.deliversPreviewSizedOutputBuffers = true
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        }

        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: sessionQueue)
            let retailTypes: [AVMetadataObject.ObjectType] = [.ean13, .ean8, .upce, .code128]
            metadataOutput.metadataObjectTypes = retailTypes.filter {
                metadataOutput.availableMetadataObjectTypes.contains($0)
            }
        }

        session.commitConfiguration()
        // The session preset only resolves the device's active format on commit,
        // so zoom and focus are set afterwards.
        if let device {
            self.device = device
            barcodeZoomFactor = Self.barcodeZoomFactor(for: device)
            applyMode(sessionMode, to: device, animated: false)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(subjectAreaDidChange),
                name: AVCaptureDevice.subjectAreaDidChangeNotification,
                object: device
            )
        }
        didConfigure = true
    }

    /// Barcode mode biases autofocus toward near subjects and zooms in; meal
    /// mode undoes both so a whole plate fits and stays sharp.
    nonisolated private func applyMode(_ mode: Mode, to device: AVCaptureDevice, animated: Bool) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }

        if device.isAutoFocusRangeRestrictionSupported {
            device.autoFocusRangeRestriction = (mode == .barcode) ? .near : .none
        }
        resetToContinuousFocus(device)
        videoOutput.connection(with: .video)?.isEnabled = (mode == .barcode)
        pendingDetection = nil
        if mode == .barcode { warmUpCoreImageIfNeeded() }

        let zoom = (mode == .barcode) ? barcodeZoomFactor : 1.0
        if animated {
            device.ramp(toVideoZoomFactor: zoom, withRate: 6)
        } else {
            device.videoZoomFactor = zoom
        }
    }

    /// Call with the device locked.
    nonisolated private func resetToContinuousFocus(_ device: AVCaptureDevice) {
        let center = CGPoint(x: 0.5, y: 0.5)
        if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = center }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = center }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        device.isSubjectAreaChangeMonitoringEnabled = false
    }

    /// After a tap to focus, the camera moved enough that the tapped point no
    /// longer means anything.
    @objc nonisolated private func subjectAreaDidChange(_ notification: Notification) {
        sessionQueue.async { [weak self] in
            guard let device = self?.device,
                  (try? device.lockForConfiguration()) != nil
            else { return }
            defer { device.unlockForConfiguration() }
            self?.resetToContinuousFocus(device)
        }
    }

    /// Wide-angle cameras on recent Pro iPhones cannot focus closer than roughly
    /// 20 cm, so a barcode held at a natural distance stays blurred and never
    /// decodes. Following Apple's AVCamBarcode sample, zoom in just enough that a
    /// 20 mm barcode fills the frame width at the minimum focus distance.
    nonisolated private static func barcodeZoomFactor(for device: AVCaptureDevice) -> CGFloat {
        let minFocusDistanceMM = Float(device.minimumFocusDistance)
        guard minFocusDistanceMM > 0 else { return 1.0 }
        let fieldOfView = device.activeFormat.videoFieldOfView * .pi / 180
        let minBarcodeWidthMM: Float = 20
        let fillRatio: Float = 0.4
        let minSubjectDistanceMM = (minBarcodeWidthMM / fillRatio) / (2 * tan(fieldOfView / 2))
        guard minSubjectDistanceMM < minFocusDistanceMM else { return 1.0 }

        let zoomFactor = CGFloat(minFocusDistanceMM / minSubjectDistanceMM)
        let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 2.0)
        return max(1.0, min(zoomFactor, maxZoom))
    }
}

extension MealCaptureCoordinator: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        Task { @MainActor in
            if let error {
                captureContinuation?.resume(throwing: CaptureError.captureFailed(error.localizedDescription))
                captureContinuation = nil
                return
            }
            guard let data = photo.fileDataRepresentation(),
                  let image = UIImage(data: data) else {
                captureContinuation?.resume(throwing: CaptureError.noImageData)
                captureContinuation = nil
                return
            }
            captureContinuation?.resume(returning: image)
            captureContinuation = nil
        }
    }
}

extension MealCaptureCoordinator: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard isBarcodeDetectionEnabled else { return }

        let code = metadataObjects
            .compactMap { $0 as? AVMetadataMachineReadableCodeObject }
            .first { !($0.stringValue ?? "").isEmpty }
        let payload = code?.stringValue

        let previouslySuppressed = barcodeStabilizer.suppressedPayload
        let stablePayload = barcodeStabilizer.observe(payload)

        if let left = previouslySuppressed, barcodeStabilizer.suppressedPayload == nil {
            // The code has left the frame, so its hint is out of date.
            Task { @MainActor [weak self] in
                guard let self, self.suggestedBarcode?.payload == left else { return }
                self.suggestedBarcode = nil
            }
        }

        guard let stablePayload else { return }
        let corners = Self.portraitOrdered(code?.corners ?? [])
        let mode = sessionMode
        // Barcode mode lifts the code out of the picture, which needs the next
        // video frame; the detection waits for it (one frame, ~30 ms).
        if mode == .barcode, corners.count == 4, videoOutput.connection(with: .video)?.isEnabled == true {
            pendingDetection = (stablePayload, corners)
            return
        }
        deliver(BarcodeDetection(id: UUID(), payload: stablePayload, detectedAt: .now, corners: corners), mode: mode)
    }

    nonisolated private func deliver(_ detection: BarcodeDetection, mode: Mode) {
        Task { @MainActor [weak self] in
            guard let self, self.mode == mode, self.detectedBarcode == nil else { return }
            switch mode {
            case .barcode: self.detectedBarcode = detection
            case .meal:    self.suggestedBarcode = detection
            }
        }
    }

    /// Orders a code's corners top-left, top-right, bottom-right, bottom-left
    /// as they appear on a portrait screen, so the cut-out comes out upright.
    /// Device coordinates follow the back camera's landscape sensor: on screen,
    /// x runs along 1 - y and y along x.
    nonisolated private static func portraitOrdered(_ corners: [CGPoint]) -> [CGPoint] {
        guard corners.count == 4 else { return [] }
        func onScreen(_ point: CGPoint) -> CGPoint { CGPoint(x: 1 - point.y, y: point.x) }
        let center = corners.map(onScreen).reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.x / 4, y: $0.y + $1.y / 4)
        }
        // With y pointing down, increasing angle runs clockwise.
        let clockwise = corners.sorted {
            let a = onScreen($0), b = onScreen($1)
            return atan2(a.y - center.y, a.x - center.x) < atan2(b.y - center.y, b.x - center.x)
        }
        let topLeft = clockwise.indices.min {
            let a = onScreen(clockwise[$0]), b = onScreen(clockwise[$1])
            return a.x + a.y < b.x + b.y
        } ?? 0
        return Array(clockwise[topLeft...] + clockwise[..<topLeft])
    }
}

extension MealCaptureCoordinator: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard let pending = pendingDetection else { return }
        pendingDetection = nil
        guard isBarcodeDetectionEnabled, sessionMode == .barcode else { return }
        // One frame is all a detection needs; frames resume with scanning.
        connection.isEnabled = false

        var detection = BarcodeDetection(
            id: UUID(),
            payload: pending.payload,
            detectedAt: .now,
            corners: pending.corners
        )
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
           let still = freeze(pixelBuffer, around: pending.corners) {
            detection.corners = still.corners
            detection.snapshot = still.cutOut
            detection.frame = still.frame
        }
        deliver(detection, mode: .barcode)
    }

    /// Renders the frame upright for a portrait screen and cuts the code out
    /// of that same image, so the cut-out matches the frozen picture pixel for
    /// pixel. Returns the corners actually used, padded with a small margin.
    nonisolated private func freeze(
        _ pixelBuffer: CVPixelBuffer,
        around corners: [CGPoint]
    ) -> (frame: UIImage, cutOut: UIImage, corners: [CGPoint])? {
        let portrait = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let extent = portrait.extent

        // Work in portrait pixels with y pointing down, like the screen. Device
        // coordinates follow the landscape sensor: on screen, x runs along
        // 1 - y and y along x.
        let quad = Self.padded(corners.map {
            CGPoint(x: (1 - $0.y) * extent.width, y: $0.x * extent.height)
        }, within: CGSize(width: extent.width, height: extent.height))
        func coreImagePoint(_ point: CGPoint) -> CGPoint {
            CGPoint(x: extent.minX + point.x, y: extent.maxY - point.y)
        }

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = portrait
        filter.topLeft = coreImagePoint(quad[0])
        filter.topRight = coreImagePoint(quad[1])
        filter.bottomRight = coreImagePoint(quad[2])
        filter.bottomLeft = coreImagePoint(quad[3])
        guard let straightened = filter.outputImage?
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.1])
            .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.4]),
              let cutOut = ciContext.createCGImage(straightened, from: straightened.extent),
              let frame = ciContext.createCGImage(portrait, from: extent)
        else { return nil }

        let deviceCorners = quad.map {
            CGPoint(x: $0.y / extent.height, y: 1 - $0.x / extent.width)
        }
        return (UIImage(cgImage: frame), UIImage(cgImage: cutOut), deviceCorners)
    }

    /// Adds a quiet-zone margin and, for 1D codes whose outline can be little
    /// more than a line, enough height to read as a barcode once lifted.
    /// Expects top-left, top-right, bottom-right, bottom-left with y pointing
    /// down; "down" is derived from the code's width so a flat outline can't
    /// tip it sideways.
    nonisolated private static func padded(_ quad: [CGPoint], within size: CGSize) -> [CGPoint] {
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }

        let (topLeft, topRight, bottomRight, bottomLeft) = (quad[0], quad[1], quad[2], quad[3])
        let leftMid = midpoint(topLeft, bottomLeft), rightMid = midpoint(topRight, bottomRight)
        let span = max(distance(leftMid, rightMid), 0.001)
        let right = CGPoint(x: (rightMid.x - leftMid.x) / span, y: (rightMid.y - leftMid.y) / span)
        let down = CGPoint(x: -right.y, y: right.x)

        let width = (distance(topLeft, topRight) + distance(bottomLeft, bottomRight)) / 2
        let topMid = midpoint(topLeft, topRight), bottomMid = midpoint(bottomLeft, bottomRight)
        let height = max(0, (bottomMid.x - topMid.x) * down.x + (bottomMid.y - topMid.y) * down.y)
        let margin = width * 0.06
        let vertical = margin + max(0, width * 0.45 - height) / 2

        func moved(_ point: CGPoint, _ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
            CGPoint(
                x: min(max(point.x + right.x * dx + down.x * dy, 0), size.width),
                y: min(max(point.y + right.y * dx + down.y * dy, 0), size.height)
            )
        }
        return [
            moved(topLeft, -margin, -vertical),
            moved(topRight, margin, -vertical),
            moved(bottomRight, margin, vertical),
            moved(bottomLeft, -margin, vertical),
        ]
    }

    /// Core Image builds its filters on first use, which would otherwise land
    /// in the middle of the first detection.
    nonisolated private func warmUpCoreImageIfNeeded() {
        guard !didWarmUpCoreImage else { return }
        didWarmUpCoreImage = true
        let sample = CIImage(color: .white)
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 12))
            .oriented(.right)
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = sample
        filter.topLeft = CGPoint(x: 1, y: 15)
        filter.topRight = CGPoint(x: 11, y: 15)
        filter.bottomRight = CGPoint(x: 11, y: 1)
        filter.bottomLeft = CGPoint(x: 1, y: 1)
        guard let output = filter.outputImage?
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.1])
            .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.4])
        else { return }
        _ = ciContext.createCGImage(output, from: output.extent)
        _ = ciContext.createCGImage(sample, from: sample.extent)
    }
}

/// Requires a barcode to persist across multiple metadata callbacks and suppresses
/// repeat delivery until several empty frames confirm it has left the camera view.
nonisolated struct LiveBarcodeStabilizer {
    private var candidate: String?
    private var consecutiveMatches = 0
    private var consecutiveMisses = 0
    /// The last delivered code, held back until it has left the frame.
    private(set) var suppressedPayload: String?
    /// When the held-back code was last in view.
    private var suppressedLastSeen: Date?

    private let matchesRequired: Int
    private let missesRequiredToReset: Int
    /// A gap this long between sightings also means the code left the frame.
    /// The camera doesn't reliably report empty frames, and reports none at
    /// all while it's paused, so counting misses alone can hold a code forever.
    private let absenceToReset: TimeInterval

    init(matchesRequired: Int = 3, missesRequiredToReset: Int = 5, absenceToReset: TimeInterval = 1) {
        self.matchesRequired = matchesRequired
        self.missesRequiredToReset = missesRequiredToReset
        self.absenceToReset = absenceToReset
    }

    /// Restarts the absence clock, e.g. when scanning resumes after a pause:
    /// a code still in view stays held back until it has been gone a moment.
    mutating func restartAbsenceClock(at now: Date = .now) {
        if suppressedPayload != nil { suppressedLastSeen = now }
    }

    mutating func observe(_ payload: String?, at now: Date = .now) -> String? {
        guard let payload, !payload.isEmpty else {
            consecutiveMisses += 1
            candidate = nil
            consecutiveMatches = 0
            if consecutiveMisses >= missesRequiredToReset {
                suppressedPayload = nil
            }
            return nil
        }

        consecutiveMisses = 0
        if payload == suppressedPayload {
            if let lastSeen = suppressedLastSeen, now.timeIntervalSince(lastSeen) >= absenceToReset {
                suppressedPayload = nil
            } else {
                suppressedLastSeen = now
                return nil
            }
        }

        if candidate == payload {
            consecutiveMatches += 1
        } else {
            candidate = payload
            consecutiveMatches = 1
        }

        guard consecutiveMatches >= matchesRequired else { return nil }
        suppressedPayload = payload
        suppressedLastSeen = now
        candidate = nil
        consecutiveMatches = 0
        return payload
    }
}
