import SwiftUI

struct FocusView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let result = services.currentResult {
                    if let bio = services.bioAge {
                        BioAgePanel(estimate: bio)
                    }

                    let winItems = PriorityEngine.wins(from: result.allItems)
                    if !winItems.isEmpty {
                        WinsStrip(items: winItems)
                    }

                    if result.topItems.isEmpty && winItems.isEmpty && services.bioAge == nil {
                        allClearState
                    } else if !result.topItems.isEmpty {
                        focusSection(topItems: result.topItems)
                    } else if winItems.isEmpty == false || services.bioAge != nil {
                        allClearInline
                    }

                    if let bio = services.bioAge, !(bio.wins.isEmpty && bio.opportunities.isEmpty) {
                        ContributorsSection(estimate: bio)
                    }
                } else if services.isRefreshing {
                    ProgressView("Reading your data…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                }
            }
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .navigationTitle("Focus")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: PriorityItem.self) { item in
            ScrollView {
                PriorityCardView(item: item)
                    .padding()
            }
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .refreshable { await services.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    DataExportView()
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await services.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.bounce, value: services.isRefreshing)
                }
                .accessibilityLabel("Refresh")
            }
        }
    }

    @ViewBuilder
    private func focusSection(topItems: [PriorityItem]) -> some View {
        FocusHeroCard(item: topItems[0])

        if topItems.count > 1 {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Also worth attention")
                VStack(spacing: 8) {
                    ForEach(Array(topItems.dropFirst())) { item in
                        NavigationLink(value: item) {
                            CompactPriorityRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var allClearState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.green)
            Text("All clear")
                .font(.title2.weight(.semibold))
            Text("Nothing urgent right now. Keep the good habits going.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .padding(.horizontal, 24)
        .glassCard(tint: .green, cornerRadius: 18, tintOpacity: 0.22)
    }

    private var allClearInline: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)
                .symbolEffect(.pulse, options: .repeating)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing urgent today")
                    .font(.subheadline.weight(.semibold))
                Text("Keep the good habits going.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: .green, cornerRadius: 14, tintOpacity: 0.22)
    }
}

// MARK: - Bio age panel

private struct BioAgePanel: View {
    let estimate: BioAgeEstimate

    @State private var showCalculationSheet: Bool = false

    private var tint: Color { AppTab.focus.tint }

    private var deltaTint: Color {
        if estimate.delta <= -0.5 { return .green }
        if estimate.delta >=  0.5 { return .orange }
        return .secondary
    }

    private var deltaLabel: String {
        let abs = abs(estimate.delta)
        let unit = abs >= 2 ? "yrs" : "yr"
        if estimate.delta <= -0.25 {
            return String(format: "−%.1f %@ younger", abs, unit)
        }
        if estimate.delta >= 0.25 {
            return String(format: "+%.1f %@ older", abs, unit)
        }
        return "On par with your age"
    }

    private var trendLabel: String {
        switch estimate.trend {
        case .improving:  "Trending younger"
        case .worsening:  "Aging faster"
        case .stable:     "Holding steady"
        case .unknown:    "Building trend…"
        }
    }

    private var trendTint: Color {
        switch estimate.trend {
        case .improving:  .green
        case .worsening:  .orange
        case .stable:     .secondary
        case .unknown:    .secondary
        }
    }

    var body: some View {
        Button {
            showCalculationSheet = true
        } label: {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Biological age")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(tint)
                            .textCase(.uppercase)
                        Text(String(format: "%.1f", estimate.biologicalAge))
                            .font(.system(size: 56, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(String(format: "Chronological %.1f", estimate.chronologicalAge))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    GlassIconTile(systemName: "hourglass", tint: tint, size: 56)
                }

                HStack(spacing: 8) {
                    chip(text: deltaLabel,
                         icon: estimate.delta <= -0.25 ? "arrow.down.right" :
                               estimate.delta >=  0.25 ? "arrow.up.right" : "equal",
                         color: deltaTint)
                    chip(text: trendLabel,
                         icon: estimate.trend.arrowSymbol == "questionmark" ? "clock" : estimate.trend.arrowSymbol,
                         color: trendTint)
                }

                if let lever = estimate.topLever {
                    topLeverLine(for: lever)
                }

                if estimate.confidence < 0.7 {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(confidenceCopy)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                    Text("Tap to see how this was calculated")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(tint.opacity(0.85))
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(tint: tint, cornerRadius: 22)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens calculation breakdown")
        .sheet(isPresented: $showCalculationSheet) {
            BioAgeDetailSheet(estimate: estimate)
        }
    }

    @ViewBuilder
    private func topLeverLine(for lever: BioInputReading) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.forward.circle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
            Text("Your biggest lever right now: \(lever.signal.displayName)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var confidenceCopy: String {
        let pct = Int((estimate.confidence * 100).rounded())
        if estimate.confidence < 0.4 {
            return "Estimate from \(pct)% of inputs — log bloodwork & wear-time to sharpen it."
        }
        return "Estimate from \(pct)% of inputs — add bloodwork to sharpen it."
    }

    private func chip(text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(color)
        .glassChip(tint: color, tintOpacity: 0.22)
    }
}

// MARK: - Wins strip

private struct WinsStrip: View {
    let items: [PriorityItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "You're crushing it")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            WinPill(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            // Cards run to the screen edge while scrolling instead of being
            // cut off at the content margin.
            .scrollClipDisabled()
        }
    }
}

private struct WinPill: View {
    let item: PriorityItem

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: item.systemImageName)
                .font(.subheadline.weight(.semibold))
                .frame(width: 30, height: 30)
                .foregroundStyle(.white)
                .background(
                    Circle()
                        .fill(Color.green)
                        .overlay(
                            Circle().fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.35), .clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        )
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(item.currentValueDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if item.trend == .improving {
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 260, alignment: .leading)
        .glassCard(tint: .green, cornerRadius: 14, tintOpacity: 0.24)
    }
}

// MARK: - Contributors section

private struct ContributorsSection: View {
    let estimate: BioAgeEstimate

    /// Match each contributor back to its underlying reading via its typed
    /// `signal` field. Each signal contributes at most one reading per
    /// evaluate-pass, so this is unambiguous.
    private func reading(for contributor: BioAgeContributor) -> BioInputReading? {
        estimate.readings.first { $0.signal == contributor.signal }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "What's shaping your age")
            VStack(spacing: 10) {
                if !estimate.wins.isEmpty {
                    ContributorList(
                        title: "Working in your favor",
                        accent: .green,
                        items: Array(estimate.wins.prefix(3)),
                        readingLookup: reading(for:)
                    )
                }
                if !estimate.opportunities.isEmpty {
                    ContributorList(
                        title: "Biggest opportunities",
                        accent: .orange,
                        items: Array(estimate.opportunities.prefix(3)),
                        readingLookup: reading(for:)
                    )
                }
            }
        }
    }
}

private struct ContributorList: View {
    let title: String
    let accent: Color
    let items: [BioAgeContributor]
    let readingLookup: (BioAgeContributor) -> BioInputReading?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(accent).frame(width: 6, height: 6)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            VStack(spacing: 6) {
                ForEach(items) { item in
                    ContributorRow(
                        item: item,
                        reading: readingLookup(item),
                        accent: accent
                    )
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 14)
    }
}

private struct ContributorRow: View {
    let item: BioAgeContributor
    let reading: BioInputReading?
    let accent: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.domain.systemImageName)
                .font(.subheadline.weight(.semibold))
                .frame(width: 26, height: 26)
                .foregroundStyle(accent)
                .glassEffect(.regular.tint(accent.opacity(0.22)), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label)
                    .font(.subheadline.weight(.semibold))
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let reading {
                    ZScoreBar(zScore: reading.zScore, accent: accent)
                }
                YearsBadgeLabel(years: item.years, accent: accent)
            }
        }
    }
}

