import SwiftUI
import SwiftData
import Charts

struct LogExerciseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \ExerciseDef.name) private var exercises: [ExerciseDef]

    var body: some View {
        NavigationStack {
            List(exercises) { exercise in
                NavigationLink(value: exercise) {
                    ExerciseDefRow(def: exercise)
                }
            }
            .navigationTitle("Log Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ExerciseDef.self) { def in
                SetLoggerView(exerciseName: def.name, photoData: def.photoData) { date, sets in
                    let entry = ExerciseEntry(date: date, name: def.name, symbol: def.sfSymbol, sets: sets)
                    context.insert(entry)
                    try? context.save()
                    dismiss()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if exercises.isEmpty {
                    ContentUnavailableView(
                        "No exercises",
                        systemImage: "dumbbell",
                        description: Text("Add exercises in the library first.")
                    )
                }
            }
        }
    }
}

// MARK: - Set Logger

struct SetLoggerView: View {
    let exerciseName: String
    let photoData: Data?
    let onSave: (Date, [WorkoutSet]) -> Void

    @State private var sets: [WorkoutSet]
    @State private var date: Date
    @State private var selectedSetID: UUID?
    @State private var pickerWeightKg: Double = 0
    @State private var pickerReps: Int = 1
    @State private var selectedChartLabel: String?

    @Query private var history: [ExerciseEntry]
    @Query private var matchedDefs: [ExerciseDef]
    private let initialDate: Date

    // 0–29.5 kg in 0.5 steps, 30–49 kg in 1 steps, then 50–300 kg in 5 steps
    private static let weightValues: [Double] =
        stride(from: 0.0, through: 29.5, by: 0.5).map { $0 } +
        stride(from: 30.0, through: 49.0, by: 1.0).map { $0 } +
        stride(from: 50.0, through: 300.0, by: 5.0).map { $0 }

