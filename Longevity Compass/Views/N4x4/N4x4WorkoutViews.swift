import Charts
import IntervalUI
import SwiftData
import SwiftUI

struct N4x4HeartRateChart: View {
    let frames: [N4x4WorkoutFrame]
    var liveWindow: TimeInterval?

    /// Frames normally arrive about once per second. A longer jump in elapsed
    /// time means no samples exist for that span (a skipped phase, a stalled or
    /// relaunched app), so the line must break instead of interpolating.
    private static let maxFrameGap: TimeInterval = 5

    private var visibleFrames: [N4x4WorkoutFrame] {
        let ordered = frames.sorted { $0.elapsed < $1.elapsed }
        guard let liveWindow, let end = ordered.last?.elapsed else { return ordered }
        return ordered.filter { $0.elapsed >= max(0, end - liveWindow) }
    }

    struct PlotPoint: Identifiable {
        let frame: N4x4WorkoutFrame
        let heartRateSegment: Int
        let targetSegment: Int
        var id: Date { frame.id }
    }

    /// Assigns each frame to a continuous run. Charts connects every point of
    /// one series, so a gap or a missing value starts a new series.
    static func plotPoints(for frames: [N4x4WorkoutFrame]) -> [PlotPoint] {
        var points: [PlotPoint] = []
        var heartRateSegment = 0
        var targetSegment = 0
        var previous: N4x4WorkoutFrame?
        for frame in frames {
            if let previous {
                let gap = frame.elapsed - previous.elapsed > maxFrameGap
                if gap || previous.bpm == nil { heartRateSegment += 1 }
                if gap || previous.targetMidpoint == nil { targetSegment += 1 }
            }
            points.append(PlotPoint(
                frame: frame,
                heartRateSegment: heartRateSegment,
                targetSegment: targetSegment
            ))
            previous = frame
        }
        return points
    }

    /// Ticks on round times (the smallest step that keeps at most six labels),
    /// so a label always names the exact time under it.
    static func ticks(for domain: ClosedRange<Double>) -> [Double] {
        let span = domain.upperBound - domain.lowerBound
        let step = [30.0, 60, 120, 300, 600].first { span / $0 <= 6 } ?? 900
        let first = (domain.lowerBound / step).rounded(.up) * step
        return Array(stride(from: first, through: domain.upperBound, by: step))
    }

    static func tickLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total % 60 == 0 { return "\(total / 60)m" }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var xDomain: ClosedRange<Double> {
        let start = visibleFrames.first?.elapsed ?? 0
        let end = max(visibleFrames.last?.elapsed ?? 60, start + 60)
        return start...end
    }

    private var yDomain: ClosedRange<Double> {
        let values = visibleFrames.flatMap { frame in
            [frame.bpm, frame.targetLower, frame.targetUpper].compactMap { $0 }
        }
        guard let low = values.min(), let high = values.max() else { return 70...200 }
        return max(40, low - 12)...min(230, max(high + 12, low + 40))
    }

    var body: some View {
        Chart {
            ForEach(Self.plotPoints(for: visibleFrames)) { point in
                let frame = point.frame
                if let low = frame.targetLower, let high = frame.targetUpper {
                    AreaMark(
                        x: .value("Elapsed", frame.elapsed),
                        yStart: .value("Target lower", low),
                        yEnd: .value("Target upper", high),
                        series: .value("Series", "Target band \(point.targetSegment)")
                    )
                    .foregroundStyle(.yellow.opacity(0.13))

                    if let target = frame.targetMidpoint {
                        LineMark(
                            x: .value("Elapsed", frame.elapsed),
                            y: .value("Algorithm target", target),
                            series: .value("Series", "Target \(point.targetSegment)")
                        )
                        .foregroundStyle(.yellow)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    }
                }

                if let bpm = frame.bpm {
                    LineMark(
                        x: .value("Elapsed", frame.elapsed),
                        y: .value("Heart rate", bpm),
                        series: .value("Series", "Heart rate \(point.heartRateSegment)")
                    )
                    .foregroundStyle(.pink)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: Self.ticks(for: xDomain)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel {
                    if let seconds = value.as(Double.self) {
                        Text(Self.tickLabel(seconds))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel()
            }
        }
        .accessibilityLabel("Heart rate compared with algorithm target")
    }
}

struct N4x4SetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var details: N4x4WorkoutDetails
    let start: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Performed on", selection: $details.equipment) {
                        ForEach(N4x4Equipment.allCases) { equipment in
                            Label(equipment.title, systemImage: equipment.systemImage)
                                .tag(equipment)
                        }
                    }
                } header: {
                    Text("Equipment")
                } footer: {
                    Text("You can add the machine's calorie, distance, and step estimates after the workout.")
                }

