import SwiftUI

/// The stored intake targets and window, read by both the card and its settings sheet.
struct IntakePreferences: DynamicProperty {
    @AppStorage(IntakeSettings.Key.calorieTarget) var calorieTarget = 0.0
    @AppStorage(IntakeSettings.Key.energyGoal) var energyGoalRaw = EnergyGoal.maintain.rawValue
    @AppStorage(IntakeSettings.Key.proteinTarget) var proteinTarget = 0.0
    @AppStorage(IntakeSettings.Key.carbsTarget) var carbsTarget = 0.0
    @AppStorage(IntakeSettings.Key.fatTarget) var fatTarget = 0.0
    @AppStorage(IntakeSettings.Key.fiberTarget) var fiberTarget = IntakeSettings.Default.fiberTarget
    @AppStorage(IntakeSettings.Key.windowMode) var windowModeRaw = IntakeWindowMode.daily.rawValue
    @AppStorage(IntakeSettings.Key.windowLength) var windowLength = IntakeSettings.Default.windowLength
    /// `timeIntervalSinceReferenceDate` of the fixed-block anchor day.
    @AppStorage(IntakeSettings.Key.windowAnchor) var windowAnchor = 0.0

    var energyGoal: EnergyGoal {
        EnergyGoal(rawValue: energyGoalRaw) ?? .maintain
    }

    var windowMode: IntakeWindowMode {
        IntakeWindowMode(rawValue: windowModeRaw) ?? .daily
    }

    var targets: IntakeTargets {
        IntakeTargets(
            energyKcal: calorieTarget,
            energyGoal: energyGoal,
            proteinGrams: proteinTarget,
            carbsGrams: carbsTarget,
            fatGrams: fatTarget,
            fiberGrams: fiberTarget
        )
    }

    var window: IntakeWindow {
        IntakeWindow(
            mode: windowMode,
            length: windowLength,
            anchor: Date(timeIntervalSinceReferenceDate: windowAnchor)
        )
    }
}

/// Calories, macros and fibre consumed in the current window, against the user's targets.
struct IntakeCard: View {
    let entries: [NutritionEntry]

    @State private var showSettings = false
    private var preferences = IntakePreferences()

    init(entries: [NutritionEntry]) {
        self.entries = entries
    }

