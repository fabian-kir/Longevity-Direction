import IntervalEngine
import IntervalUI
import SwiftUI

/// Every adjustable part of the guided workouts, explained. Nothing here is
/// needed to start: the defaults are the standard protocols.
struct WorkoutSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var model = services.n4x4
        let hrMax = model.effectiveMaxHeartRate

        NavigationStack {
            Form {
                maxHeartRateSection(model: model)

                Section {
                    Stepper(value: $model.settings.n4x4.warmUpMinutes, in: 0...15) {
                        LabeledContent("Warm-up", value: "\(model.settings.n4x4.warmUpMinutes) min")
                    }
                    Stepper(value: $model.settings.n4x4.rounds, in: 2...8) {
                        LabeledContent("Hard intervals", value: "\(model.settings.n4x4.rounds)")
                    }
                    Stepper(value: $model.settings.n4x4.intervalMinutes, in: 1...10) {
                        LabeledContent("Interval length", value: "\(model.settings.n4x4.intervalMinutes) min")
                    }
                    Stepper(value: $model.settings.n4x4.recoveryMinutes, in: 1...8) {
                        LabeledContent("Recovery length", value: "\(model.settings.n4x4.recoveryMinutes) min")
                    }
                    Stepper(value: $model.settings.n4x4.cooldownMinutes, in: 0...15) {
                        LabeledContent("Cool-down", value: "\(model.settings.n4x4.cooldownMinutes) min")
                    }
                } header: {
                    Text("Norwegian 4×4 · structure")
                } footer: {
                    Text("Total \(model.settings.n4x4.totalMinutes) min.")
                }

                Section {
                    percentRange(
                        "Hard zone",
                        lower: $model.settings.n4x4.highLowerPercent,
                        upper: $model.settings.n4x4.highUpperPercent,
                        bounds: 70...100,
                        hrMax: hrMax
                    )
                    percentRange(
                        "Recovery zone",
                        lower: $model.settings.n4x4.recoveryLowerPercent,
                        upper: $model.settings.n4x4.recoveryUpperPercent,
                        bounds: 50...85,
                        hrMax: hrMax
                    )
                    Stepper(value: $model.settings.n4x4.toleranceBPM, in: 3...15) {
                        LabeledContent("Tolerance", value: "±\(model.settings.n4x4.toleranceBPM) bpm")
                    }
                    if !model.settings.n4x4.isStandard {
                        Button("Restore standard 4×4") {
                            model.settings.n4x4 = .standard
                        }
                    }
                } header: {
                    Text("Norwegian 4×4 · heart-rate targets")
                } footer: {
                    Text("At the start of each interval the target line rises from your current heart rate to the edge of the zone over one minute, then the full zone applies. Your Watch taps you once you're further outside it than the tolerance, and more often the further off you are.")
                }

                Section {
                    Toggle("Choose my own target", isOn: Binding(
                        get: { model.settings.steady.targetBPM != nil },
                        set: { useOwn in
                            model.settings.steady.targetBPM = useOwn
                                ? SteadySettings.standard.resolvedTarget(hrMax: hrMax)
                                : nil
                        }
                    ))
                    if let target = model.settings.steady.targetBPM {
                        Stepper(value: Binding(
                            get: { target },
                            set: { model.settings.steady.targetBPM = $0 }
                        ), in: 80...200) {
                            LabeledContent("Target", value: "\(target) bpm")
                        }
                    } else {
                        LabeledContent("Target", value: "\(model.settings.steady.resolvedTarget(hrMax: hrMax)) bpm")
                    }
                    Stepper(value: $model.settings.steady.toleranceBPM, in: 2...15) {
                        LabeledContent("Tolerance", value: "±\(model.settings.steady.toleranceBPM) bpm")
                    }
                    Stepper(value: $model.settings.steady.durationMinutes, in: 10...180, step: 5) {
                        LabeledContent("Duration", value: "\(model.settings.steady.durationMinutes) min")
                    }
                    Stepper(value: $model.settings.steady.warmUpMinutes, in: 0...15) {
                        LabeledContent("Warm-up", value: "\(model.settings.steady.warmUpMinutes) min")
                    }
                } header: {
                    Text("Hold heart rate")
                } footer: {
                    Text("The automatic target is 70% of your max heart rate, the upper end of easy aerobic training. After the warm-up the target eases in over three minutes. Finish any time after five minutes and the session is saved.")
                }

                if let workload = model.settings.heartCheckWorkload {
                    Section {
                        LabeledContent("Workload", value: workload.summary)
                    } header: {
                        Text("Heart check")
                    } footer: {
                        Text("Change it when you start your next check. Results only compare at the same workload.")
                    }
                }
            }
            .navigationTitle("Workout settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .task { await model.refreshMaxHeartRateEstimate() }
        }
    }

    @ViewBuilder
    private func maxHeartRateSection(model: N4x4SessionModel) -> some View {
        @Bindable var model = model
        let estimate = model.maxHeartRateEstimate
        Section {
            Toggle("Use my own max heart rate", isOn: Binding(
                get: { model.settings.customMaxHeartRate != nil },
                set: { useOwn in
                    model.settings.customMaxHeartRate = useOwn
                        ? Int((estimate?.value ?? 185).rounded())
                        : nil
                }
            ))
            if let custom = model.settings.customMaxHeartRate {
                Stepper(value: Binding(
                    get: { custom },
                    set: { model.settings.customMaxHeartRate = $0 }
                ), in: 120...230) {
                    LabeledContent("Max heart rate", value: "\(custom) bpm")
                }
            } else {
                LabeledContent("Estimated", value: estimate?.value.map { "\(Int($0.rounded())) bpm" } ?? "Unavailable")
            }
        } header: {
            Text("Max heart rate")
        } footer: {
            Text(estimateExplanation(estimate))
        }
    }

    private func estimateExplanation(_ estimate: N4x4SessionModel.MaxHeartRateEstimate?) -> String {
        var parts: [String] = []
        if let formula = estimate?.formula {
            parts.append("age formula 208 − 0.7 × age = \(Int(formula.rounded())) bpm")
        }
        if let observed = estimate?.observedMax {
            parts.append("your highest heart rate in the last 90 days = \(Int(observed.rounded())) bpm")
        }
        let base = parts.isEmpty
            ? "No estimate yet: add your date of birth in Apple Health, or set your own value."
            : "The estimate is the higher of: " + parts.joined(separator: ", and ") + "."
        return base + " If you know your real max from a lab or field test, use it: every target is a percentage of it."
    }

    private func percentRange(
        _ title: String,
        lower: Binding<Int>,
        upper: Binding<Int>,
        bounds: ClosedRange<Int>,
        hrMax: Double?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(lower.wrappedValue)–\(upper.wrappedValue)% of max")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let hrMax {
                Text("\(Int((Double(lower.wrappedValue) / 100 * hrMax).rounded()))–\(Int((Double(upper.wrappedValue) / 100 * hrMax).rounded())) bpm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Stepper("From \(lower.wrappedValue)%", value: lower, in: bounds.lowerBound...(upper.wrappedValue - 1))
                .font(.subheadline)
            Stepper("To \(upper.wrappedValue)%", value: upper, in: (lower.wrappedValue + 1)...bounds.upperBound)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}
