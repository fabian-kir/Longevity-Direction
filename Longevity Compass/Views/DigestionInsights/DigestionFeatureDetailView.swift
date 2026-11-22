import Charts
import DigestionInsightsEngine
import SwiftUI

/// One food or allergen: effect, confidence, delay, basis and the two charts
/// (exposure–symptom pairs over the delay curve, shared 0–96 h axis).
struct DigestionFeatureDetailView: View {
    let feature: FeatureResult
    /// Input of the run that produced `feature`; pairs are computed from it.
    let input: AnalysisInput?

    private var row: DigestionPresentation.Row { DigestionPresentation.row(for: feature) }
    private var maxLag: Int { input?.config.maxLagHours ?? 96 }
    private var showsEffect: Bool { feature.level == .earlySignal || feature.level == .clearPattern }

    private var pairs: [DigestionPresentation.Pair] {
        input.map { DigestionPresentation.pairs(featureID: feature.featureID, input: $0) } ?? []
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name).font(.title3.weight(.semibold))
                        Text(row.kindLabel).font(.subheadline).foregroundStyle(.secondary)
                    }
                    DigestionLevelBadge(level: feature.level)
                        .padding(.top, 2)
                    if let confounded = row.confoundedText {
                        Text(confounded).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if showsEffect {
                    Text(DigestionPresentation.doctorLine).font(.subheadline.weight(.semibold))
                }
            }

            if let overall = feature.overall {
                Section("Effect") {
                    LabeledContent("Peak effect") {
                        Text("×\(DigestionPresentation.ratio(overall.peakRR.median))")
                    }
                    Text("Symptoms up to \(DigestionPresentation.ratio(overall.peakRR.median)) times as frequent at the peak; 90 % range \(DigestionPresentation.ratio(overall.peakRR.lower))–\(DigestionPresentation.ratio(overall.peakRR.upper)).")
                        .font(.footnote).foregroundStyle(.secondary)
                    LabeledContent("Extra symptoms per meal") {
                        Text(overall.excessPerExposure.median.formatted(.number.precision(.fractionLength(2))))
                    }
                    Text("90 % range \(overall.excessPerExposure.lower.formatted(.number.precision(.fractionLength(2))))–\(overall.excessPerExposure.upper.formatted(.number.precision(.fractionLength(2)))).")
                        .font(.footnote).foregroundStyle(.secondary)
                    LabeledContent("Confidence", value: DigestionPresentation.percent(overall.probRaises))
                    Text("Estimated chance that symptoms become more frequent after eating this.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let lag = overall.medianLagHours {
                        LabeledContent("Delay") {
                            Text("median about \(DigestionPresentation.hours(lag.median))")
                        }
                        Text("90 % range \(DigestionPresentation.hours(lag.lower))–\(DigestionPresentation.hours(lag.upper)) after eating.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let main = feature.mainKind {
                        LabeledContent("Main symptom", value: DigestionPresentation.symptomLabel(main))
                    }
                    if feature.level == .clearPattern,
                       let first = feature.firstHalfProbRaises, let second = feature.secondHalfProbRaises {
                        LabeledContent("Both halves agree") {
                            Text("\(DigestionPresentation.percent(first)) · \(DigestionPresentation.percent(second))")
                        }
                        Text("The pattern shows up in the first and in the second half of your log on its own.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Basis") {
                LabeledContent("Meals with it", value: "\(feature.exposureCount)")
                LabeledContent("Symptoms within 96 h after", value: "\(feature.symptomsAfterCount)")
            }

            if !feature.lagCurve.isEmpty || !pairs.isEmpty {
                Section {
                    pairsChart
                        .frame(height: 200)
                        .padding(.vertical, 4)
                    if !feature.lagCurve.isEmpty {
                        curveChart
                            .frame(height: 160)
                            .padding(.vertical, 4)
                    }
                } header: {
                    Text("After eating")
                } footer: {
                    Text("Top: each dot is a symptom that came that many hours after a meal with \(row.name); larger dots are higher levels. The grey band shows how many to expect if \(row.name) had no effect. Bottom: estimated change in symptom rate by hours after eating, with 90 % band; 1 means no change.")
                }
            }

            Section {
                Text(DigestionPresentation.disclaimer).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(row.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var xDomain: ClosedRange<Double> { 0...Double(maxLag) }
    private var xTicks: [Double] { stride(from: 0, through: Double(maxLag), by: 24).map { $0 } }

    private var pairsChart: some View {
        let expected = DigestionPresentation.smoothedExpected(feature.lagCurve)
        return Chart {
            ForEach(expected, id: \.hour) { point in
                AreaMark(
                    x: .value("Hours after eating", Double(point.hour) + 0.5),
                    yStart: .value("Zero", 0),
                    yEnd: .value("Expected if no effect", point.expected)
                )
                .foregroundStyle(.gray.opacity(0.25))
            }
            ForEach(pairs) { pair in
                PointMark(
                    x: .value("Hours after eating", pair.hoursAfter),
                    y: .value("Symptoms", Double(pair.stack) - 0.5)
                )
                .foregroundStyle(by: .value("Symptom", DigestionPresentation.symptomLabel(pair.kind)))
                .symbolSize(pair.band == .highest ? 40 : (pair.band == .middle ? 24 : 12))
            }
        }
        .chartXScale(domain: xDomain)
        .chartXAxis {
            AxisMarks(values: xTicks) { value in
                AxisGridLine()
                AxisValueLabel { if let h = value.as(Double.self) { Text("\(Int(h)) h") } }
            }
        }
        .chartYAxisLabel("Symptoms per hour")
        .chartLegend(position: .top, alignment: .leading)
    }

    private var curveChart: some View {
        Chart {
            ForEach(feature.lagCurve, id: \.hour) { point in
                AreaMark(
                    x: .value("Hours after eating", Double(point.hour) + 0.5),
                    yStart: .value("Lower", point.rr.lower),
                    yEnd: .value("Upper", point.rr.upper)
                )
                .foregroundStyle(.teal.opacity(0.22))
                LineMark(
                    x: .value("Hours after eating", Double(point.hour) + 0.5),
                    y: .value("Rate ratio", point.rr.median)
                )
                .foregroundStyle(.teal)
            }
            RuleMark(y: .value("No effect", 1))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .trailing) {
                    Text("no effect").font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartXScale(domain: xDomain)
        .chartXAxis {
            AxisMarks(values: xTicks) { value in
                AxisGridLine()
                AxisValueLabel { if let h = value.as(Double.self) { Text("\(Int(h)) h") } }
            }
        }
        .chartYAxisLabel("Rate ratio")
    }
}

struct DigestionLevelBadge: View {
    let level: PatternLevel

    var body: some View {
        Text(DigestionPresentation.badge(level))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(level == .earlySignal ? Self.readableYellow : tint)
            .background(tint.opacity(0.15), in: Capsule())
    }

    /// Plain yellow text is unreadable on a light background.
    private static let readableYellow = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .systemYellow
            : UIColor(red: 0.60, green: 0.44, blue: 0.0, alpha: 1)
    })

    private var tint: Color {
        switch level {
        case .clearPattern:  .orange
        case .earlySignal:   .yellow
        case .noLinkFound:   .green
        case .inconclusive:  .secondary
        case .notEnoughData: .secondary
        }
    }
}
