import SwiftUI
import SwiftData
import UIKit

struct NutritionTabView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Query(sort: \NutritionEntry.date, order: .reverse) private var entries: [NutritionEntry]

    @State private var captured: CapturedImage?
    @State private var savedNotice: String?
    @State private var isCapturing = false
    @State private var showLibraryPicker = false
    @State private var showFoodSearch = false
    @State private var libraryImage: UIImage?
    @State private var detectedProduct: DetectedProduct?
    @State private var isResolvingBarcode = false
    @State private var showLogSymptom = false
    /// Bumped per symptom log, for the confirming haptic.
    @State private var symptomLogCount = 0
    @State private var opensInsightsAfterSymptomSheet = false
    @State private var showDigestionInsights = false
    @State private var showPendingMeals = false
    @State private var focusTap: FocusTap?
    @State private var isExpanded = false
    /// Live drag offset of the dashboard panel from its resting point.
    @State private var panelDrag: CGFloat = 0
    @State private var cameraSwipeAxis: SwipeAxis?
    @State private var dashboardPosition = ScrollPosition(edge: .top)
    @State private var isDashboardDragging = false
    /// False while another tab or a pushed screen covers this one.
    @State private var isVisible = false
    @State private var liftedBarcode: BarcodeLiftView.Lifted?
    @State private var previewConverter = PreviewPointConverter()

    private struct CapturedImage: Identifiable {
        let id = UUID()
        let image: UIImage
        let date: Date
    }

    private struct DetectedProduct: Identifiable {
        let id = UUID()
        let product: OpenFoodFactsProduct
        let detectedAt: Date
    }

    private struct FocusTap: Identifiable {
        let id = UUID()
        let point: CGPoint
    }

    private enum SwipeAxis {
        case horizontal
        case vertical
    }

    var body: some View {
        GeometryReader { geo in
            let layout = CaptureLayout(size: geo.size, insets: geo.safeAreaInsets)
            ZStack(alignment: .topLeading) {
                cameraLayer(layout)
                dashboardPanel(layout)
                topBar(layout)
            }
            .ignoresSafeArea()
        }
        .background(Color.black)
        .navigationTitle("Nutrition")
        .toolbar(.hidden, for: .navigationBar)
        // Like the system Camera: the clock would be dark on dark in light mode.
        .statusBarHidden(isShowingCamera)
        .sheet(isPresented: $showLogSymptom, onDismiss: symptomSheetDismissed) {
            LogSymptomSheet(
                onLogged: { symptomLogCount += 1 },
                onOpenInsights: { opensInsightsAfterSymptomSheet = true }
            )
        }
        .navigationDestination(isPresented: $showDigestionInsights) {
            DigestionInsightsView()
        }
        .sensoryFeedback(.success, trigger: symptomLogCount)
        .sheet(isPresented: $showPendingMeals, onDismiss: resumeBarcodeDetection) {
            PendingMealsSheet()
        }
        .sheet(item: $captured, onDismiss: resumeBarcodeDetection) { item in
            PostCaptureSheet(image: item.image, capturedAt: item.date) { outcome in
                handleSheetOutcome(outcome)
            }
        }
        .sheet(item: $detectedProduct, onDismiss: resumeBarcodeDetection) { item in
            DetectedBarcodeProductSheet(
                product: item.product,
                detectedAt: item.detectedAt
            ) { title in
                detectedProduct = nil
                flash("Logged \(title)")
            }
        }
        .sheet(isPresented: $showFoodSearch, onDismiss: resumeBarcodeDetection) {
            FoodSearchSheet { title in
                flash("Logged \(title)")
            }
        }
        .sheet(isPresented: $showLibraryPicker, onDismiss: resumeBarcodeDetection) {
            CameraPickerView(mode: .library) { image in
                showLibraryPicker = false
                if let image {
                    captured = CapturedImage(image: image, date: .now)
                }
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .top) { toast }
        .task {
            if !isExpanded { await services.mealCapture.start() }
        }
        // Not `.task(id:)`: resolveBarcode consumes the detection, which changes
        // the id and would cancel its own in-flight lookup request.
        .onChange(of: services.mealCapture.detectedBarcode?.id) {
            guard let detection = services.mealCapture.detectedBarcode else { return }
            Task { await resolveBarcode(detection) }
        }
        .sensoryFeedback(.success, trigger: services.mealCapture.detectedBarcode?.id) { _, new in
            new != nil
        }
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            liftedBarcode = nil
            services.mealCapture.stop()
        }
        .onChange(of: services.mealCapture.mode) {
            guard liftedBarcode != nil else { return }
            liftedBarcode = nil
            Task { await services.mealCapture.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            // A frozen barcode card restarts the camera itself when it goes.
            if phase == .active && !isExpanded && liftedBarcode == nil {
                Task { await services.mealCapture.start() }
            } else {
                services.mealCapture.stop()
            }
        }
        // The camera only runs while it's visible: saves battery and turns off
        // the camera-in-use indicator while the dashboard is open.
        .onChange(of: isExpanded) { _, expanded in
            if expanded {
                liftedBarcode = nil
                services.mealCapture.stop()
            } else if scenePhase == .active, services.selectedTab == .nutrition {
                Task { await services.mealCapture.start() }
            }
        }
        // The tab always reopens on the camera.
        .onChange(of: services.selectedTab) { _, tab in
            if tab != .nutrition { isExpanded = false }
        }
    }

    private var isShowingCamera: Bool {
        isVisible && !isExpanded
    }

    // MARK: - Camera

    @ViewBuilder
    private func cameraLayer(_ layout: CaptureLayout) -> some View {
        let mode = services.mealCapture.mode
        let viewfinder = layout.viewfinder
        // Meal photos keep the true 3:4 frame so the preview shows exactly what
        // the AI gets; barcodes don't care about framing, so they get the screen.
        let previewRect = mode == .barcode ? CGRect(origin: .zero, size: layout.full) : viewfinder

        ZStack(alignment: .topLeading) {
            Color.black

            switch services.mealCapture.authorization {
            case .granted:
                cameraPreview
                    .frame(width: previewRect.width, height: previewRect.height)
                    .clipped()
                    .offset(x: previewRect.minX, y: previewRect.minY)
                if let frozenFrame = liftedBarcode?.frame {
                    // The frame the code was cut from, filled exactly like the
                    // preview, so the picture freezes without a jump.
                    Image(uiImage: frozenFrame)
                        .resizable()
                        .scaledToFill()
                        .frame(width: previewRect.width, height: previewRect.height)
                        .clipped()
                        .offset(x: previewRect.minX, y: previewRect.minY)
                }
                if mode == .barcode {
                    let center = CGPoint(x: viewfinder.midX, y: viewfinder.midY)
                    BarcodeReticleOverlay(center: center, showsFrame: liftedBarcode == nil)
                        .transition(.opacity)
                    if let liftedBarcode {
                        BarcodeLiftView(
                            lifted: liftedBarcode,
                            frameRect: BarcodeReticleOverlay.frameRect(center: center, in: layout.full),
                            center: center,
                            isResolving: isResolvingBarcode
                        )
                        .id(liftedBarcode.id)
                        .transition(.opacity)
                    }
                }
            case .denied, .restricted:
                permissionDeniedView
                    .frame(width: viewfinder.width, height: viewfinder.height)
                    .offset(x: viewfinder.minX, y: viewfinder.minY)
            case .undetermined:
                ProgressView()
                    .tint(.white)
                    .frame(width: viewfinder.width, height: viewfinder.height)
                    .offset(x: viewfinder.minX, y: viewfinder.minY)
            }

            if !isCameraUnavailable {
                VStack(spacing: 12) {
                    if mode == .meal {
                        if services.mealCapture.suggestedBarcode != nil {
                            barcodeSuggestionChip
                                .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                        shutterRow
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 24)
                .frame(width: layout.full.width, height: max(0, viewfinder.maxY - 16), alignment: .bottom)

                CaptureModePicker(selection: captureMode)
                    .position(layout.modePickerCenter)
            }
        }
        .frame(width: layout.full.width, height: layout.full.height)
        .gesture(cameraSwipe(layout))
        .animation(.easeInOut(duration: 0.2), value: mode)
        .animation(.snappy(duration: 0.25), value: services.mealCapture.suggestedBarcode?.id)
    }

    private var cameraPreview: some View {
        CameraPreviewView(
            session: services.mealCapture.session,
            onTap: { point, devicePoint in
                services.mealCapture.focus(at: devicePoint)
                focusTap = FocusTap(point: point)
            },
            converter: previewConverter
        )
        .overlay {
            if let focusTap {
                FocusIndicator()
                    .id(focusTap.id)
                    .position(focusTap.point)
                    .transition(.opacity)
            }
        }
        .task(id: focusTap?.id) {
            guard focusTap != nil else { return }
            try? await Task.sleep(for: .seconds(0.9))
            withAnimation { focusTap = nil }
        }
    }

    /// Sideways swipes switch mode like the system Camera; swiping up pulls the
    /// dashboard over the camera.
    private func cameraSwipe(_ layout: CaptureLayout) -> some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .global)
            .onChanged { value in
                let translation = value.translation
                let axis = cameraSwipeAxis
                    ?? (abs(translation.width) > abs(translation.height) ? .horizontal : .vertical)
                cameraSwipeAxis = axis
                if axis == .vertical {
                    panelDrag = min(0, translation.height)
                }
            }
            .onEnded { value in
                let axis = cameraSwipeAxis
                cameraSwipeAxis = nil
                switch axis {
                case .horizontal:
                    let distance = value.predictedEndTranslation.width
                    guard abs(distance) > 60 else { return }
                    withAnimation(.snappy(duration: 0.25)) {
                        // The picker reads Meal | Barcode, so a swipe left moves right.
                        captureMode.wrappedValue = distance < 0 ? .barcode : .meal
                    }
                case .vertical:
                    settlePanel(predictedTranslation: value.predictedEndTranslation.height, layout: layout)
                case nil:
                    break
                }
            }
    }

    private var captureMode: Binding<MealCaptureCoordinator.Mode> {
        Binding(
            get: { services.mealCapture.mode },
            set: { services.mealCapture.setMode($0) }
        )
    }

    /// Meal mode found a readable code. Offered rather than opened, so it also
    /// teaches that the camera can scan barcodes.
    private var barcodeSuggestionChip: some View {
        Button {
            services.mealCapture.acceptSuggestedBarcode()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "barcode.viewfinder")
                Text("Barcode found · Look up")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .glassEffect(.regular.tint(.black.opacity(0.45)), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.30), lineWidth: 0.6))
        }
        .disabled(isResolvingBarcode)
    }

    /// Access is off: the permission view offers its own Library and Settings
    /// buttons, so the shutter row would only cover them.
    private var isCameraUnavailable: Bool {
        switch services.mealCapture.authorization {
        case .denied, .restricted: true
        case .granted, .undetermined: false
        }
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.8))
            Text("Camera access is off")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Use the library, or enable camera access in Settings.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 10) {
                Button {
                    services.mealCapture.suspendBarcodeDetection()
                    showLibraryPicker = true
                } label: {
                    Label("Library", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.glassProminent)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Text("Open Settings")
                }
                .buttonStyle(.glass)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var shutterRow: some View {
        HStack {
            Button {
                services.mealCapture.suspendBarcodeDetection()
                showLibraryPicker = true
            } label: {
                Image(systemName: "photo.on.rectangle")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(width: Self.sideButtonSize, height: Self.sideButtonSize)
                    .glassEffect(.regular.tint(.white.opacity(0.12)), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.30), lineWidth: 0.8))
            }
            .accessibilityLabel("Choose from library")

            Spacer()

            Button {
                Task { await snap() }
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.white, lineWidth: 4)
                        .frame(width: 76, height: 76)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 62, height: 62)
                        .opacity(isCapturing ? 0.4 : 1.0)
                        .scaleEffect(isCapturing ? 0.92 : 1.0)
                        .animation(.easeOut(duration: 0.15), value: isCapturing)
                }
            }
            .accessibilityLabel("Take photo")
            .disabled(
                isCapturing
                || isResolvingBarcode
                || services.mealCapture.authorization != .granted
            )

            Spacer()

            // Same width as the library button, so the shutter sits centred.
            Color.clear.frame(width: Self.sideButtonSize, height: Self.sideButtonSize)
        }
    }

    private static let sideButtonSize: CGFloat = 52

    // MARK: - Top bar

    /// Floats over both the camera and the open dashboard, replacing the
    /// navigation bar so the camera can reach the top of the screen.
    private func topBar(_ layout: CaptureLayout) -> some View {
        HStack(spacing: 10) {
            if isExpanded {
                cameraButton
            } else if !services.pendingMeals.pending.isEmpty {
                pendingBadge
            }
            Spacer()
            if services.isTrackingDigestion {
                // Logs straight away; Digestion Insights is linked from the sheet.
                Button {
                    services.mealCapture.suspendBarcodeDetection()
                    showLogSymptom = true
                } label: {
                    topBarIcon("heart.text.clipboard")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Log symptom")
            }
            NavigationLink {
                NutritionHistoryView()
            } label: {
                topBarIcon("list.bullet.rectangle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Nutrition history")
            Button {
                services.mealCapture.suspendBarcodeDetection()
                showFoodSearch = true
            } label: {
                topBarIcon("magnifyingglass")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search food")
        }
        .padding(.horizontal, 16)
        .frame(height: CaptureLayout.topBarHeight)
        .padding(.top, layout.insets.top + 4)
        .animation(.snappy(duration: 0.2), value: isExpanded)
    }

    private func topBarIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.body.weight(.semibold))
            .foregroundStyle(isExpanded ? Color.primary : .white)
            .frame(width: CaptureLayout.topBarHeight, height: CaptureLayout.topBarHeight)
            .glassEffect(
                isExpanded ? .regular.interactive() : .regular.tint(.black.opacity(0.35)).interactive(),
                in: Circle()
            )
    }

    private var cameraButton: some View {
        Button {
            setExpanded(false)
        } label: {
            Label("Camera", systemImage: "camera.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 16)
                .frame(height: CaptureLayout.topBarHeight)
                .glassEffect(.regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var pendingBadgeIcon: String {
        if !services.pendingMeals.isAISharingAllowed { return "pause.circle" }
        return services.pendingMeals.isOnline ? "icloud.and.arrow.up" : "wifi.slash"
    }

    private var pendingBadge: some View {
        Button {
            services.mealCapture.suspendBarcodeDetection()
            showPendingMeals = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: pendingBadgeIcon)
                Text("\(services.pendingMeals.pending.count) pending")
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .opacity(0.7)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .glassEffect(.regular.tint(.black.opacity(0.45)), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.20), lineWidth: 0.6))
        }
        .accessibilityHint("Shows meal photos waiting for analysis")
    }

    // MARK: - Dashboard panel

    /// Rests as a peek with today's intake under the camera; drag it up, tap
    /// it or swipe up on the camera to open the full dashboard.
    private func dashboardPanel(_ layout: CaptureLayout) -> some View {
        let progress = panelProgress(layout)
        let grabberHeight: CGFloat = 18
        // Expanded, the floating top bar sits over the panel's header.
        let expandedHeaderHeight = layout.insets.top + CaptureLayout.topBarHeight + 12
        let headerHeight = grabberHeight + (expandedHeaderHeight - grabberHeight) * progress

        return VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .opacity(1 - progress)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .frame(height: headerHeight)
                .contentShape(Rectangle())
                .gesture(panelDragGesture(layout))
                .accessibilityHidden(true)

            ZStack(alignment: .top) {
                dashboardScroll(layout)
                    .opacity(progress)
                    .allowsHitTesting(isExpanded)
                    .accessibilityHidden(!isExpanded)

                IntakePeekView(entries: entries)
                    .padding(.horizontal, 20)
                    .frame(height: CaptureLayout.peekHeight - grabberHeight, alignment: .top)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { setExpanded(true) }
                    .gesture(panelDragGesture(layout))
                    .opacity(1 - min(progress * 2, 1))
                    .allowsHitTesting(!isExpanded)
                    .accessibilityHidden(isExpanded)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Shows your nutrition dashboard")
                    .accessibilityAction { setExpanded(true) }
            }
        }
        .frame(width: layout.full.width, height: layout.full.height, alignment: .top)
        .background(
            Color(.systemGroupedBackground),
            in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: -2)
        .offset(y: panelTop(layout))
    }

    private func dashboardScroll(_ layout: CaptureLayout) -> some View {
        ScrollView {
            dashboardContent
                .padding(.horizontal)
                .padding(.top, 4)
                // The panel ignores the safe area; keep the end clear of the tab bar.
                .padding(.bottom, layout.insets.bottom + 16)
        }
        .scrollPosition($dashboardPosition)
        .onScrollPhaseChange { _, phase in
            isDashboardDragging = phase == .interacting
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            // Pulling down past the top hands the screen back to the camera.
            if offset < -80, isDashboardDragging, isExpanded {
                setExpanded(false)
            }
        }
    }

    @ViewBuilder
    private var dashboardContent: some View {
        if let digest = services.nutritionDigest {
            NutritionDashboardView(digest: digest, entries: entries)
        } else {
            ProgressView("Building your food pattern…")
                .foregroundStyle(.secondary)
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        }
    }

    private func panelTop(_ layout: CaptureLayout) -> CGFloat {
        let collapsed = layout.collapsedTop
        let proposed = (isExpanded ? 0 : collapsed) + panelDrag
        // Rubber-band past either resting point.
        if proposed < 0 { return proposed * 0.2 }
        if proposed > collapsed { return collapsed + (proposed - collapsed) * 0.2 }
        return proposed
    }

    /// 0 with only the peek showing, 1 fully open.
    private func panelProgress(_ layout: CaptureLayout) -> CGFloat {
        guard layout.collapsedTop > 0 else { return 0 }
        return min(max(1 - panelTop(layout) / layout.collapsedTop, 0), 1)
    }

    private func panelDragGesture(_ layout: CaptureLayout) -> some Gesture {
        // Global space: the panel moves with the finger, so local coordinates would drift.
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { panelDrag = $0.translation.height }
            .onEnded { settlePanel(predictedTranslation: $0.predictedEndTranslation.height, layout: layout) }
    }

    /// Snaps to whichever resting point the fling would land nearer to.
    private func settlePanel(predictedTranslation: CGFloat, layout: CaptureLayout) {
        let start = isExpanded ? 0 : layout.collapsedTop
        setExpanded(start + predictedTranslation < layout.collapsedTop / 2)
    }

    private func setExpanded(_ expanded: Bool) {
        withAnimation(.spring(duration: 0.4, bounce: 0.12)) {
            isExpanded = expanded
            panelDrag = 0
        }
        if !expanded {
            dashboardPosition.scrollTo(edge: .top)
        }
    }

    // MARK: - Toast

    @ViewBuilder
    private var toast: some View {
        if let notice = savedNotice {
            Text(notice)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassEffect(.regular, in: Capsule())
                .padding(.horizontal, 24)
                // Below the floating top bar.
                .padding(.top, CaptureLayout.topBarHeight + 16)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Actions

    private func snap() async {
        guard !isCapturing, !isResolvingBarcode, detectedProduct == nil else { return }
        services.mealCapture.suspendBarcodeDetection()
        isCapturing = true
        defer { isCapturing = false }
        do {
            let image = try await services.mealCapture.capturePhoto()
            captured = CapturedImage(image: image, date: .now)
        } catch {
            services.mealCapture.resumeBarcodeDetection()
            flash("Could not capture photo")
        }
    }

    private func resolveBarcode(_ detection: MealCaptureCoordinator.BarcodeDetection) async {
        guard captured == nil,
              detectedProduct == nil,
              !showLibraryPicker,
              !showFoodSearch,
              !showPendingMeals,
              !showLogSymptom,
              !isCapturing,
              !isResolvingBarcode
        else { return }

        isResolvingBarcode = true
        services.mealCapture.consumeBarcodeDetection(id: detection.id)
        defer { isResolvingBarcode = false }
        let isLifting = liftBarcode(detection)
        // Let the lift play out before a sheet or a toast covers it.
        let liftEnds = ContinuousClock.now + (isLifting ? .milliseconds(1100) : .zero)
        if isLifting, liftedBarcode?.frame != nil {
            // The frozen frame now covers the preview; pause the camera behind
            // it so nothing redraws over a moving picture while the card and
            // the product sheet are up. A moment's delay lets the frozen frame
            // reach the screen first.
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                if liftedBarcode?.id == detection.id { services.mealCapture.stop() }
            }
        }

        let result: Result<OpenFoodFactsProduct, Error>
        do {
            result = .success(try await OpenFoodFactsClient.lookup(barcode: detection.payload))
        } catch {
            result = .failure(error)
        }
        try? await Task.sleep(until: liftEnds)

        switch result {
        case .success(let product):
            detectedProduct = DetectedProduct(product: product, detectedAt: detection.detectedAt)
        case .failure(let error):
            // A short toast tells the user the code was read, so an unknown
            // product or a failed lookup is not mistaken for a scanner that
            // never sees anything. The camera then returns to recognition mode.
            if case OpenFoodFactsError.notFound = error {
                flash("Barcode \(detection.payload) not in Open Food Facts")
            } else {
                flash("Barcode lookup failed: \(error.localizedDescription)")
            }
            resumeBarcodeDetection()
        }
    }

    /// Barcode mode: starts lifting the code's cut-out off the preview.
    /// Returns whether the animation is playing.
    private func liftBarcode(_ detection: MealCaptureCoordinator.BarcodeDetection) -> Bool {
        guard services.mealCapture.mode == .barcode,
              // In barcode mode the preview fills the screen from its top-left
              // corner, so preview points are already screen points.
              let points = previewConverter.viewPoints(fromDevicePoints: detection.corners),
              let quad = Quad(points)
        else { return false }
        liftedBarcode = BarcodeLiftView.Lifted(
            id: detection.id,
            payload: detection.payload,
            image: detection.snapshot,
            frame: detection.frame,
            quad: quad
        )
        return true
    }

    private func dropLiftedBarcode() {
        withAnimation(.easeOut(duration: 0.25)) { liftedBarcode = nil }
    }

    private func symptomSheetDismissed() {
        resumeBarcodeDetection()
        if opensInsightsAfterSymptomSheet {
            opensInsightsAfterSymptomSheet = false
            showDigestionInsights = true
        }
    }

    private func resumeBarcodeDetection() {
        services.mealCapture.resumeBarcodeDetection()
        guard liftedBarcode != nil else { return }
        Task {
            // Keep the frozen picture until the live one is back, so the
            // camera never flashes black on the way out.
            if isVisible && !isExpanded && scenePhase == .active {
                await services.mealCapture.start()
            }
            dropLiftedBarcode()
        }
    }

    private func handleSheetOutcome(_ outcome: PostCaptureSheet.Outcome) {
        captured = nil
        switch outcome {
        case .saved(let title):       flash("Logged \(title)")
        case .queued:                 flash("Saved — will analyse when online")
        case .heldForAISharing:       flash("Photo kept for later")
        case .cancelled, .failed:     break
        }
    }

    private func flash(_ text: String) {
        withAnimation { savedNotice = text }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation { savedNotice = nil }
        }
    }
}

