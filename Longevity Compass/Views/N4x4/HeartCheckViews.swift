import Charts
import IntervalEngine
import IntervalUI
import SwiftData
import SwiftUI

/// The heart check is one monthly routine with two results, so nobody has to
/// choose between a "fitness test" and a "recovery test":
///
/// - Heart rate at a fixed workload: how hard the heart works at the same
///   speed and incline. It falls as aerobic fitness improves.
/// - Heart-rate drop after stopping: how fast the nervous system slows the
///   heart again. A faster drop is a strong marker of cardiovascular health.
enum HeartCheckSchedule {
    static let interval: TimeInterval = 28 * 24 * 60 * 60

    static func completedChecks(in logs: [N4x4WorkoutLog]) -> [N4x4WorkoutLog] {
        logs.filter { $0.mode == .heartCheck && $0.isCompleted && $0.workloadHeartRate != nil }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Days until the next check is due; zero or less means due now.
    static func daysUntilDue(lastCheck: Date, now: Date = .now) -> Int {
        let due = lastCheck.addingTimeInterval(interval)
        return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now), to: Calendar.current.startOfDay(for: due)).day ?? 0
    }

    /// The previous check at the same workload, which is the only fair
    /// comparison.
    static func previousCheck(before log: N4x4WorkoutLog, in logs: [N4x4WorkoutLog]) -> N4x4WorkoutLog? {
        completedChecks(in: logs).first {
            $0.startedAt < log.startedAt && $0.workloadSummary == log.workloadSummary
        }
    }
}

struct HeartCheckCard: View {
    let logs: [N4x4WorkoutLog]
    let onStart: () -> Void

