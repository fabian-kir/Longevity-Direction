import SwiftUI

/// Logs symptoms, or edits `existing` when given.
/// Common path: tap one or more symptom tiles, tap Log (onset defaults to now).
/// Several symptoms share one onset, each with its own level.
struct LogSymptomSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    var existing: SymptomEntry?
    /// Called after new symptoms are saved; not for edits.
    var onLogged: (() -> Void)?
    /// Shows the Insights link; the presenter opens Digestion Insights once the sheet is gone.
    var onOpenInsights: (() -> Void)?

    /// Picked symptoms, in `SymptomKind.allCases` order.
    @State private var picked: [SymptomKind]
    @State private var levels: [SymptomKind: SymptomLevel]
    @State private var onsetChoice: SymptomOnsetChoice = .now
    @State private var customOnset: Date = .now

    init(
        existing: SymptomEntry? = nil,
        onLogged: (() -> Void)? = nil,
        onOpenInsights: (() -> Void)? = nil
    ) {
        self.existing = existing
        self.onLogged = onLogged
        self.onOpenInsights = onOpenInsights
        if let existing, let kind = existing.kind {
            _picked = State(initialValue: [kind])
            _levels = State(initialValue: existing.level.map { [kind: $0] } ?? [:])
            _onsetChoice = State(initialValue: .earlier)
            _customOnset = State(initialValue: existing.onset)
        } else {
            // Nothing pre-picked, so an early tap on Log can't record a symptom by accident.
            _picked = State(initialValue: [])
            _levels = State(initialValue: [:])
        }
    }

    private var isEditing: Bool { existing != nil }

    private var periodStart: Date {
        SymptomOnsetChoice.lowerBound(
            editing: existing?.onset,
            periods: services.store.fetchTrackingPeriods(),
            activeStart: services.store.activeTrackingPeriod()?.start
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    tiles
                    levelRows
                    onsetSection
                }
                .padding(.horizontal)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .safeAreaInset(edge: .bottom) { logButton }
            .navigationTitle(isEditing ? "Edit symptom" : "Log symptoms")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                if let onOpenInsights {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            onOpenInsights()
                            dismiss()
                        } label: {
                            Label("Insights", systemImage: "chart.xyaxis.line")
                        }
                    }
                }
            }
        }
        .presentationDetents([.fraction(0.62), .large])
    }

    // MARK: - Symptoms

    private var tiles: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(SymptomKind.allCases) { kind in
                SymptomTile(kind: kind, isPicked: picked.contains(kind)) {
                    toggle(kind)
                }
            }
        }
    }

    private func toggle(_ kind: SymptomKind) {
        withAnimation(.snappy(duration: 0.2)) {
            if picked.contains(kind) {
                picked.removeAll { $0 == kind }
            } else if isEditing {
                // An edit changes one entry, so a new pick replaces the old one.
                picked = [kind]
            } else {
                picked.append(kind)
                picked.sort { SymptomKind.allCases.firstIndex(of: $0)! < SymptomKind.allCases.firstIndex(of: $1)! }
            }
        }
    }

    private func level(for kind: SymptomKind) -> SymptomLevel {
        levels[kind].flatMap { kind.levels.contains($0) ? $0 : nil } ?? kind.levels[0]
    }

    /// One row per picked symptom that has levels to choose from.
    @ViewBuilder
    private var levelRows: some View {
        let graded = picked.filter(\.hasLevelChoice)
        if !graded.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(graded) { kind in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(kind.label)
                            .font(.subheadline.weight(.semibold))
                        Picker(kind.label, selection: Binding(
                            get: { level(for: kind) },
                            set: { levels[kind] = $0 }
                        )) {
                            ForEach(kind.levels) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    // MARK: - Onset

    private var onsetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Started")
                .font(.subheadline.weight(.semibold))
            Picker("Started", selection: $onsetChoice) {
                ForEach(SymptomOnsetChoice.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if onsetChoice == .earlier {
                DatePicker(
                    "Onset",
                    selection: $customOnset,
                    in: periodStart...Date.now,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }
        }
    }

    // MARK: - Save

    private var logButton: some View {
        Button(action: save) {
            Text(logTitle)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
        }
        .buttonStyle(.glassProminent)
        .disabled(picked.isEmpty)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var logTitle: String {
        if isEditing { return "Save" }
        switch picked.count {
        case 0:  return "Pick a symptom"
        case 1:  return "Log \(picked[0].label.lowercased())"
        default: return "Log \(picked.count) symptoms"
        }
    }

    private func save() {
        let now = Date.now
        let onset = onsetChoice.date(now: now, periodStart: periodStart, custom: customOnset)
        if let existing {
            guard let kind = picked.first else { return }
            existing.kind = kind
            existing.level = level(for: kind)
            existing.onset = onset
            services.store.saveContext()
        } else {
            for kind in picked {
                services.recordSymptom(SymptomEntry(onset: onset, kind: kind, level: level(for: kind)))
            }
            onLogged?()
        }
        dismiss()
    }
}

extension SymptomKind {
    var systemImage: String {
        switch self {
        case .abdominalPain: "bolt.fill"
        case .bloating:      "balloon.fill"
        case .diarrhoea:     "drop.fill"
        case .gas:           "wind"
        case .nausea:        "tornado"
        case .heartburn:     "flame.fill"
        }
    }
}

/// A symptom to tap on or off.
private struct SymptomTile: View {
    let kind: SymptomKind
    let isPicked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: kind.systemImage)
                    .font(.title3)
                    .foregroundStyle(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(kind.label)
                    .font(.footnote.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 76)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isPicked ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.fill.tertiary))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.tint, lineWidth: isPicked ? 1.5 : 0)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }
}
