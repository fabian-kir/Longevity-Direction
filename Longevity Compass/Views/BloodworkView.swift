import SwiftUI
import SwiftData

struct BloodworkView: View {
    @Environment(AppServices.self) private var services
    @Query(sort: \BloodworkPanel.date, order: .reverse) private var panels: [BloodworkPanel]
    @State private var showAddSheet = false

    var body: some View {
        Form {
            cadenceSummarySection

            if panels.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("No panels yet", systemImage: "drop")
                            .font(.headline)
                        Text("Add the results from your most recent blood draw. The app will remind you when it's time for the next one — yearly at most, less often when everything looks clean.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        NavigationLink {
                            BloodworkMarkerGuideView()
                        } label: {
                            Label("Which markers should I ask for?", systemImage: "info.circle")
                                .font(.footnote.weight(.semibold))
                        }
                        .padding(.top, 2)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Section {
                    ForEach(panels) { panel in
                        NavigationLink {
                            BloodworkPanelDetailView(panel: panel)
                        } label: {
                            BloodworkPanelRow(panel: panel)
                        }
                    }
                    .onDelete(perform: deletePanels)
                } header: {
                    Text("Panels")
                } footer: {
                    Text("Glucose values sync to Apple Health automatically. Other markers stay in-app — HealthKit doesn't expose native types for lipids, HbA1c, hs-CRP, vitamins, hormones, etc.")
                }
            }
        }
        .navigationTitle("Bloodwork")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    BloodworkMarkerGuideView()
                } label: {
                    Label("Marker guide", systemImage: "info.circle")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add panel", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddBloodworkPanelSheet()
        }
    }

    @ViewBuilder
    private var cadenceSummarySection: some View {
        if let item = services.currentResult?.allItems.first(where: { $0.domain == .bloodwork }) {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "calendar.badge.clock")
                            .foregroundStyle(cadenceTint(for: item.status))
                        Text(cadenceHeadline(for: item))
                            .font(.subheadline.weight(.semibold))
                    }
                    Text(item.reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func cadenceHeadline(for item: PriorityItem) -> String {
        switch item.status {
        case .missing:
            return "Book a baseline panel"
        case .bad, .borderline:
            if let next = item.nextTrackingDate {
                return "Next panel: \(next.formatted(.relative(presentation: .named)))"
            }
            return "Plan a recheck in ~12 months"
        case .good:
            if let next = item.nextTrackingDate {
                return "Next panel: \(next.formatted(.relative(presentation: .named)))"
            }
            return "All clean — recheck in ~3 years"
        case .urgent, .unknown:
            return "Open the most recent panel"
        }
    }

    private func cadenceTint(for status: DomainStatus) -> Color {
        switch status {
        case .urgent, .bad: .red
        case .borderline:   .orange
        case .good:         .green
        case .missing:      .blue
        case .unknown:      .gray
        }
    }

    private func deletePanels(_ indexSet: IndexSet) {
        let toDelete = indexSet.map { panels[$0] }
        Task {
            for panel in toDelete {
                await services.deleteBloodworkPanel(panel)
            }
        }
    }
}

// MARK: - Panel row

private struct BloodworkPanelRow: View {
    let panel: BloodworkPanel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(panel.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                flagBadge(panel.worstFlag)
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        let markers = "\(panel.markers.count) marker\(panel.markers.count == 1 ? "" : "s")"
        guard let lab = panel.labName, !lab.isEmpty else { return markers }
        return "\(lab) · \(markers)"
    }

    @ViewBuilder
    private func flagBadge(_ flag: BloodworkFlag) -> some View {
        Text(flag.displayLabel)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(badgeTint(flag))
            .glassChip(tint: badgeTint(flag), tintOpacity: 0.25)
    }

    private func badgeTint(_ flag: BloodworkFlag) -> Color {
        switch flag {
        case .good:       .green
        case .borderline: .orange
        case .bad:        .red
        case .unknown:    .gray
        }
    }
}
