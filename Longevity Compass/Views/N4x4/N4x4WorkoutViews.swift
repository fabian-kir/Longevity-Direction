import Charts
import IntervalEngine
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
    let mode: WorkoutMode
    @Binding var details: N4x4WorkoutDetails
    @Binding var settings: WorkoutSettings
    let hrMax: Double?
    let start: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Performed on", selection: $details.equipment) {
                        ForEach(N4x4Equipment.pickerOrder) { equipment in
                            Label(equipment.title, systemImage: equipment.systemImage)
                                .tag(equipment)
                        }
                    }
                } header: {
                    Text("Equipment")
                } footer: {
                    Text(equipmentFooter)
                }

                if mode == .steadyHeartRate {
                    Section {
                        Stepper(value: targetBinding, in: 80...200, step: 1) {
                            LabeledContent("Target", value: "\(targetBinding.wrappedValue) bpm")
                        }
                        Stepper(value: $settings.steady.durationMinutes, in: 10...180, step: 5) {
                            LabeledContent("Duration", value: "\(settings.steady.durationMinutes) min")
                        }
                    } header: {
                        Text("Hold")
                    } footer: {
                        Text("Your Watch taps you once you're more than \(settings.steady.toleranceBPM) bpm off target. Finish any time after 5 minutes and the session is saved.")
                    }
                }

                Section {
                    Label("The workout is saved to Apple Health when it completes.", systemImage: "heart.text.clipboard")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(mode == .steadyHeartRate ? "Hold heart rate" : "Workout setup")
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

    /// Editing the target stores it, so the next session starts from it.
    private var targetBinding: Binding<Int> {
        Binding(
            get: { settings.steady.resolvedTarget(hrMax: hrMax) },
            set: { settings.steady.targetBPM = $0 }
        )
    }

    private var equipmentFooter: String {
        if details.equipment.recordsRoute {
            return "Recorded as an Apple Health \(details.equipment.title.lowercased()) with your GPS route."
        }
        if details.equipment.acceptsDistanceCorrection {
            return "Recorded as an Apple Health \(details.equipment.title.lowercased()). You can correct distance\(details.equipment.acceptsIncline ? " and incline" : "") afterwards."
        }
        return "Choosing the equipment lets Apple Health record the matching workout type."
    }
}

