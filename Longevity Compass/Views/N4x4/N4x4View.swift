import IntervalEngine
import IntervalUI
import SwiftData
import SwiftUI

/// Phone screen for a live Norwegian 4x4 session (spec §6.1): a center timer
/// inside a current-phase progress ring, phase label, HR + guidance cue, and
/// the Skip / Pause / End controls.
struct N4x4View: View {
    @Environment(AppServices.self) private var services
    @Query(sort: \N4x4WorkoutLog.startedAt, order: .reverse) private var workoutLogs: [N4x4WorkoutLog]
    @State private var presentedSheet: PresentedSheet?

    private enum PresentedSheet: Identifiable {
        case setup
        case machineResults(N4x4WorkoutLog)

        var id: String {
            switch self {
            case .setup: return "setup"
            case .machineResults(let log): return "machine-\(log.sessionID.uuidString)"
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
                .accessibilityLabel("N4x4 workout history")
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
                N4x4SetupSheet(details: $model.workoutDetails) {
                    Task { await model.start(dateOfBirth: services.healthSnapshot.dateOfBirth) }
                }
            case .machineResults(let log):
                N4x4MachineResultsSheet(log: log)
            }
        }
    }

    // MARK: - Idle / start

    private var idle: some View {
        ZStack {
            N4x4AmbientBackdrop(tint: AppTab.n4x4.tint)

            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 32)

                    MjolnirIcon()
                        .frame(width: 54, height: 64)
                        .foregroundStyle(AppTab.n4x4.tint)
                        .padding(24)
                        .glassEffect(.regular.tint(AppTab.n4x4.tint.opacity(0.12)), in: Circle())

                    VStack(spacing: 8) {
                        Text("Norwegian 4×4")
                            .font(.largeTitle.bold())
                            .tracking(-0.7)
                        Text("A focused 31-minute interval session with live heart-rate guidance.")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 310)
                    }
                    .padding(.top, 24)

                    protocolOverview
                        .padding(.top, 30)

                    estimatedMaxLabel
                        .padding(.top, 16)

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
                    .tint(AppTab.n4x4.tint)
                    .padding(.top, 28)
                }
                .padding(24)
            }
        }
    }

    private var protocolOverview: some View {
        HStack(spacing: 0) {
            protocolStep("3 MIN", "WARM UP", color: N4x4Palette.warmUp)
            protocolDivider
            protocolStep("4×4", "HARD", color: N4x4Palette.effort)
            protocolDivider
            protocolStep("3 MIN", "RECOVER", color: N4x4Palette.recovery)
        }
        .padding(.vertical, 15)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.34), lineWidth: 0.75)
        }
    }

    private func protocolStep(_ value: String, _ label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2.weight(.semibold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var protocolDivider: some View {
        Divider()
            .frame(height: 32)
    }

    @ViewBuilder
    private var estimatedMaxLabel: some View {
        if let hrMax = model.hrMax {
            Label("Estimated HRmax \(Int(hrMax.rounded())) bpm", systemImage: "heart.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Active

    private func activeSession(_ model: N4x4SessionModel) -> some View {
        let output = model.output
        return PhaseFlowView(
            progress: output?.phaseProgress ?? 0,
            color: output?.ringColor.swiftUIColor ?? N4x4Palette.warmUp,
            nextColor: output?.phase.nextRingColor?.swiftUIColor,
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
                .overlay(.white.opacity(0.18))

            HStack(spacing: 12) {
                targetHint(output)
                Spacer(minLength: 8)
                totalRemainingLabel(output)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 12) {
                    Label("BPM", systemImage: "waveform.path.ecg")
                        .foregroundStyle(.pink)
                    Label("Target slope", systemImage: "line.diagonal")
                        .foregroundStyle(.yellow)
                    Spacer()
                    Text("LAST 7 MIN")
                        .foregroundStyle(.white.opacity(0.55))
                }
                .font(.caption2.weight(.bold))

                N4x4HeartRateChart(frames: model.liveFrames, liveWindow: 7 * 60)
                    .frame(height: 116)
                    .overlay {
                        if !model.liveFrames.contains(where: { $0.bpm != nil }) {
                            Text("Waiting for heart-rate data")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.62))
                        }
                    }
            }

            if model.isMirroring {
                Label("Heart rate from Apple Watch", systemImage: "applewatch.radiowaves.left.and.right")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.82))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .foregroundStyle(.white)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.20), lineWidth: 0.75)
        }
    }

    private func phaseSymbol(_ output: EngineOutput?) -> String {
        guard let output else { return "timer" }
        switch output.phase {
        case .warmUp: return "flame"
        case .highIntensity: return "bolt.fill"
        case .activeRecovery: return "wind"
        case .cooldown: return "snowflake"
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
                    .foregroundStyle(.white.opacity(0.65))
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
        if output?.trailingHR == nil {
            Label("Timer only", systemImage: "timer")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))
        } else {
            Label("Warming up", systemImage: "waveform.path.ecg")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))
        }
    }

    @ViewBuilder
    private func targetHint(_ output: EngineOutput?) -> some View {
        if let t = output?.target {
            let lo = Int(t.lowerBound.rounded()), hi = Int(t.upperBound.rounded())
            Label(lo == hi ? "Target \(lo)" : "Target \(lo)–\(hi)", systemImage: "scope")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.78))
                .monospacedDigit()
        } else {
            Label("No HR target", systemImage: "scope")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.58))
        }
    }

    @ViewBuilder
    private func totalRemainingLabel(_ output: EngineOutput?) -> some View {
        if let output {
            Label(Self.clock(output.totalRemaining), systemImage: "hourglass")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.78))
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

                Button(role: .destructive) { model.end() } label: {
                    controlLabel("End", "stop.fill")
                }
                .buttonStyle(.glass)
                .tint(.red)
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
        ZStack {
            N4x4AmbientBackdrop(tint: N4x4Palette.recovery)

            VStack(spacing: 18) {
                Spacer()

                Image(systemName: "checkmark")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 88, height: 88)
                    .glassEffect(.regular.tint(N4x4Palette.recovery.opacity(0.38)), in: Circle())

                Text("Session complete")
                    .font(.largeTitle.bold())
                    .tracking(-0.7)
                Text("\(Self.clock(output.elapsed)) total")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                if let log = completedLog {
                    HStack(spacing: 18) {
                        completionMetric("AVG", log.averageHeartRate.map { "\(Int($0.rounded()))" } ?? "—", "BPM")
                        completionMetric("IN TARGET", log.targetAdherence.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—", "")
                        completionMetric("RECOVERY", log.averageOneMinuteRecovery.map { "\(Int($0.rounded()))" } ?? "—", "BPM / 1M")
                    }
                    .padding(.top, 8)

                    Button {
                        presentedSheet = .machineResults(log)
                    } label: {
                        Label("Add machine results", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.glass)

                    NavigationLink {
                        N4x4WorkoutDetailView(log: log)
                    } label: {
                        Label("View workout analysis", systemImage: "chart.xyaxis.line")
                    }
                    .font(.headline)
                }

                Spacer()

                Button {
                    Task { await model.start(dateOfBirth: services.healthSnapshot.dateOfBirth) }
                } label: {
                    Label("Start again", systemImage: "arrow.clockwise")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.glassProminent)
                .tint(N4x4Palette.recovery)
            }
            .padding(24)
        }
    }

    // MARK: - Helpers

    private var completedLog: N4x4WorkoutLog? {
        guard let id = model.lastCompletedLogID else { return nil }
        return workoutLogs.first { $0.sessionID == id }
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

private struct N4x4AmbientBackdrop: View {
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
