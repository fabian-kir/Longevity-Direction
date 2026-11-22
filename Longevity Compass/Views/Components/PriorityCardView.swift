import SwiftUI

struct PriorityCardView: View {
    let item: PriorityItem

    @Environment(\.openURL) private var openURL
    @State private var showWhy: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            HStack(spacing: 16) {
                ValueRow(icon: "circle.dashed", label: "Now",   value: item.currentValueDescription)
                Divider().frame(height: 32)
                ValueRow(icon: item.trend.arrowSymbol, label: "Trend", value: item.trendDescription)
            }

            Text(item.reason)
                .font(.subheadline)
                .foregroundStyle(.primary)

            if !item.recommendedActions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What to do next")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(item.recommendedActions.prefix(3), id: \.self) { action in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(action).font(.subheadline)
                        }
                    }
                    if item.recommendedActions.count > 3 {
                        DisclosureGroup("More") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(item.recommendedActions.dropFirst(3), id: \.self) { action in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text("•").foregroundStyle(.secondary)
                                        Text(action).font(.subheadline)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                        .font(.caption.weight(.semibold))
                        .tint(.secondary)
                    }
                }
            }

            DisclosureGroup(isExpanded: $showWhy) {
                Text(item.rationale)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            } label: {
                Text("Why this matters")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            trackNowButton

            HStack {
                if let next = item.nextTrackingDate, item.reminderFrequency != .never {
                    Label("Next check \(next.formatted(.relative(presentation: .named)))", systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if item.reminderFrequency != .never {
                    Text("Every: \(item.reminderFrequency.displayLabel.lowercased())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No reminders while stable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: statusTint, cornerRadius: 18, tintOpacity: 0.22)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: item.systemImageName)
                .font(.title3.weight(.semibold))
                .frame(width: 32, height: 32)
                .foregroundStyle(statusTint)
                .glassEffect(.regular.tint(statusTint.opacity(0.22)), in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(.headline)
                Text(item.status.displayLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusTint)
            }
            Spacer()
            if item.dataIsStale {
                Text("Track now")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .foregroundStyle(.white)
                    .background(
                        Capsule()
                            .fill(statusTint)
                            .overlay(
                                Capsule().fill(
                                    LinearGradient(
                                        colors: [.white.opacity(0.30), .clear],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                            )
                    )
            }
        }
    }

    @ViewBuilder
    private var trackNowButton: some View {
        if AppleHealthLink.destination(for: item.domain) == .appleHealth {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    openURL(AppleHealthLink.url)
                } label: {
                    HStack {
                        Image(systemName: "heart.text.square")
                        Text("Open Apple Health")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(statusTint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(statusTint)
                }
                .buttonStyle(.plain)
                if let hint = AppleHealthLink.healthLocationHint(for: item.domain) {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusTint: Color {
        item.status.focusTint
    }
}

private struct ValueRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2)
                Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(value).font(.subheadline).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