/// After-workout corrections for values the Watch can't measure on a machine,
/// plus the effort rating. Calories are deliberately left to Apple.
struct N4x4WorkoutDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppServices.self) private var services

    let log: N4x4WorkoutLog
    @State private var equipment: N4x4Equipment
    @State private var distance: String
    @State private var incline: String
    @State private var effort: Int?
    @State private var notes: String

    init(log: N4x4WorkoutLog) {
        self.log = log
        _equipment = State(initialValue: log.equipment)
        _distance = State(initialValue: Self.text(log.correctedDistanceKilometers))
        _incline = State(initialValue: Self.text(log.inclinePercent))
        _effort = State(initialValue: log.effortScore)
        _notes = State(initialValue: log.notes)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Equipment") {
                    Picker("Performed on", selection: $equipment) {
                        ForEach(N4x4Equipment.pickerOrder) { item in
                            Label(item.title, systemImage: item.systemImage).tag(item)
                        }
                    }
                }

                if equipment.acceptsDistanceCorrection || equipment.acceptsIncline {
                    Section {
                        if equipment.acceptsDistanceCorrection {
                            LabeledContent("Distance") {
                                TextField(distancePlaceholder, text: $distance)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                Text("km").foregroundStyle(.secondary)
                            }
                        }
                        if equipment.acceptsIncline {
                            LabeledContent("Incline") {
                                TextField("0", text: $incline)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                Text("%").foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("From the machine")
                    } footer: {
                        Text(correctionFooter)
                    }
                }

                Section {
                    EffortPicker(score: effort) { effort = $0 }
                } header: {
                    Text("Effort")
                } footer: {
                    Text("Saved to Apple Health as the workout's effort rating.")
                }

                Section("Notes") {
                    TextField("How did it feel?", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .navigationTitle("Workout details")
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

    private var distancePlaceholder: String {
        log.appleDistanceKilometers.map { Self.text($0) } ?? "0.0"
    }

    private var correctionFooter: String {
        var text = "Use the numbers on the machine's display. They replace the Watch's estimate in Longevity Direction; Apple Health keeps the Watch's own measurement."
        if equipment.acceptsIncline {
            text += " Incline also gives the elevation you climbed."
        }
        return text
    }

    private func save() {
        log.equipment = equipment
        log.correctedDistanceKilometers = equipment.acceptsDistanceCorrection ? Self.number(distance) : nil
        log.inclinePercent = equipment.acceptsIncline ? Self.number(incline) : nil
        log.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        try? context.save()
        if effort != log.effortScore {
            let linker = services.n4x4.healthLinker
            let score = effort
            Task { await linker.setEffort(score, for: log) }
        }
        dismiss()
    }

    private static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    private static func text(_ value: Double?) -> String {
        value?.formatted(.number.precision(.fractionLength(0...2))) ?? ""
    }
}

/// Apple's 1–10 workout effort scale with its four bands.
struct EffortPicker: View {
    let score: Int?
    let onChange: (Int?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("How hard was it?")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(score.map { "\($0) · \(Self.band(for: $0))" } ?? "Not rated")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 5) {
                ForEach(1...10, id: \.self) { value in
                    Button {
                        onChange(score == value ? nil : value)
                    } label: {
                        Text("\(value)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .foregroundStyle((score ?? 0) >= value ? .white : .primary)
                            .background(
                                (score ?? 0) >= value ? Self.color(for: value) : Color.secondary.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Effort \(value), \(Self.band(for: value))")
                }
            }
        }
    }

    static func band(for score: Int) -> String {
        switch score {
        case ...3: return "Easy"
        case 4...6: return "Moderate"
        case 7...8: return "Hard"
        default: return "All out"
        }
    }

    private static func color(for score: Int) -> Color {
        switch score {
        case ...3: return N4x4Palette.recovery
        case 4...6: return N4x4Palette.workload
        case 7...8: return N4x4Palette.effort
        default: return Color(red: 0.55, green: 0.12, blue: 0.20)
        }
    }
}

struct N4x4WorkoutHistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \N4x4WorkoutLog.startedAt, order: .reverse) private var logs: [N4x4WorkoutLog]

    var body: some View {
        List {
            if logs.contains(where: { $0.mode == .heartCheck && $0.isCompleted }) {
                Section {
                    NavigationLink {
                        HeartCheckTrendView()
                    } label: {
                        Label("Heart check trend", systemImage: "stethoscope")
                    }
                }
            }

            Section {
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
        }
        .listStyle(.insetGrouped)
        .overlay {
            if logs.isEmpty {
                ContentUnavailableView(
                    "No workouts yet",
                    systemImage: "waveform.path.ecg",
                    description: Text("Completed and stopped sessions will appear here.")
                )
            }
        }
        .navigationTitle("Workout history")
    }
}

struct N4x4WorkoutDetailView: View {
    @Environment(AppServices.self) private var services
    @Query(sort: \N4x4WorkoutLog.startedAt, order: .reverse) private var logs: [N4x4WorkoutLog]
    let log: N4x4WorkoutLog
    @State private var editTarget: N4x4WorkoutLog?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(log.title)
                        .font(.title2.bold())
                    if log.equipment != .unspecified {
                        Label(log.equipment.title, systemImage: log.equipment.systemImage)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
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

                if log.mode == .heartCheck {
                    HeartCheckComparison(log: log, logs: logs)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    metric("Duration", clock(log.duration), "timer")
                    metric("Average HR", bpm(log.averageHeartRate), "heart")
                    switch log.mode {
                    case .n4x4:
                        metric("Peak HR", bpm(log.peakHeartRate), "heart.fill")
                        metric("In target", percent(log.targetAdherence), "scope")
                        metric("1-min rise", signedBPM(log.averageOneMinuteRise), "arrow.up.right")
                        metric("1-min recovery", signedBPM(log.averageOneMinuteRecovery), "arrow.down.right")
                    case .steadyHeartRate:
                        metric("Peak HR", bpm(log.peakHeartRate), "heart.fill")
                        metric("In range", percent(log.targetAdherence), "scope")
                    case .heartCheck:
                        metric("HR at workload", bpm(log.workloadHeartRate), "speedometer")
                        metric("HR when stopping", bpm(log.stopHeartRate), "figure.stand")
                        metric("Drop after 1 min", bpm(log.recoveryDropAfter60), "arrow.down.right")
                        metric("Drop after 2 min", bpm(log.recoveryDropAfter120), "arrow.down.right")
                    }
                }

                measurementsSection

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
            N4x4WorkoutDetailsSheet(log: target)
        }
        .task(id: log.sessionID) {
            guard log.isCompleted, log.healthKitSaveState != .notRequested, log.appleActiveCalories == nil else { return }
            await services.n4x4.healthLinker.refresh(log)
        }
    }

    private var chartLegend: some View {
        HStack(spacing: 14) {
            Label("BPM", systemImage: "waveform.path.ecg").foregroundStyle(.pink)
            if log.mode != .heartCheck {
                Label("Target", systemImage: "line.diagonal").foregroundStyle(.yellow)
            }
        }
        .font(.caption.weight(.semibold))
    }

    /// Distance, pace and calories as Apple Health measured them, with the
    /// user's machine corrections marked where they apply.
    @ViewBuilder
    private var measurementsSection: some View {
        let rows = measurementRows
        if !rows.isEmpty || log.effortScore != nil {
            VStack(alignment: .leading, spacing: 12) {
                Text("Measurements").font(.headline)
                ForEach(rows, id: \.title) { row in
                    HStack {
                        Label(row.title, systemImage: row.symbol)
                            .foregroundStyle(.secondary)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(row.value)
                                .font(.body.weight(.semibold).monospacedDigit())
                            if let note = row.note {
                                Text(note)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let effort = log.effortScore {
                    HStack {
                        Label("Effort", systemImage: "gauge.with.dots.needle.67percent")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(effort) · \(EffortPicker.band(for: effort))")
                            .font(.body.weight(.semibold).monospacedDigit())
                    }
                }
            }
            .font(.subheadline)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private struct MeasurementRow {
        let title: String
        let symbol: String
        let value: String
        let note: String?
    }

    private var measurementRows: [MeasurementRow] {
        var rows: [MeasurementRow] = []
        if let distance = log.distanceKilometers {
            let note: String? = if log.correctedDistanceKilometers != nil, let apple = log.appleDistanceKilometers {
                "From the machine · Watch measured \(apple.formatted(.number.precision(.fractionLength(2)))) km"
            } else if log.correctedDistanceKilometers != nil {
                "From the machine"
            } else {
                "Apple Health"
            }
            rows.append(MeasurementRow(
                title: "Distance",
                symbol: "point.topleft.down.to.point.bottomright.curvepath",
                value: "\(distance.formatted(.number.precision(.fractionLength(2)))) km",
                note: note
            ))
            if distance > 0, log.duration > 0, [.treadmill, .treadmillWalk, .outdoor, .outdoorWalk].contains(log.equipment) {
                let secondsPerKm = log.duration / distance
                rows.append(MeasurementRow(
                    title: "Average pace",
                    symbol: "speedometer",
                    value: "\(clock(secondsPerKm)) /km",
                    note: nil
                ))
            }
        }
        if let incline = log.inclinePercent {
            rows.append(MeasurementRow(
                title: "Incline",
                symbol: "triangle",
                value: "\(incline.formatted(.number.precision(.fractionLength(0...1))))%",
                note: log.elevationGainMeters.map { "≈ \(Int($0.rounded())) m climbed" }
            ))
        }
        if let calories = log.appleActiveCalories {
            rows.append(MeasurementRow(
                title: "Active calories",
                symbol: "flame",
                value: "\(Int(calories.rounded())) kcal",
                note: "Apple Health"
            ))
        }
        return rows
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
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(log.isCompleted ? N4x4Palette.recovery : .secondary)
                .frame(width: 42, height: 42)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(log.title)
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

    private var symbol: String {
        switch log.mode {
        case .n4x4: return log.equipment.systemImage
        case .steadyHeartRate: return "heart.circle"
        case .heartCheck: return "stethoscope"
        }
    }

    private var summary: String {
        var parts = [Self.clock(log.duration)]
        if log.equipment != .unspecified { parts.append(log.equipment.title) }
        if log.mode == .heartCheck, let drop = log.recoveryDropAfter60 {
            parts.append("−\(Int(drop.rounded())) bpm in 1 min")
        } else if let average = log.averageHeartRate {
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
