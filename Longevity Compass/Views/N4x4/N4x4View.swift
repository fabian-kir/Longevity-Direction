import IntervalEngine
import IntervalUI
import SwiftData
import SwiftUI

/// Phone screen for a live guided session (spec §6.1): a center timer inside a
/// current-phase progress ring, phase label, HR + guidance cue, and the
/// Skip / Pause / End controls. The idle screen opens on the Norwegian 4×4 as
/// before; Hold HR is one switch away and the heart check is a monthly card.
struct N4x4View: View {
    @Environment(AppServices.self) private var services
    @Query(sort: \N4x4WorkoutLog.startedAt, order: .reverse) private var workoutLogs: [N4x4WorkoutLog]
    @State private var presentedSheet: PresentedSheet?

    private enum PresentedSheet: Identifiable {
        case setup
        case heartCheck
        case settings
        case details(N4x4WorkoutLog)

        var id: String {
            switch self {
            case .setup: return "setup"
            case .heartCheck: return "heart-check"
            case .settings: return "settings"
            case .details(let log): return "details-\(log.sessionID.uuidString)"
            }
        }
    }

    private var model: N4x4SessionModel { services.n4x4 }

    var body: some View {
        @Bindable var model = services.n4x4
        Group {
            if model.isRunning || model.isMirroring {
                activeSession(model)
            } else if let output = model.output, output.isFinished {
                completion(output)
            } else {
                idle
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("N4x4")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    N4x4WorkoutHistoryView()
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel("Workout history")
            }
            if !(model.isRunning || model.isMirroring) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        presentedSheet = .settings
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Workout settings")
                }
            }
        }
        .preferredColorScheme(model.isRunning || model.isMirroring ? .dark : nil)
        .onAppear {
            model.onAppear(dateOfBirth: services.healthSnapshot.dateOfBirth)
        }
        .alert(model.timerOnlyWarningTitle, isPresented: $model.showTimerOnlyWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.timerOnlyWarningMessage)
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .setup:
                N4x4SetupSheet(mode: model.selectedMode, details: $model.workoutDetails, settings: $model.settings, hrMax: model.effectiveMaxHeartRate) {
                    start(model.selectedMode)
                }
            case .heartCheck:
                HeartCheckStartSheet(settings: $model.settings, details: $model.workoutDetails) {
                    start(.heartCheck)
                }
            case .settings:
                WorkoutSettingsView()
            case .details(let log):
                N4x4WorkoutDetailsSheet(log: log)
            }
        }
    }

    private func start(_ mode: WorkoutMode) {
        Task { await model.start(mode: mode, dateOfBirth: services.healthSnapshot.dateOfBirth) }
    }

    // MARK: - Idle / start

    /// Swiping left/right pages between the two everyday routines and does
    /// nothing else; each page scrolls vertically only.
    private var idle: some View {
        @Bindable var model = services.n4x4
        return ZStack {
            N4x4AmbientBackdrop(tint: modeTint(model.selectedMode))
                .animation(.easeInOut(duration: 0.3), value: model.selectedMode)

            VStack(spacing: 0) {
                N4x4ModeSwitcher(selection: $model.selectedMode, tint: modeTint(model.selectedMode))
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                TabView(selection: $model.selectedMode) {
                    idlePage(.n4x4)
                        .tag(WorkoutMode.n4x4)
                    idlePage(.steadyHeartRate)
                        .tag(WorkoutMode.steadyHeartRate)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .sensoryFeedback(.selection, trigger: model.selectedMode)
    }

    private func idlePage(_ mode: WorkoutMode) -> some View {
        let tint = modeTint(mode)
        return ScrollView {
            VStack(spacing: 0) {
                modeIcon(mode, tint: tint)
                    .padding(24)
                    .glassEffect(.regular.tint(tint.opacity(0.12)), in: Circle())
                    .padding(.top, 16)

                VStack(spacing: 8) {
                    Text(mode.title)
                        .font(.largeTitle.bold())
                        .tracking(-0.7)
                        .multilineTextAlignment(.center)
                    Text(modeSubtitle(mode))
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 310)
                }
                .padding(.top, 24)

                Group {
                    if mode == .steadyHeartRate {
                        steadyOverview
                    } else {
                        protocolOverview
                    }
                }
                .padding(.top, 30)

                maxHeartRateLabel
                    .padding(.top, 16)

                HeartCheckCard(logs: workoutLogs) {
                    presentedSheet = .heartCheck
                }
                .padding(.top, 26)

                if let latest = workoutLogs.first {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Latest workout", systemImage: "chart.xyaxis.line")
                                .font(.headline)
                            Spacer()
                            NavigationLink("All") { N4x4WorkoutHistoryView() }
                                .font(.subheadline.weight(.semibold))
                        }
                        NavigationLink {
                            N4x4WorkoutDetailView(log: latest)
                        } label: {
                            N4x4WorkoutRow(log: latest)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 26)
                }

                Button {
                    presentedSheet = .setup
                } label: {
                    Label("Start workout", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.glassProminent)
                .tint(tint)
                .padding(.top, 28)
            }
            .padding(24)
            // Pin the content to the page width: nothing inside can widen the
            // scroll content and make the page drag sideways.
            .containerRelativeFrame(.horizontal)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private func modeIcon(_ mode: WorkoutMode, tint: Color) -> some View {
        if mode == .steadyHeartRate {
            Image(systemName: "heart.circle")
                .font(.system(size: 54, weight: .medium))
                .frame(width: 54, height: 64)
                .foregroundStyle(tint)
        } else {
            MjolnirIcon()
                .frame(width: 54, height: 64)
                .foregroundStyle(tint)
        }
    }

    private func modeTint(_ mode: WorkoutMode) -> Color {
        mode == .steadyHeartRate ? N4x4Palette.recovery : AppTab.n4x4.tint
    }

    private func modeSubtitle(_ mode: WorkoutMode) -> String {
        switch mode {
        case .n4x4:
            return "A focused \(model.settings.n4x4.totalMinutes)-minute interval session with live heart-rate guidance."
        case .steadyHeartRate:
            return "Hold one heart rate for a set time. Your Watch taps you when you drift too high or too low."
        case .heartCheck:
            return "A monthly check of your heart's fitness and recovery."
        }
    }

    private var protocolOverview: some View {
        let n4x4 = model.settings.n4x4
        let hrMax = model.effectiveMaxHeartRate
        return HStack(spacing: 0) {
            protocolStep("\(n4x4.warmUpMinutes) MIN", "WARM UP", detail: nil, color: N4x4Palette.warmUp)
            protocolDivider
            protocolStep(
                "\(n4x4.rounds)×\(n4x4.intervalMinutes)",
                "HARD",
                detail: bpmRange(n4x4.highFraction, hrMax: hrMax),
                color: N4x4Palette.effort
            )
            protocolDivider
            protocolStep(
                "\(n4x4.recoveryMinutes) MIN",
                "RECOVER",
                detail: bpmRange(n4x4.recoveryFraction, hrMax: hrMax),
                color: N4x4Palette.recovery
            )
        }
        .padding(.vertical, 15)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.34), lineWidth: 0.75)
        }
    }

    private var steadyOverview: some View {
        let steady = model.settings.steady
        let target = steady.resolvedTarget(hrMax: model.effectiveMaxHeartRate)
        return HStack(spacing: 0) {
            protocolStep("\(steady.warmUpMinutes) MIN", "WARM UP", detail: nil, color: N4x4Palette.warmUp)
            protocolDivider
            protocolStep("\(target)", "BPM", detail: "±\(steady.toleranceBPM)", color: N4x4Palette.recovery)
            protocolDivider
            protocolStep("\(steady.durationMinutes) MIN", "HOLD", detail: nil, color: N4x4Palette.recovery)
        }
        .padding(.vertical, 15)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.34), lineWidth: 0.75)
        }
    }

    private func bpmRange(_ fraction: ClosedRange<Double>, hrMax: Double?) -> String? {
        guard let hrMax else { return nil }
        return "\(Int((fraction.lowerBound * hrMax).rounded()))–\(Int((fraction.upperBound * hrMax).rounded())) bpm"
    }

    private func protocolStep(_ value: String, _ label: String, detail: String?, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2.weight(.semibold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var protocolDivider: some View {
        Divider()
            .frame(height: 32)
    }

    @ViewBuilder
    private var maxHeartRateLabel: some View {
        Button {
            presentedSheet = .settings
        } label: {
            if let hrMax = model.effectiveMaxHeartRate {
                let source = model.settings.customMaxHeartRate == nil ? "estimated" : "your setting"
                Label("Max HR \(Int(hrMax.rounded())) bpm · \(source)", systemImage: "heart.fill")
            } else {
                Label("Set your max heart rate", systemImage: "heart")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
    }

    // MARK: - Active

    private func activeSession(_ model: N4x4SessionModel) -> some View {
        let output = model.output
        return PhaseFlowView(
            progress: output?.phaseProgress ?? 0,
            color: output?.ringColor.swiftUIColor ?? N4x4Palette.warmUp,
            nextColor: output?.nextRingColor?.swiftUIColor,
            backgroundColor: Color(uiColor: .systemBackground),
            minimumCoreRadius: 64,
            shadowRadius: 30
        ) {
            VStack(spacing: 22) {
                Spacer(minLength: 52)

                VStack(spacing: 8) {
                    Label(output?.phaseLabel ?? "Getting ready", systemImage: phaseSymbol(output))
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .glassEffect(.clear, in: Capsule())

                    Text(Self.clock(output?.timeRemainingInPhase ?? 0))
                        .font(.system(size: 74, weight: .semibold, design: .rounded))
                        .tracking(-2)
                        .monospacedDigit()
                        .contentTransition(.numericText())

                    Text(output?.isPaused == true ? "PAUSED" : "PHASE REMAINING")
                        .font(.caption2.weight(.bold))
                        .tracking(1.25)
                        .foregroundStyle(.white.opacity(0.72))
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.28), radius: 10, y: 4)

                metricsPanel(output)

                Spacer(minLength: 18)

                controls(model, output: output)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .padding(.bottom, 88)
        }
    }

    private func metricsPanel(_ output: EngineOutput?) -> some View {
        VStack(spacing: 14) {
            guidanceRow(output)

            Divider()
                .overlay(.white.opacity(0.25))

            HStack(spacing: 12) {
                targetHint(output)
                Spacer(minLength: 8)
                totalRemainingLabel(output)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 12) {
                    Label("BPM", systemImage: "waveform.path.ecg")
                        .foregroundStyle(.pink)
                    if model.program?.mode != .heartCheck {
                        Label("Target", systemImage: "line.diagonal")
                            .foregroundStyle(.yellow)
                    }
                    Spacer()
                    Text("LAST 7 MIN")
                        .foregroundStyle(.white.opacity(0.6))
                }
                .font(.caption2.weight(.bold))

                N4x4HeartRateChart(frames: model.liveFrames, liveWindow: 7 * 60)
                    .frame(height: 116)
                    .overlay {
                        if !model.liveFrames.contains(where: { $0.bpm != nil }) {
                            Text("Waiting for heart-rate data")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
            }

            if model.isMirroring {
                Label("Heart rate from Apple Watch", systemImage: "applewatch.radiowaves.left.and.right")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
        // Clear Liquid Glass: the phase colour flows through and refracts at
        // the edges instead of sitting behind a dark frosted slab.
        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func phaseSymbol(_ output: EngineOutput?) -> String {
        guard let output else { return "timer" }
        switch output.phase {
        case .warmUp: return "flame"
        case .highIntensity: return "bolt.fill"
        case .activeRecovery: return "wind"
        case .cooldown: return "snowflake"
        case .steady: return "heart.fill"
        case .fixedWorkload: return "speedometer"
        case .stillness: return "figure.stand"
        }
    }

    @ViewBuilder
    private func guidanceRow(_ output: EngineOutput?) -> some View {
        HStack(spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "heart.fill")
                    .font(.subheadline)
                    .foregroundStyle(.pink)
                Text(hrText(output))
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .monospacedDigit()
                Text("BPM")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer(minLength: 4)

            cue(output)
        }
        .frame(minHeight: 42)
    }

    @ViewBuilder
    private func cue(_ output: EngineOutput?) -> some View {
        switch output?.deadBandState ?? .noTarget {
        case .below:
            guidanceLabel("Go harder", symbol: "arrow.up", tint: N4x4Palette.effort)
        case .above:
            guidanceLabel("Ease off", symbol: "arrow.down", tint: N4x4Palette.warmUp)
        case .inRange:
            guidanceLabel("In range", symbol: "checkmark", tint: N4x4Palette.recovery)
        case .noTarget:
            targetlessCue(output)
        }
    }

    private func guidanceLabel(_ title: String, symbol: String, tint: Color) -> some View {
        // One palette style only: an inner `.foregroundStyle(.white)` would win
        // and draw the symbol as a plain white dot.
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .symbolVariant(.circle.fill)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, tint)
    }

    @ViewBuilder
    private func targetlessCue(_ output: EngineOutput?) -> some View {
        Group {
            if output?.trailingHR == nil {
                Label("Timer only", systemImage: "timer")
            } else {
                switch output?.phase {
                case .fixedWorkload?: Label("Keep it steady", systemImage: "speedometer")
                case .stillness?: Label("Measuring", systemImage: "waveform.path.ecg")
                case .cooldown?: Label("Cooling down", systemImage: "waveform.path.ecg")
                default: Label("Warming up", systemImage: "waveform.path.ecg")
                }
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white.opacity(0.85))
    }

    @ViewBuilder
    private func targetHint(_ output: EngineOutput?) -> some View {
        if let t = output?.target {
            let lo = Int(t.lowerBound.rounded()), hi = Int(t.upperBound.rounded())
            let text: String = if model.program?.mode == .steadyHeartRate, let band = model.program?.deadBand {
                "Target \(lo) ±\(Int(band))"
            } else {
                lo == hi ? "Target \(lo)" : "Target \(lo)–\(hi)"
            }
            Label(text, systemImage: "scope")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .monospacedDigit()
        } else {
            Label("No HR target", systemImage: "scope")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    @ViewBuilder
    private func totalRemainingLabel(_ output: EngineOutput?) -> some View {
        if let output {
            Label(Self.clock(output.totalRemaining), systemImage: "hourglass")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .monospacedDigit()
        }
    }

    private func controls(_ model: N4x4SessionModel, output: EngineOutput?) -> some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 12) {
                if model.canSkip {
                    Button { model.skip() } label: {
                        controlLabel("Skip", "forward.end.fill")
                    }
                    .buttonStyle(.glass)
                    .tint(.white)
                }

                Button { model.pauseResume() } label: {
                    let paused = output?.isPaused ?? false
                    controlLabel(paused ? "Resume" : "Pause", paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.glassProminent)
                .tint(output?.isPaused == true ? N4x4Palette.recovery : AppTab.n4x4.tint)

                if model.endCompletesSession {
                    Button { model.end() } label: {
                        controlLabel("Finish", "checkmark")
                    }
                    .buttonStyle(.glass)
                    .tint(N4x4Palette.recovery)
                } else {
                    Button(role: .destructive) { model.end() } label: {
                        controlLabel("End", "stop.fill")
                    }
                    .buttonStyle(.glass)
                    .tint(.red)
                }
            }
        }
    }

    private func controlLabel(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.headline)
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity, minHeight: 48)
    }

    // MARK: - Completion

    private func completion(_ output: EngineOutput) -> some View {
        let mode = model.program?.mode ?? .n4x4
        return ZStack {
            N4x4AmbientBackdrop(tint: N4x4Palette.recovery)

            GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 88, height: 88)
                        .glassEffect(.regular.tint(N4x4Palette.recovery.opacity(0.38)), in: Circle())

                    Text(mode == .heartCheck ? "Heart check done" : "Session complete")
                        .font(.largeTitle.bold())
                        .tracking(-0.7)
                    Text("\(Self.clock(output.elapsed)) total")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    if let log = completedLog {
                        completionMetrics(log)
                            .padding(.top, 8)

                        if log.mode == .heartCheck {
                            HeartCheckComparison(log: log, logs: workoutLogs)
                        }

                        EffortPicker(score: log.effortScore) { score in
                            Task { await model.healthLinker.setEffort(score, for: log) }
                        }
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                        Button {
                            presentedSheet = .details(log)
                        } label: {
                            Label(detailsButtonTitle(log.equipment), systemImage: "square.and.pencil")
                        }
                        .buttonStyle(.glass)

                        NavigationLink {
                            N4x4WorkoutDetailView(log: log)
                        } label: {
                            Label("View workout analysis", systemImage: "chart.xyaxis.line")
                        }
                        .font(.headline)
                    }

                    Button {
                        start(mode)
                    } label: {
                        Label("Start again", systemImage: "arrow.clockwise")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(N4x4Palette.recovery)
                    .padding(.top, 12)

                    Button("Done") { model.dismissCompletion() }
                        .font(.headline)
                }
                .padding(24)
                .containerRelativeFrame(.horizontal)
                // Centered when it fits; scrolls vertically when it doesn't.
                .frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    @ViewBuilder
    private func completionMetrics(_ log: N4x4WorkoutLog) -> some View {
        HStack(spacing: 18) {
            switch log.mode {
            case .n4x4:
                completionMetric("AVG", bpm(log.averageHeartRate), "BPM")
                completionMetric("IN TARGET", percent(log.targetAdherence), "")
                completionMetric("RECOVERY", bpm(log.averageOneMinuteRecovery), "BPM / 1M")
            case .steadyHeartRate:
                completionMetric("AVG", bpm(log.averageHeartRate), "BPM")
                completionMetric("IN RANGE", percent(log.targetAdherence), "")
                completionMetric("PEAK", bpm(log.peakHeartRate), "BPM")
            case .heartCheck:
                completionMetric("AT WORKLOAD", bpm(log.workloadHeartRate), "BPM")
                completionMetric("DROP 1 MIN", bpm(log.recoveryDropAfter60), "BPM")
                completionMetric("DROP 2 MIN", bpm(log.recoveryDropAfter120), "BPM")
            }
        }
    }

    // MARK: - Helpers

    private func detailsButtonTitle(_ equipment: N4x4Equipment) -> String {
        if equipment.acceptsIncline { return "Correct distance or incline" }
        if equipment.acceptsDistanceCorrection { return "Correct distance" }
        return "Add notes"
    }

    private var completedLog: N4x4WorkoutLog? {
        guard let id = model.lastCompletedLogID else { return nil }
        return workoutLogs.first { $0.sessionID == id }
    }

    private func bpm(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))" } ?? "—"
    }

    private func percent(_ value: Double?) -> String {
        value.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—"
    }

    private func completionMetric(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold().monospacedDigit())
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func hrText(_ output: EngineOutput?) -> String {
        // Render the authoritative trailing value from EngineOutput on both
        // devices. Using a primary-only raw sample here made the two screens
        // disagree even when synchronization itself was healthy.
        if let hr = output?.trailingHR {
            return String(Int(hr.rounded()))
        }
        return "—"
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct N4x4AmbientBackdrop: View {
    let tint: Color

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            RadialGradient(
                colors: [tint.opacity(0.22), tint.opacity(0.05), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 420
            )
            RadialGradient(
                colors: [tint.opacity(0.12), .clear],
                center: .bottomLeading,
                startRadius: 10,
                endRadius: 330
            )
        }
        .ignoresSafeArea()
    }
}

/// Two-option switch above the mode pager. Unlike a segmented control it
/// shrinks its labels instead of forcing the page wider than the screen.
private struct N4x4ModeSwitcher: View {
    @Binding var selection: WorkoutMode
    let tint: Color
    @Namespace private var highlight

    private let options: [(mode: WorkoutMode, title: String)] = [
        (.n4x4, "4×4 intervals"),
        (.steadyHeartRate, "Hold heart rate"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.mode) { option in
                let isSelected = selection == option.mode
                Button {
                    withAnimation(.snappy) { selection = option.mode }
                } label: {
                    Text(option.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(tint.opacity(0.18))
                                    .matchedGeometryEffect(id: "highlight", in: highlight)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .glassEffect(.regular, in: Capsule())
    }
}