    var body: some View {
        let checks = HeartCheckSchedule.completedChecks(in: logs)
        Button(action: onStart) {
            HStack(spacing: 13) {
                Image(systemName: "stethoscope")
                    .font(.title3)
                    .foregroundStyle(N4x4Palette.workload)
                    .frame(width: 42, height: 42)
                    .background(N4x4Palette.workload.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Heart check")
                            .font(.headline)
                        Spacer()
                        Text(status(checks))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isDue(checks) ? N4x4Palette.workload : .secondary)
                    }
                    Text(detail(checks))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func isDue(_ checks: [N4x4WorkoutLog]) -> Bool {
        guard let last = checks.first else { return true }
        return HeartCheckSchedule.daysUntilDue(lastCheck: last.startedAt) <= 0
    }

    private func status(_ checks: [N4x4WorkoutLog]) -> String {
        guard let last = checks.first else { return "Monthly" }
        let days = HeartCheckSchedule.daysUntilDue(lastCheck: last.startedAt)
        return days <= 0 ? "Due now" : "Next in \(days) d"
    }

    private func detail(_ checks: [N4x4WorkoutLog]) -> String {
        guard let last = checks.first, let workload = last.workloadHeartRate else {
            return "11 minutes, once a month: how hard your heart works at a fixed pace, and how fast it recovers."
        }
        var parts = ["\(Int(workload.rounded())) bpm at your workload"]
        if let drop = last.recoveryDropAfter60 {
            parts.append("drops \(Int(drop.rounded())) bpm in 1 min")
        }
        return parts.joined(separator: " · ")
    }
}

struct HeartCheckStartSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var settings: WorkoutSettings
    @Binding var details: N4x4WorkoutDetails
    let start: () -> Void

    @State private var workload: HeartCheckWorkload
    @State private var speed: String
    @State private var incline: String

    init(settings: Binding<WorkoutSettings>, details: Binding<N4x4WorkoutDetails>, start: @escaping () -> Void) {
        _settings = settings
        _details = details
        self.start = start
        let initial = settings.wrappedValue.heartCheckWorkload
            ?? HeartCheckWorkload(equipment: .treadmillWalk, speedKilometersPerHour: 5.5, inclinePercent: 8)
        _workload = State(initialValue: initial)
        _speed = State(initialValue: Self.text(initial.speedKilometersPerHour))
        _incline = State(initialValue: Self.text(initial.inclinePercent))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    measureRow(
                        "Heart rate at a fixed workload",
                        "How hard your heart works at the same speed and incline. Lower means fitter.",
                        symbol: "speedometer"
                    )
                    measureRow(
                        "Drop after stopping",
                        "How quickly your heart slows once you stand still. A bigger drop means healthier recovery.",
                        symbol: "arrow.down.heart"
                    )
                } header: {
                    Text("One check, two results")
                } footer: {
                    Text("3 min easy warm-up, 6 min at your workload, then stop and stand still for 2 min. Do it about once a month, ideally at a similar time of day.")
                }

                Section {
                    Picker("Performed on", selection: $workload.equipment) {
                        ForEach(N4x4Equipment.pickerOrder.filter { $0 != .unspecified }) { equipment in
                            Label(equipment.title, systemImage: equipment.systemImage).tag(equipment)
                        }
                    }
                    if workload.equipment.hasSpeedSetting {
                        LabeledContent("Speed") {
                            TextField("5.5", text: $speed)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Text("km/h").foregroundStyle(.secondary)
                        }
                    }
                    if workload.equipment.acceptsIncline {
                        LabeledContent("Incline") {
                            TextField("8", text: $incline)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Text("%").foregroundStyle(.secondary)
                        }
                    }
                    if !workload.equipment.hasSpeedSetting {
                        TextField("Machine setting, e.g. Level 8 or 120 W", text: $workload.setting)
                    }
                } header: {
                    Text("Your fixed workload")
                } footer: {
                    Text(workloadFooter)
                }
            }
            .navigationTitle("Heart check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        let resolved = resolvedWorkload
                        settings.heartCheckWorkload = resolved
                        details.equipment = resolved.equipment
                        dismiss()
                        start()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var resolvedWorkload: HeartCheckWorkload {
        var resolved = workload
        resolved.speedKilometersPerHour = workload.equipment.hasSpeedSetting ? Self.number(speed) : nil
        resolved.inclinePercent = workload.equipment.acceptsIncline ? Self.number(incline) : nil
        if workload.equipment.hasSpeedSetting { resolved.setting = "" }
        return resolved
    }

    private var workloadFooter: String {
        let base = "Choose something you can hold for 6 minutes that feels moderately hard, where you can still talk in short sentences. A brisk uphill walk works for most people."
        if let saved = settings.heartCheckWorkload, saved != resolvedWorkload {
            return base + " Changing it starts a new comparison, since results only compare at the same workload."
        }
        return base
    }

    private func measureRow(_ title: String, _ detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(N4x4Palette.workload)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    private static func text(_ value: Double?) -> String {
        value?.formatted(.number.precision(.fractionLength(0...1))) ?? ""
    }
}

/// This check against the previous one at the same workload.
struct HeartCheckComparison: View {
    let log: N4x4WorkoutLog
    let logs: [N4x4WorkoutLog]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Compared with last check", systemImage: "arrow.left.arrow.right")
                    .font(.headline)
                Spacer()
            }
            if let previous = HeartCheckSchedule.previousCheck(before: log, in: logs) {
                comparisonRow(
                    "At workload",
                    now: log.workloadHeartRate,
                    before: previous.workloadHeartRate,
                    betterWhenLower: true
                )
                comparisonRow(
                    "Drop after 1 min",
                    now: log.recoveryDropAfter60,
                    before: previous.recoveryDropAfter60,
                    betterWhenLower: false
                )
                Text("Last check \(previous.startedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("This is your baseline at \(log.workloadSummary ?? "this workload"). Your next check compares against it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("Published norms come from maximal treadmill tests, so they don't apply here. Your own trend is what counts.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func comparisonRow(_ title: String, now: Double?, before: Double?, betterWhenLower: Bool) -> some View {
        if let now, let before {
            let delta = now - before
            let improved = betterWhenLower ? delta < -1 : delta > 1
            let worse = betterWhenLower ? delta > 1 : delta < -1
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(before.rounded())) → \(Int(now.rounded())) bpm")
                    .monospacedDigit()
                Text(delta >= 0 ? "+\(Int(delta.rounded()))" : "\(Int(delta.rounded()))")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(improved ? N4x4Palette.recovery : worse ? N4x4Palette.effort : .secondary)
                    .frame(minWidth: 34, alignment: .trailing)
            }
            .font(.subheadline)
        }
    }
}

struct HeartCheckTrendView: View {
    @Query(sort: \N4x4WorkoutLog.startedAt, order: .reverse) private var logs: [N4x4WorkoutLog]

    var body: some View {
        let checks = HeartCheckSchedule.completedChecks(in: logs)
        let workload = checks.first?.workloadSummary
        let sameWorkload = checks.filter { $0.workloadSummary == workload }.reversed()

        List {
            Section {
                Text("Heart rate at your workload falls as aerobic fitness improves. The drop after stopping grows as your heart's recovery gets healthier. Each point is one check at \(workload ?? "your workload").")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Heart rate at workload") {
                trendChart(Array(sameWorkload), value: \.workloadHeartRate, color: N4x4Palette.workload)
            }

            Section("Drop after 1 minute") {
                trendChart(Array(sameWorkload), value: \.recoveryDropAfter60, color: N4x4Palette.recovery)
            }

            Section("All checks") {
                ForEach(checks) { log in
                    NavigationLink {
                        N4x4WorkoutDetailView(log: log)
                    } label: {
                        N4x4WorkoutRow(log: log)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Heart check trend")
    }

    private func trendChart(
        _ checks: [N4x4WorkoutLog],
        value: KeyPath<N4x4WorkoutLog, Double?>,
        color: Color
    ) -> some View {
        Chart(checks) { log in
            if let y = log[keyPath: value] {
                LineMark(x: .value("Date", log.startedAt), y: .value("BPM", y))
                    .foregroundStyle(color)
                PointMark(x: .value("Date", log.startedAt), y: .value("BPM", y))
                    .foregroundStyle(color)
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 160)
        .overlay {
            if checks.count < 2 {
                Text("The trend appears after your second check.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
