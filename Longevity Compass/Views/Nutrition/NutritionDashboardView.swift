import SwiftUI

struct NutritionDashboardView: View {
    let digest: NutritionDigest
    let entries: [NutritionEntry]

    @State private var showWeeklyDetails = false

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            IntakeCard(entries: entries)

            dashboardHeader
                .padding(.top, 8)

            if digest.totalEntries == 0 {
                NutritionStartCard()
            } else {
                if let guidance = digest.priorityGuidance {
                    NutritionGuidanceCard(guidance: guidance)
                }
                FoodPatternCard(digest: digest)
                weeklyDetailsCard
            }
        }
    }

    private var dashboardHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Your food pattern")
                .font(.title3.weight(.bold))
            Text("Last \(digest.lookbackDays) days · \(digest.coverageDays) days logged")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var weeklyDetailsCard: some View {
        DisclosureGroup(isExpanded: $showWeeklyDetails) {
            VStack(alignment: .leading, spacing: 14) {
                signalSection(
                    "Add more often",
                    rollups: digest.rollups.filter { !$0.bucket.lowerIsBetter }
                )
                Divider()
                signalSection(
                    "Keep in check",
                    rollups: digest.rollups.filter(\.bucket.lowerIsBetter)
                )
            }
            .padding(.top, 12)
        } label: {
            HStack {
                // The disclosure label is a button; keep the title out of the tint.
                Label {
                    Text("Weekly signals")
                        .foregroundStyle(Color.primary)
                } icon: {
                    Image(systemName: "chart.bar.fill")
                        .foregroundStyle(AppTab.nutrition.tint)
                }
                .font(.headline)
                Spacer()
                let onTarget = digest.rollups.filter { $0.status == .ok }.count
                Text("\(onTarget)/\(digest.rollups.count) on track")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding()
        .glassSurface(cornerRadius: 18)
    }

    private func signalSection(_ title: String, rollups: [NutritionBucketRollup]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            ForEach(rollups) { rollup in
                NutritionSignalRow(rollup: rollup)
            }
        }
    }
}

private struct NutritionStartCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text("Build a picture of how you eat")
            } icon: {
                Image(systemName: "camera.viewfinder")
                    .foregroundStyle(AppTab.nutrition.tint)
            }
            .font(.headline)

            Text("Log ordinary meals — not just the “good” ones. After a few days, the app can spot variety, protective food groups and patterns worth rebalancing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                onboardingChip("Variety", icon: "leaf")
                onboardingChip("Food groups", icon: "square.grid.3x3")
                onboardingChip("Next meal", icon: "sparkles")
            }
        }
        .padding()
        .glassCard(tint: AppTab.nutrition.tint, cornerRadius: 18, tintOpacity: 0.14)
    }

    private func onboardingChip(_ title: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(AppTab.nutrition.tint)
            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .glassSurface(cornerRadius: 12)
    }
}

private struct NutritionGuidanceCard: View {
    let guidance: NutritionGuidance

    private var tint: Color {
        switch guidance.tone {
        case .add, .maintain: AppTab.nutrition.tint
        case .rebalance: .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                GlassIconTile(
                    systemName: guidance.systemImage,
                    tint: tint,
                    size: 46,
                    cornerRadius: 13
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(guidance.eyebrow.uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(tint)
                    Text(guidance.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(guidance.rationale)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 7) {
                ForEach(guidance.ideas, id: \.self) { idea in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.caption)
                            .foregroundStyle(tint)
                        Text(idea)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: tint, cornerRadius: 18, tintOpacity: 0.17)
    }
}

private struct FoodPatternCard: View {
    let digest: NutritionDigest

    private var plantRollup: NutritionBucketRollup? {
        digest.rollup(for: .plantVariety)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label {
                    Text("Diet breadth")
                } icon: {
                    Image(systemName: "circle.hexagongrid.fill")
                        .foregroundStyle(AppTab.nutrition.tint)
                }
                .font(.headline)
                Spacer()
                Text("Patterns, not grams")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 8) {
                metric(
                    value: "\(Int((plantRollup?.weeklyValue ?? 0).rounded()))",
                    target: "of \(Int((plantRollup?.target ?? 30).rounded()))",
                    label: "distinct plants",
                    tint: .green
                )
                metric(
                    value: "\(digest.pattern.beneficialGroupsSeen)",
                    target: "of \(digest.pattern.beneficialGroupTarget)",
                    label: "food groups seen",
                    tint: .teal
                )
                metric(
                    value: "\(digest.pattern.mealsWithoutLimitFlags)",
                    target: "of \(digest.pattern.assessedMeals)",
                    label: "without limit flags",
                    tint: .mint
                )
            }

            Text("Food groups include vegetables, fruit, legumes, whole grains, nuts and seeds, omega-3 sources and fermented foods.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .glassCard(tint: AppTab.nutrition.tint, cornerRadius: 18, tintOpacity: 0.10)
    }

    private func metric(
        value: String,
        target: String,
        label: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                Text(target)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct NutritionSignalRow: View {
    let rollup: NutritionBucketRollup

    private var progress: Double {
        guard let value = rollup.weeklyValue, rollup.target > 0 else { return 0 }
        return min(value / rollup.target, 1)
    }

    private var tint: Color {
        switch rollup.status {
        case .ok: .green
        case .veryLow, .low, .high: .orange
        case .veryHigh: .red
        case .unknown: .gray
        }
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 9) {
                Image(systemName: rollup.bucket.systemImage)
                    .frame(width: 20)
                    .foregroundStyle(rollup.bucket.lowerIsBetter ? .orange : AppTab.nutrition.tint)
                Text(rollup.bucket.displayLabel)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(valueLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }
            ProgressView(value: progress)
                .tint(tint)
                .accessibilityLabel(rollup.bucket.displayLabel)
                .accessibilityValue(valueLabel)
        }
    }

    private var valueLabel: String {
        let value = Int((rollup.weeklyValue ?? 0).rounded())
        let target = Int(rollup.target.rounded())
        return rollup.bucket.lowerIsBetter
            ? "\(value) / ≤\(target)"
            : "\(value) / \(target)"
    }
}