                Section {
                    Label("The workout is saved to Apple Health when the full protocol completes.", systemImage: "heart.text.clipboard")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Workout setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        dismiss()
                        start()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

struct N4x4MachineResultsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    let log: N4x4WorkoutLog
    @State private var equipment: N4x4Equipment
    @State private var calories: String
    @State private var distance: String
    @State private var steps: String
    @State private var notes: String

    init(log: N4x4WorkoutLog) {
        self.log = log
        _equipment = State(initialValue: log.equipment)
        _calories = State(initialValue: Self.text(log.machineCalories))
        _distance = State(initialValue: Self.text(log.machineDistanceKilometers))
        _steps = State(initialValue: log.machineSteps.map(String.init) ?? "")
        _notes = State(initialValue: log.notes)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Equipment") {
                    Picker("Performed on", selection: $equipment) {
                        ForEach(N4x4Equipment.allCases) { item in
                            Label(item.title, systemImage: item.systemImage).tag(item)
                        }
                    }
                }

                Section {
                    TextField("Calories (kcal)", text: $calories)
                        .keyboardType(.decimalPad)
                    TextField("Distance (km)", text: $distance)
                        .keyboardType(.decimalPad)
                    TextField("Steps", text: $steps)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Machine estimate")
                } footer: {
                    Text("These values stay labeled as machine estimates in Longevity Direction. Apple Health keeps the workout's own measured values.")
                }

                Section("Notes") {
                    TextField("How did it feel?", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .navigationTitle("Machine results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func save() {
        log.equipment = equipment
        log.machineCalories = Self.number(calories)
        log.machineDistanceKilometers = Self.number(distance)
        log.machineSteps = Int(steps)
        log.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        try? context.save()
        dismiss()
    }

    private static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    private static func text(_ value: Double?) -> String {
        value?.formatted(.number.precision(.fractionLength(0...2))) ?? ""
    }
}

struct N4x4WorkoutHistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \N4x4WorkoutLog.startedAt, order: .reverse) private var logs: [N4x4WorkoutLog]

    var body: some View {
        List {
            ForEach(logs) { log in
                NavigationLink {
                    N4x4WorkoutDetailView(log: log)
                } label: {
                    N4x4WorkoutRow(log: log)
                }
                .swipeActions {
                    Button("Delete", role: .destructive) {
                        context.delete(log)
                        try? context.save()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if logs.isEmpty {
                ContentUnavailableView(
                    "No N4x4 workouts yet",
                    systemImage: "waveform.path.ecg",
                    description: Text("Completed and stopped sessions will appear here.")
                )
            }
        }
        .navigationTitle("N4x4 history")
    }
}

struct N4x4WorkoutDetailView: View {
    let log: N4x4WorkoutLog
    @State private var editTarget: N4x4WorkoutLog?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(log.equipment.title, systemImage: log.equipment.systemImage)
                        .font(.title2.bold())
                    Text(log.startedAt.formatted(date: .complete, time: .shortened))
                        .foregroundStyle(.secondary)
                    Label(healthKitLabel, systemImage: healthKitSymbol)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(healthKitColor)
                }

                VStack(alignment: .leading, spacing: 10) {
                    chartLegend
                    N4x4HeartRateChart(frames: log.frames)
                        .frame(height: 280)
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    metric("Duration", clock(log.duration), "timer")
                    metric("Average HR", bpm(log.averageHeartRate), "heart")
                    metric("Peak HR", bpm(log.peakHeartRate), "heart.fill")
                    metric("In target", percent(log.targetAdherence), "scope")
                    metric("1-min rise", signedBPM(log.averageOneMinuteRise), "arrow.up.right")
                    metric("1-min recovery", signedBPM(log.averageOneMinuteRecovery), "arrow.down.right")
                }

                machineSummary

                if !log.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notes").font(.headline)
                        Text(log.notes).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(log.isCompleted ? "Workout analysis" : "Stopped session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { editTarget = log }
            }
        }
        .sheet(item: $editTarget) { target in
            N4x4MachineResultsSheet(log: target)
        }
    }

    private var chartLegend: some View {
        HStack(spacing: 14) {
            Label("BPM", systemImage: "waveform.path.ecg").foregroundStyle(.pink)
            Label("Algorithm target", systemImage: "line.diagonal").foregroundStyle(.yellow)
        }
        .font(.caption.weight(.semibold))
    }

    @ViewBuilder
    private var machineSummary: some View {
        if log.machineCalories != nil || log.machineDistanceKilometers != nil || log.machineSteps != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Machine estimate").font(.headline)
                HStack(spacing: 18) {
                    if let value = log.machineCalories {
                        Label("\(value.formatted(.number.precision(.fractionLength(0)))) kcal", systemImage: "flame")
                    }
                    if let value = log.machineDistanceKilometers {
                        Label("\(value.formatted(.number.precision(.fractionLength(0...2)))) km", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                    if let value = log.machineSteps {
                        Label(value.formatted(), systemImage: "shoeprints.fill")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func metric(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold().monospacedDigit())
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var healthKitLabel: String {
        switch log.healthKitSaveState {
        case .notRequested: return "Not written to Apple Health"
        case .requested: return "Apple Health save requested"
        case .saved: return "Saved to Apple Health"
        case .failed: return "Apple Health save failed"
        }
    }

    private var healthKitSymbol: String {
        log.healthKitSaveState == .saved ? "checkmark.circle.fill" : "heart.text.clipboard"
    }

    private var healthKitColor: Color {
        log.healthKitSaveState == .failed ? .red : .secondary
    }

    private func bpm(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded())) bpm" } ?? "—"
    }

    private func signedBPM(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(value >= 0 ? "+" : "")\(Int(value.rounded())) bpm"
    }

    private func percent(_ value: Double?) -> String {
        value.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—"
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct N4x4WorkoutRow: View {
    let log: N4x4WorkoutLog

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: log.equipment.systemImage)
                .font(.title3)
                .foregroundStyle(log.isCompleted ? N4x4Palette.recovery : .secondary)
                .frame(width: 42, height: 42)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(log.equipment.title)
                    .font(.headline)
                Text(log.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(summary)
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var summary: String {
        var parts = [Self.clock(log.duration)]
        if let average = log.averageHeartRate {
            parts.append("\(Int(average.rounded())) avg bpm")
        }
        if !log.isCompleted { parts.append("Stopped") }
        return parts.joined(separator: " · ")
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