    init(exerciseName: String, photoData: Data? = nil, initialSets: [WorkoutSet] = [], initialDate: Date = .now, onSave: @escaping (Date, [WorkoutSet]) -> Void) {
        self.exerciseName = exerciseName
        self.photoData = photoData
        self.initialDate = initialDate
        self.onSave = onSave
        let s = initialSets.isEmpty ? [WorkoutSet()] : initialSets
        _sets = State(initialValue: s)
        _date = State(initialValue: initialDate)
        if let last = s.last {
            _selectedSetID = State(initialValue: last.id)
            _pickerWeightKg = State(initialValue: Self.snap(last.weightKg))
            _pickerReps = State(initialValue: last.reps)
        }
        let name = exerciseName
        _history = Query(
            filter: #Predicate<ExerciseEntry> { $0.exerciseName == name },
            sort: [SortDescriptor(\.date, order: .reverse)]
        )
        _matchedDefs = Query(filter: #Predicate<ExerciseDef> { $0.name == name })
    }

    private var selectedIndex: Int? {
        sets.firstIndex(where: { $0.id == selectedSetID })
    }

    // Past sessions = history minus the entry currently being edited (matched by exact date)
    private var pastSessions: [ExerciseEntry] {
        history.filter { abs($0.date.timeIntervalSince(initialDate)) > 1 }
    }

    /// Running average of weight and reps for the given set index, over up to 3 most recent sessions.
    /// Returns nil if no past session had a set at this position.
    private func target(forSetIndex i: Int) -> (weight: Double, reps: Int)? {
        let recent = pastSessions.prefix(3)
        let relevantSets: [WorkoutSet] = recent.compactMap { entry in
            let s = entry.sets
            return i < s.count ? s[i] : nil
        }
        guard !relevantSets.isEmpty else { return nil }
        let avgW = relevantSets.map(\.weightKg).reduce(0, +) / Double(relevantSets.count)
        let avgR = Double(relevantSets.map(\.reps).reduce(0, +)) / Double(relevantSets.count)
        return (Self.snap(avgW), max(1, min(50, Int(avgR.rounded()))))
    }

    private var selectedTarget: (weight: Double, reps: Int)? {
        guard let idx = selectedIndex else { return nil }
        return target(forSetIndex: idx)
    }

    private var currentVolume: Double {
        sets.reduce(0) { $0 + $1.weightKg * Double($1.reps) }
    }

    /// Set positions that get a dedicated legend colour; extra sets fold into the
    /// last colour so the stack total still equals the session volume.
    private static let maxTrackedSetLines = 3

    private struct VolumePoint: Identifiable {
        let id = UUID()
        let index: Int
        let label: String           // categorical x value (unique per session)
        let date: Date
        let volume: Double          // total session volume → full stack height
        let setVolumes: [Double]    // raw per-set volume, ordered
        let isCurrent: Bool
    }

    /// Up to 10 most recent sessions (incl. the one being edited), evenly spaced by
    /// ordinal index so untrained days don't leave empty gaps on the x-axis.
    private var volumeChartData: [VolumePoint] {
        var raw: [(date: Date, sets: [WorkoutSet], isCurrent: Bool)] =
            pastSessions.prefix(9).reversed().map { ($0.date, $0.sets, false) }
        raw.append((date, sets, true))
        return raw.enumerated().map { i, s in
            VolumePoint(
                index: i,
                label: String(i),
                date: s.date,
                volume: s.sets.reduce(0) { $0 + $1.weightKg * Double($1.reps) },
                setVolumes: s.sets.map { $0.weightKg * Double($0.reps) },
                isCurrent: s.isCurrent
            )
        }
    }

    private struct SetSegment: Identifiable {
        let id = UUID()
        let label: String           // parent session (categorical x)
        let setNumber: Int          // 1-based
        let volume: Double          // raw per-set volume → segment height
        let isCurrent: Bool
    }

    /// One stack segment per set, at its true volume. Segments sharing an x auto-stack,
    /// so the full stack height equals the session's total volume.
    private var setSegments: [SetSegment] {
        volumeChartData.flatMap { p in
            p.setVolumes.enumerated().map { j, v in
                SetSegment(
                    label: p.label,
                    setNumber: j + 1,
                    volume: v,
                    isCurrent: p.isCurrent
                )
            }
        }
    }

    /// How many set positions get a distinct legend colour (0…3).
    private var trackedSetLineCount: Int {
        min(Self.maxTrackedSetLines, volumeChartData.map(\.setVolumes.count).max() ?? 0)
    }

    private func setColor(_ n: Int) -> Color {
        switch n {
        case 1: return .green
        case 2: return .yellow
        default: return .orange
        }
    }

    private var selectedVolumePoint: VolumePoint? {
        guard let label = selectedChartLabel else { return nil }
        return volumeChartData.first { $0.label == label }
    }

    /// Headroom above the tallest stack so top markers + tooltip aren't clipped.
    private var volumeYMax: Double {
        max(volumeChartData.map(\.volume).max() ?? 1, 1) * 1.2
    }

    /// ~5 evenly spaced x-axis ticks (always including first and last) so date
    /// labels stay readable regardless of how many sessions are plotted.
    private var volumeAxisTicks: [Int] {
        let n = volumeChartData.count
        guard n > 1 else { return volumeChartData.map(\.index) }
        let step = max(1, Int((Double(n) / 5).rounded()))
        var ticks = Array(stride(from: 0, to: n, by: step))
        if ticks.last != n - 1 { ticks.append(n - 1) }
        return ticks
    }

    // MARK: - Insight data (rendered cards)

    /// Past sessions oldest→newest, capped, for the trend charts.
    private var trendSessions: [ExerciseEntry] {
        Array(pastSessions.prefix(8)).reversed()
    }

    private var currentTopSet: Double { sets.map(\.weightKg).max() ?? 0 }

    private var previousTopSet: Double? {
        pastSessions.first.map { $0.sets.map(\.weightKg).max() ?? 0 }
    }

    private var topSetDelta: Double? {
        guard let prev = previousTopSet else { return nil }
        return currentTopSet - prev
    }

    private struct BandPoint: Identifiable {
        let id = UUID()
        let date: Date
        let heaviest: Double
        let lightest: Double
    }

    /// Heaviest→lightest set spread per session (+ the one being edited).
    private var bandData: [BandPoint] {
        var pts = trendSessions.map { e -> BandPoint in
            let w = e.sets.map(\.weightKg)
            return BandPoint(date: e.date, heaviest: w.max() ?? 0, lightest: w.min() ?? 0)
        }
        let cw = sets.map(\.weightKg)
        pts.append(BandPoint(date: date, heaviest: cw.max() ?? 0, lightest: cw.min() ?? 0))
        return pts
    }

    /// How many set positions to draw per-set trends for.
    private var trackedSetPositions: Int { min(sets.count, 4) }

    private struct SetSeriesPoint: Identifiable {
        let id = UUID()
        let order: Int
        let weight: Double
    }

    /// Weight at set position `i` across trend sessions + current.
    private func series(forPosition i: Int) -> [SetSeriesPoint] {
        var out: [SetSeriesPoint] = []
        var order = 0
        for e in trendSessions {
            let s = e.sets
            if i < s.count {
                out.append(SetSeriesPoint(order: order, weight: s[i].weightKg))
                order += 1
            }
        }
        if i < sets.count {
            out.append(SetSeriesPoint(order: order, weight: sets[i].weightKg))
        }
        return out
    }

    private var primaryMuscles: [MuscleGroup] { matchedDefs.first?.primaryMuscles ?? [] }
    private var secondaryMuscles: [MuscleGroup] { matchedDefs.first?.secondaryMuscles ?? [] }

    private func weightShort(_ kg: Double) -> String {
        kg.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(kg))" : String(format: "%.1f", kg)
    }