// MARK: - Layout

/// Screen geometry for the full-screen camera, in the coordinates of a view
/// that ignores the safe area.
private struct CaptureLayout {
    let full: CGSize
    let insets: EdgeInsets

    /// Visible height of the resting dashboard panel above the tab bar.
    static let peekHeight: CGFloat = 104
    /// Room for the mode picker between the viewfinder and the peek.
    static let controlBandHeight: CGFloat = 60
    static let topBarHeight: CGFloat = 44

    init(size: CGSize, insets: EdgeInsets) {
        self.insets = insets
        full = CGSize(
            width: size.width + insets.leading + insets.trailing,
            height: size.height + insets.top + insets.bottom
        )
    }

    /// Panel top while only the peek shows.
    var collapsedTop: CGFloat {
        full.height - insets.bottom - Self.peekHeight
    }

    /// Meal mode's viewfinder: the largest 3:4 frame below the status bar that
    /// still leaves room for the mode picker and the peek. Narrower than the
    /// screen on short phones rather than cropping what the photo captures.
    var viewfinder: CGRect {
        let top = insets.top
        let maxHeight = max(0, collapsedTop - Self.controlBandHeight - top)
        let height = min(full.width * 4 / 3, maxHeight)
        let width = height * 3 / 4
        return CGRect(x: (full.width - width) / 2, y: top, width: width, height: height)
    }