    var body: some View {
        // Re-evaluates each minute so "today" rolls over at midnight while the tab is open.
        TimelineView(.everyMinute) { context in
            let summary = IntakeEngine.summary(
                entries: entries,
                targets: preferences.targets,
                window: preferences.window,
                now: context.date
            )
            Button {
                showSettings = true
            } label: {
                content(summary)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens calorie, macro and window settings")
        }
        .padding()
        .glassCard(tint: .blue, cornerRadius: 18, tintOpacity: 0.10)
        .sheet(isPresented: $showSettings) {
            IntakeSettingsSheet()
        }
    }

    private func content(_ summary: IntakeSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(summary)
            energySection(summary)
            if summary.budgetDays > 1 {
                IntakeDayStrip(summary: summary)
            }
            macroGrid(summary)
            footnote(summary)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Header

    private func header(_ summary: IntakeSummary) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text(summary.windowTitle)
                } icon: {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(.blue)
                }
                .font(.headline)
                Text(windowSubtitle(summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private func windowSubtitle(_ summary: IntakeSummary) -> String {
        var parts: [String] = []
        if summary.budgetDays > 1, let first = summary.days.first, let last = summary.days.last {
            let range = "\(shortDate(first.date)) – \(last.isToday ? "today" : shortDate(last.date))"
            parts.append(range)
        }
        if let target = summary.targets.daily(.energy) {
            parts.append("\(kcal(target)) kcal/day · \(summary.targets.energyGoal.displayLabel.lowercased())")
        } else {
            parts.append("No calorie target")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Energy

    private func energySection(_ summary: IntakeSummary) -> some View {
        let consumed = summary.totals.energyKcal
        let budget = summary.budget(for: .energy)
        let progress = summary.progress(for: .energy)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(kcal(consumed))
                    .font(.title.weight(.bold))
                    .monospacedDigit()
                Text(budget.map { "/ \(kcal($0)) kcal" } ?? "kcal")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if let progress {
                    Text(energyLabel(progress, kind: summary.targets.kind(for: .energy)))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(progress.tint)
                        .monospacedDigit()
                } else {
                    Text("Set a target")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.blue)
                }
            }

            if let budget, let progress {
                ProgressView(value: min(consumed / budget, 1))
                    .tint(progress.tint)
                    .accessibilityLabel("Calories")
                    .accessibilityValue("\(kcal(consumed)) of \(kcal(budget)) kcal")
            }

            if summary.budgetDays > 1 {
                HStack {
                    Text("Today \(kcal(summary.today.energyKcal)) kcal")
                    Spacer()
                    if let perDay = summary.remainingPerDay(for: .energy) {
                        Text("≈ \(kcal(perDay)) kcal/day for \(summary.daysLeft) days")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
    }

    private func energyLabel(_ progress: IntakeProgress, kind: IntakeTargetKind) -> String {
        switch progress {
        case .remaining(let left):
            kind == .minimum ? "\(kcal(left)) to go" : "\(kcal(left)) left"
        case .reached:
            "Target reached"
        case .over(let excess):
            "\(kcal(excess)) over"
        }
    }

    // MARK: - Macros

    private func macroGrid(_ summary: IntakeSummary) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
            alignment: .leading,
            spacing: 10
        ) {
            ForEach(IntakeNutrient.macros) { nutrient in
                macroCell(nutrient, summary: summary)
            }
        }
    }

    private func macroCell(_ nutrient: IntakeNutrient, summary: IntakeSummary) -> some View {
        let consumed = summary.totals[nutrient]
        let budget = summary.budget(for: nutrient)
        let progress = summary.progress(for: nutrient)
        let valueText = budget.map { "\(grams(consumed)) / \(grams($0)) g" } ?? "\(grams(consumed)) g"

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(nutrient.displayLabel)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(valueText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let budget, let progress {
                ProgressView(value: min(consumed / budget, 1))
                    .tint(progress.tint)
            } else {
                // Keeps rows aligned when only some macros have a target.
                ProgressView(value: 0)
                    .hidden()
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Footnote

    @ViewBuilder
    private func footnote(_ summary: IntakeSummary) -> some View {
        let notes = footnotes(summary)
        if !notes.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                Text(notes.joined(separator: " "))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func footnotes(_ summary: IntakeSummary) -> [String] {
        var notes: [String] = []
        if summary.mealsWithoutEnergy == 1 {
            notes.append("1 meal has no calorie estimate.")
        } else if summary.mealsWithoutEnergy > 1 {
            notes.append("\(summary.mealsWithoutEnergy) meals have no calorie estimate.")
        }
        if summary.includesPhotoEstimates {
            notes.append("Photo meals are AI estimates.")
        }
        if summary.startsAtFirstLog && summary.window.mode != .daily {
            notes.append("Counted from your first logged meal.")
        }
        return notes
    }

    // MARK: - Formatting

    private func kcal(_ value: Double) -> String {
        Int(value.rounded()).formatted()
    }

    private func grams(_ value: Double) -> String {
        Int(value.rounded()).formatted()
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }
}

extension IntakeSummary {
    var windowTitle: String {
        let length = window.effectiveLength
        switch window.mode {
        case .daily:   return "Today"
        case .fixed:   return "\(length)-day block"
        case .rolling: return "Last \(length) days"
        }
    }
}

extension IntakeProgress {
    var tint: Color {
        switch self {
        case .remaining: .blue
        case .reached:   .green
        case .over:      .orange
        }
    }
}

/// Calories and protein so far, for the dashboard peek under the camera.
struct IntakePeekView: View {
    let entries: [NutritionEntry]

    private var preferences = IntakePreferences()

    init(entries: [NutritionEntry]) {
        self.entries = entries
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(IntakeEngine.summary(
                entries: entries,
                targets: preferences.targets,
                window: preferences.window,
                now: context.date
            ))
        }
    }

    private func content(_ summary: IntakeSummary) -> some View {
        let consumed = summary.totals.energyKcal
        let budget = summary.budget(for: .energy)
        let protein = summary.totals[.protein]
        let proteinBudget = summary.budget(for: .protein)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.windowTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(rounded(consumed))
                            .font(.title2.weight(.bold))
                        Text(budget.map { "/ \(rounded($0)) kcal" } ?? "kcal")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(IntakeNutrient.protein.displayLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(proteinBudget.map { "\(rounded(protein)) / \(rounded($0)) g" } ?? "\(rounded(protein)) g")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
            }
            if let budget, let progress = summary.progress(for: .energy) {
                ProgressView(value: min(consumed / budget, 1))
                    .tint(progress.tint)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func rounded(_ value: Double) -> String {
        Int(value.rounded()).formatted()
    }
}

/// One bar per day of a multi-day window, so fasting and feasting days stay visible.
private struct IntakeDayStrip: View {
    let summary: IntakeSummary

    private let barHeight: CGFloat = 40

    private var scale: Double {
        let peak = summary.days.map(\.energyKcal).max() ?? 0
        return max(peak, summary.targets.daily(.energy) ?? 0, 1)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(summary.days) { day in
                VStack(spacing: 4) {
                    if summary.days.count <= 7 {
                        Text(day.isUpcoming ? "–" : shortKcal(day.energyKcal))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    bar(for: day)
                    Text(day.date.formatted(.dateTime.weekday(.narrow)))
                        .font(.caption2.weight(day.isToday ? .bold : .regular))
                        .foregroundStyle(day.isToday ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                .accessibilityValue(day.isUpcoming ? "Upcoming" : "\(Int(day.energyKcal.rounded())) kcal")
            }
        }
    }

    private func bar(for day: IntakeSummary.Day) -> some View {
        ZStack(alignment: .bottom) {
            if day.isUpcoming {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(maxWidth: 28)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.blue.opacity(day.isToday ? 0.9 : 0.45))
                    .frame(maxWidth: 28)
                    .frame(height: max(3, barHeight * day.energyKcal / scale))
            }
            if let target = summary.targets.daily(.energy) {
                // One segment per column; side by side they read as the daily-target line.
                Rectangle()
                    .fill(.secondary.opacity(0.6))
                    .frame(height: 1)
                    .offset(y: -barHeight * target / scale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: barHeight, alignment: .bottom)
        .frame(height: barHeight)
    }

    private func shortKcal(_ value: Double) -> String {
        value >= 1_000
            ? (value / 1_000).formatted(.number.precision(.fractionLength(1))) + "k"
            : "\(Int(value.rounded()))"
    }
}