    private func trendColor(_ s: [SetSeriesPoint]) -> Color {
        guard let f = s.first?.weight, let l = s.last?.weight else { return .secondary }
        if l > f + 0.01 { return .green }
        if l < f - 0.01 { return .orange }
        return .secondary
    }

    var body: some View {
        Form {
            Section {
                ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
                    Button {
                        selectSet(at: index)
                    } label: {
                        HStack {
                            Text("Set \(index + 1)")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 46, alignment: .leading)
                            Spacer()
                            Text(weightLabel(set.weightKg))
                                .font(.subheadline)
                            Text("·")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 2)
                            Text("\(set.reps) reps")
                                .font(.subheadline)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(set.id == selectedSetID ? AppTab.train.tint : .clear)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(set.id == selectedSetID ? AppTab.train.tint.opacity(0.10) : nil)
                }
                .onDelete { sets.remove(atOffsets: $0) }

                Button {
                    var next = WorkoutSet()
                    next.weightKg = pickerWeightKg
                    next.reps = pickerReps
                    sets.append(next)
                    selectSet(at: sets.count - 1)
                } label: {
                    Label("Add Set", systemImage: "plus")
                }
            } header: {
                Text("Sets")
            } footer: {
                Text("Swipe left on a set to delete it.")
            }

            if let idx = selectedIndex {
                Section {
                    HStack(spacing: 0) {
                        Picker("weight", selection: $pickerWeightKg) {
                            ForEach(Self.weightValues, id: \.self) { w in
                                weightPickerLabel(w, isTarget: selectedTarget?.weight == w)
                                    .tag(w)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(width: 110)
                        .clipped()
                        .onChange(of: pickerWeightKg) { _, _ in updateSelectedSet() }

                        Text("kg")
                            .font(.body.weight(.semibold))
                            .padding(.leading, 6)

                        Spacer()

                        Picker("reps", selection: $pickerReps) {
                            ForEach(1...50, id: \.self) { r in
                                repsPickerLabel(r, isTarget: selectedTarget?.reps == r)
                                    .tag(r)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(width: 72)
                        .clipped()
                        .onChange(of: pickerReps) { _, _ in updateSelectedSet() }

                        Text("reps")
                            .font(.body.weight(.semibold))
                            .padding(.leading, 6)
                    }
                    .frame(height: 150)
                } header: {
                    Text("Set \(idx + 1)")
                }
            }

            Section("Date & Time") {
                DatePicker(
                    "Logged at",
                    selection: $date,
                    in: ...Date.now,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }

            if !pastSessions.isEmpty {
                Section("Volume + per-set") {
                    volumeChart
                }

                workingWeightCard
                lastTimeCard
                perSetTrendCard
            }

            musclesCard
        }
        .navigationTitle(exerciseName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    if let data = photoData, let img = UIImage(data: data) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    Text(exerciseName)
                        .font(.headline)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { onSave(date, sets) }
                    .disabled(sets.isEmpty)
            }
        }
    }

    // MARK: - Volume chart

    private func volumeShort(_ v: Double) -> String {
        v >= 100 ? "\(Int(v.rounded()))" : String(format: "%.0f", v)
    }

    @ViewBuilder
    private var volumeChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(setSegments) { seg in
                    BarMark(
                        x: .value("Session", seg.label),
                        y: .value("Set volume", seg.volume),
                        width: .ratio(0.6)
                    )
                    .foregroundStyle(setColor(seg.setNumber))
                    .opacity(seg.isCurrent ? 1 : 0.5)
                }

                if let sel = selectedVolumePoint {
                    RuleMark(x: .value("Session", sel.label))
                        .foregroundStyle(Color.secondary.opacity(0.3))
                        .annotation(
                            position: .top,
                            spacing: 4,
                            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .plot))
                        ) {
                            volumeTooltip(sel)
                        }
                }
            }
            .chartXSelection(value: $selectedChartLabel)
            .chartYScale(domain: 0...volumeYMax)
            .chartXAxis {
                AxisMarks(values: volumeAxisTicks.map(String.init)) { value in
                    if let s = value.as(String.self),
                       let p = volumeChartData.first(where: { $0.label == s }) {
                        AxisGridLine()
                        AxisValueLabel {
                            Text(p.date, format: .dateTime.day().month(.abbreviated))
                        }
                    }
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 170)

            volumeLegend
        }
    }

    @ViewBuilder
    private var volumeLegend: some View {
        HStack(spacing: 14) {
            Text("Stack = volume")
            ForEach(1...max(1, trackedSetLineCount), id: \.self) { n in
                legendItem(color: setColor(n), label: "Set \(n)")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 9, height: 9)
            Text(label)
        }
    }

    @ViewBuilder
    private func volumeTooltip(_ p: VolumePoint) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(p.date, format: .dateTime.day().month(.abbreviated).year())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Vol \(volumeShort(p.volume))")
                .font(.caption.weight(.semibold).monospacedDigit())
            if !p.setVolumes.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(p.setVolumes.enumerated()), id: \.offset) { i, v in
                        Text("\(volumeShort(v))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(setColor(i + 1))
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Insight cards

    @ViewBuilder
    private var workingWeightCard: some View {
        Section("Working weight") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(weightLabel(currentTopSet)).font(.title2.weight(.bold))
                Text("top set").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let d = topSetDelta, abs(d) >= 0.5 {
                    Label(String(format: "%+.1f kg", d),
                          systemImage: d > 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(d > 0 ? .green : .orange)
                }
            }
            Chart(bandData) { p in
                AreaMark(
                    x: .value("Date", p.date, unit: .day),
                    yStart: .value("Lightest", p.lightest),
                    yEnd: .value("Heaviest", p.heaviest)
                )
                .foregroundStyle(AppTab.train.tint.opacity(0.12))
                LineMark(
                    x: .value("Date", p.date, unit: .day),
                    y: .value("Heaviest", p.heaviest)
                )
                .foregroundStyle(AppTab.train.tint)
                .interpolationMethod(.catmullRom)
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 120)
        }
    }

    @ViewBuilder
    private var lastTimeCard: some View {
        if let last = pastSessions.first {
            Section {
                ForEach(Array(last.sets.enumerated()), id: \.offset) { i, s in
                    HStack {
                        Text("Set \(i + 1)").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(weightLabel(s.weightKg)) · \(s.reps)")
                    }
                    .font(.subheadline)
                }
            } header: {
                HStack {
                    Text("Last time")
                    Spacer()
                    Text(last.date, format: .relative(presentation: .named))
                        .textCase(nil)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var perSetTrendCard: some View {
        if !trendSessions.isEmpty, trackedSetPositions > 0 {
            Section("Per-set trend") {
                ForEach(0..<trackedSetPositions, id: \.self) { i in
                    let s = series(forPosition: i)
                    HStack(spacing: 10) {
                        Text("Set \(i + 1)")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .leading)
                        if let first = s.first {
                            Text(weightShort(first.weight))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                        Chart(s) { p in
                            LineMark(x: .value("i", p.order), y: .value("kg", p.weight))
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(trendColor(s))
                        }
                        .chartXAxis(.hidden)
                        .chartYAxis(.hidden)
                        .frame(height: 22)
                        if let last = s.last {
                            Text(weightShort(last.weight))
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var musclesCard: some View {
        if !primaryMuscles.isEmpty || !secondaryMuscles.isEmpty {
            Section("Muscles worked") {
                FlowLayout(spacing: 6) {
                    ForEach(primaryMuscles) { MuscleChip(group: $0, emphasized: true) }
                    ForEach(secondaryMuscles) { MuscleChip(group: $0, emphasized: false) }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func weightPickerLabel(_ w: Double, isTarget: Bool) -> Text {
        let s = w.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(w))" : String(format: "%.1f", w)
        if isTarget {
            return Text("\(Image(systemName: "target"))  \(s)").foregroundColor(AppTab.train.tint)
        }
        return Text(s)
    }

    private func repsPickerLabel(_ r: Int, isTarget: Bool) -> Text {
        if isTarget {
            return Text("\(Image(systemName: "target"))  \(r)").foregroundColor(AppTab.train.tint)
        }
        return Text("\(r)")
    }

    private func selectSet(at index: Int) {
        selectedSetID = sets[index].id
        pickerWeightKg = Self.snap(sets[index].weightKg)
        pickerReps = sets[index].reps
    }

    private func updateSelectedSet() {
        guard let i = selectedIndex else { return }
        sets[i].weightKg = pickerWeightKg
        sets[i].reps = pickerReps
    }

    private static func snap(_ kg: Double) -> Double {
        weightValues.min(by: { abs($0 - kg) < abs($1 - kg) }) ?? 0
    }

    private func weightLabel(_ kg: Double) -> String {
        if kg == 0 { return "BW" }
        return kg.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(kg)) kg"
            : String(format: "%.1f kg", kg)
    }
}
