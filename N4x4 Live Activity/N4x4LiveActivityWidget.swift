import ActivityKit
import Foundation
import IntervalEngine
import SwiftUI
import WidgetKit

struct N4x4LiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: N4x4ActivityAttributes.self) { context in
            N4x4LiveActivityView(
                sessionID: context.attributes.sessionID,
                state: context.state
            )
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
            .widgetURL(Self.deepLink(for: context.attributes.sessionID))
        } dynamicIsland: { context in
            let state = context.state
            let tint = state.ringColor.liveActivityColor

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseMark(state: state, showsLabel: true)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    HeartRateMetric(state: state, alignment: .trailing)
                }

                DynamicIslandExpandedRegion(.center) {
                    CountdownText(state: state, scope: .phase)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedDetails(state: state)
                }
            } compactLeading: {
                PhaseMark(state: state, showsLabel: false)
            } compactTrailing: {
                CountdownText(state: state, scope: .phase)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 42)
            } minimal: {
                PhaseGauge(state: state)
            }
            .keylineTint(tint)
            .widgetURL(Self.deepLink(for: context.attributes.sessionID))
        }
        .supplementalActivityFamilies([.small])
    }

    private static func deepLink(for sessionID: UUID) -> URL? {
        URL(string: "longevity-compass://n4x4?session=\(sessionID.uuidString)")
    }
}

private struct N4x4LiveActivityView: View {
    @Environment(\.activityFamily) private var activityFamily

    let sessionID: UUID
    let state: N4x4ActivityAttributes.ContentState

    var body: some View {
        Group {
            switch activityFamily {
            case .small:
                smartStackView
            case .medium:
                lockScreenView
            @unknown default:
                lockScreenView
            }
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var smartStackView: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                PhaseMark(state: state, showsLabel: true)
                Spacer(minLength: 4)
                CountdownText(state: state, scope: .phase)
                    .font(.headline.weight(.semibold))
            }

            ProgressView(value: state.phaseProgress.clampedUnit)
                .tint(state.ringColor.liveActivityColor)

            HStack(spacing: 8) {
                HeartRateMetric(state: state, alignment: .leading)
                Spacer(minLength: 4)
                TargetMetric(state: state)
                AdjustmentMetric(state: state, includesText: false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var lockScreenView: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                PhaseMark(state: state, showsLabel: true)
                Spacer(minLength: 8)
                CountdownText(state: state, scope: .phase)
                    .font(.title2.weight(.semibold))
            }

            ProgressView(value: state.phaseProgress.clampedUnit)
                .tint(state.ringColor.liveActivityColor)

            HStack(alignment: .bottom, spacing: 16) {
                HeartRateMetric(state: state, alignment: .leading)
                TargetMetric(state: state)
                AdjustmentMetric(state: state, includesText: true)
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("TOTAL")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    CountdownText(state: state, scope: .total)
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var accessibilitySummary: String {
        let phaseTime = Self.clock(state.phaseRemaining)
        let heartRate = state.heartRate.map { "heart rate \(Int($0.rounded())) beats per minute" }
            ?? "heart rate unavailable"
        return "\(state.phaseLabel), \(phaseTime) remaining, \(heartRate)"
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct ExpandedDetails: View {
    let state: N4x4ActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 8) {
            ProgressView(value: state.phaseProgress.clampedUnit)
                .tint(state.ringColor.liveActivityColor)

            HStack(spacing: 12) {
                TargetMetric(state: state)
                AdjustmentMetric(state: state, includesText: true)
                Spacer(minLength: 4)
                Text("Total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                CountdownText(state: state, scope: .total)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct PhaseMark: View {
    let state: N4x4ActivityAttributes.ContentState
    let showsLabel: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.phaseSymbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(state.ringColor.liveActivityColor)
                .frame(width: 22, height: 22)
                .background(state.ringColor.liveActivityColor.opacity(0.18), in: Circle())

            if showsLabel {
                Text(state.phaseLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
    }
}

private struct PhaseGauge: View {
    let state: N4x4ActivityAttributes.ContentState

    var body: some View {
        Gauge(value: state.phaseProgress.clampedUnit) {
            EmptyView()
        } currentValueLabel: {
            Image(systemName: state.phaseSymbol)
                .font(.system(size: 8, weight: .bold))
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(state.ringColor.liveActivityColor)
        .foregroundStyle(.white)
    }
}

private struct HeartRateMetric: View {
    let state: N4x4ActivityAttributes.ContentState
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text("HR")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Image(systemName: "heart.fill")
                    .font(.caption2)
                    .foregroundStyle(.pink)
                Text(state.heartRate.map { String(Int($0.rounded())) } ?? "—")
                    .font(.headline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text("BPM")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct TargetMetric: View {
    let state: N4x4ActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("TARGET")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Label(targetText, systemImage: "scope")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }

    private var targetText: String {
        guard let lower = state.targetLower, let upper = state.targetUpper else { return "—" }
        let low = Int(lower.rounded())
        let high = Int(upper.rounded())
        return low == high ? "\(low)" : "\(low)–\(high)"
    }
}

private struct AdjustmentMetric: View {
    let state: N4x4ActivityAttributes.ContentState
    let includesText: Bool

    var body: some View {
        Label {
            if includesText {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(color)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch state.adjustmentHint {
        case .up: return "Go harder"
        case .down: return "Ease off"
        case .none: return state.targetLower == nil ? "No target" : "In range"
        @unknown default: return "In range"
        }
    }

    private var symbol: String {
        switch state.adjustmentHint {
        case .up: return "arrow.up.circle.fill"
        case .down: return "arrow.down.circle.fill"
        case .none: return state.targetLower == nil ? "minus.circle" : "checkmark.circle.fill"
        @unknown default: return "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch state.adjustmentHint {
        case .up: return .red
        case .down: return .cyan
        case .none: return state.targetLower == nil ? .secondary : .green
        @unknown default: return .green
        }
    }
}

private struct CountdownText: View {
    enum Scope {
        case phase
        case total
    }

    let state: N4x4ActivityAttributes.ContentState
    let scope: Scope

    var body: some View {
        Group {
            if let endDate, !state.isPaused, !state.isFinished {
                let now = Date.now
                Text(
                    timerInterval: now...max(now, endDate),
                    countsDown: true,
                    showsHours: false
                )
            } else {
                Text(Self.clock(remaining))
            }
        }
        .monospacedDigit()
        .contentTransition(.numericText())
    }

    private var endDate: Date? {
        switch scope {
        case .phase: return state.phaseEndDate
        case .total: return state.totalEndDate
        }
    }

    private var remaining: TimeInterval {
        switch scope {
        case .phase: return state.phaseRemaining
        case .total: return state.totalRemaining
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private extension N4x4ActivityAttributes.ContentState {
    var phaseSymbol: String {
        let normalized = phaseLabel.lowercased()
        if normalized.contains("high") { return "bolt.fill" }
        if normalized.contains("recovery") { return "wind" }
        if normalized.contains("cool") { return "snowflake" }
        if normalized.contains("stand still") { return "figure.stand" }
        if normalized.hasPrefix("hold") && normalized.contains("bpm") { return "heart.fill" }
        if ringColor == .amber { return "speedometer" }
        return "flame.fill"
    }
}

private extension RingColor {
    var liveActivityColor: Color {
        switch self {
        case .blue: return .cyan
        case .red: return .red
        case .green: return .green
        case .amber: return .orange
        @unknown default: return .cyan
        }
    }
}

private extension Double {
    var clampedUnit: Double {
        min(max(self, 0), 1)
    }
}