// MARK: - Hero card (the one thing to focus on)

private struct FocusHeroCard: View {
    let item: PriorityItem

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            heroHeader

            Text(item.reason)
                .font(.title3)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: "circle.dashed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.currentValueDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            whyItMatters

            if !item.recommendedActions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Do this")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    ForEach(item.recommendedActions.prefix(2), id: \.self) { action in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(tint)
                            Text(action)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            primaryActionButton
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: tint, cornerRadius: 22, tintOpacity: 0.30)
    }

    private var heroHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            GlassIconTile(systemName: item.systemImageName, tint: tint, size: 64, cornerRadius: 16)

            VStack(alignment: .leading, spacing: 4) {
                Text("Focus here first")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .textCase(.uppercase)
                Text(item.title)
                    .font(.system(.largeTitle, design: .default).weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(item.status.displayLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
            }
            Spacer(minLength: 0)
        }
    }

    private var whyItMatters: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Why it matters")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(item.rationale)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        if AppleHealthLink.destination(for: item.domain) == .appleHealth {
            Button {
                openURL(AppleHealthLink.url)
            } label: {
                actionLabel(icon: "heart.text.square", text: "Open Apple Health", trailing: "arrow.up.right.square")
            }
            .buttonStyle(.plain)
        }
    }

    private func actionLabel(icon: String, text: String, trailing: String) -> some View {
        HStack {
            Image(systemName: icon)
            Text(text).font(.body.weight(.semibold))
            Spacer()
            Image(systemName: trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .foregroundStyle(.white)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.28), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.30), lineWidth: 0.8)
        )
        .shadow(color: tint.opacity(0.30), radius: 8, x: 0, y: 4)
    }

    private var tint: Color {
        item.status.focusTint
    }
}

// MARK: - Compact row (secondary items)

private struct CompactPriorityRow: View {
    let item: PriorityItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImageName)
                .font(.subheadline.weight(.semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(tint)
                .glassChip(tint: tint, tintOpacity: 0.22)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(item.currentValueDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(item.status.displayLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassSurface(cornerRadius: 12)
    }

    private var tint: Color {
        item.status.focusTint
    }
}

// MARK: - Shared section label

private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 4)
    }
}

// MARK: - Shared status color

extension DomainStatus {
    /// Status colour on the Focus tab. The priority detail uses the same
    /// mapping, so a row and the card it opens always match.
    var focusTint: Color {
        switch self {
        case .urgent, .bad:                       .red
        case .good:                               .green
        case .borderline, .missing, .unknown:     AppTab.focus.tint
        }
    }
}