    var modePickerCenter: CGPoint {
        CGPoint(x: full.width / 2, y: (viewfinder.maxY + collapsedTop) / 2)
    }
}

// MARK: - History destination

struct NutritionHistoryView: View {
    @Environment(AppServices.self) private var services
    @Query(sort: \NutritionEntry.date, order: .reverse) private var entries: [NutritionEntry]

    /// Entries grouped by calendar day, newest day first.
    private var days: [(day: Date, entries: [NutritionEntry])] {
        let calendar = Calendar.current
        return Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
            .map { (day: $0.key, entries: $0.value) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        List {
            ForEach(days, id: \.day) { day in
                Section {
                    ForEach(day.entries) { entry in
                        NutritionHistoryRow(entry: entry)
                    }
                    .onDelete { offsets in
                        let doomed = offsets.map { day.entries[$0] }
                        Task {
                            for entry in doomed {
                                await services.deleteNutritionEntry(entry)
                            }
                        }
                    }
                } header: {
                    NutritionHistoryDayHeader(day: day.day, entries: day.entries)
                }
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No entries yet",
                    systemImage: "fork.knife",
                    description: Text("Snap a meal from the Nutrition tab to log it.")
                )
            }
        }
        .navigationTitle("Nutrition history")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct NutritionHistoryDayHeader: View {
    let day: Date
    let entries: [NutritionEntry]

    private var totals: NutrientAmounts {
        entries.reduce(into: NutrientAmounts()) { $0.add($1) }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Text(summary)
                .font(.footnote)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private var summary: String {
        let totals = totals
        var parts = ["\(Int(totals.energyKcal.rounded()).formatted()) kcal"]
        if totals.protein > 0 {
            parts.append("P \(Int(totals.protein.rounded()))")
        }
        if totals.fiber > 0 {
            parts.append("Fibre \(Int(totals.fiber.rounded()))")
        }
        return parts.joined(separator: " · ")
    }
}

private struct NutritionHistoryRow: View {
    let entry: NutritionEntry

    var body: some View {
        NavigationLink {
            NutritionEntryDetailView(entry: entry)
        } label: {
            HStack(spacing: 12) {
                MealThumbnailView(fileName: entry.imageFileName, fallback: entry.source.systemImage)
                // The time sits under the title instead of in a trailing
                // column, so meal names get the full row width.
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(entry.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var detail: String {
        if let fp = entry.fingerprint {
            var parts: [String] = []
            if let kcal = entry.caloriesKcal {
                parts.append("\(Int(kcal.rounded())) kcal")
            }
            let maxCategories = parts.isEmpty ? 3 : 2
            let topCategories = fp.items
                .sorted { $0.plateFraction > $1.plateFraction }
                .prefix(maxCategories)
                .map(\.category.displayLabel)
            if !topCategories.isEmpty {
                parts.append(contentsOf: topCategories)
            } else if !fp.plantIngredients.isEmpty {
                parts.append(contentsOf: fp.plantIngredients.prefix(maxCategories).map { $0 })
            }
            return parts.isEmpty ? entry.source.displayLabel : parts.joined(separator: " · ")
        }
        var parts: [String] = []
        if let kcal = entry.caloriesKcal   { parts.append("\(Int(kcal.rounded())) kcal") }
        if let p = entry.portionGrams       { parts.append("\(Int(p.rounded())) g") }
        if let p = entry.proteinGrams       { parts.append("P \(Int(p.rounded()))") }
        if let f = entry.fiberGrams         { parts.append("F \(Int(f.rounded()))") }
        return parts.joined(separator: " · ")
    }
}

/// 44pt square thumbnail for meal history. Falls back to a system glyph when the
/// entry has no on-disk image (legacy entries, or barcode entries logged before
/// image persistence shipped).
struct MealThumbnailView: View {
    let fileName: String?
    let fallback: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: fallback)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .background(Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: fileName) {
            image = MealImageStore.image(for: fileName)
        }
    }
}
