import DigestionInsightsEngine
import SwiftUI
import SwiftData

/// Hub for Digestion Insights: status, results, symptom log, export.
struct DigestionInsightsView: View {
    @Environment(AppServices.self) private var services
    @Query(sort: \SymptomEntry.onset, order: .reverse) private var symptoms: [SymptomEntry]
    @Query(sort: \DigestionTrackingPeriod.start, order: .reverse) private var periods: [DigestionTrackingPeriod]

    @State private var editing: SymptomEntry?
    @State private var showsNotEnoughData = false
    /// Input built from today's data; for the report's day count.
    @State private var currentInput: AnalysisInput?

    private var activePeriod: DigestionTrackingPeriod? { periods.first { $0.end == nil } }
    private var analysis: DigestionAnalysisService { services.digestion }

    private var symptomsByDay: [(day: Date, entries: [SymptomEntry])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: symptoms) { cal.startOfDay(for: $0.onset) }
        return groups.keys.sorted(by: >).map { day in
            (day, groups[day]!.sorted { $0.onset > $1.onset })
        }
    }

    var body: some View {
        List {
            Section("Status") {
                if let period = activePeriod {
                    LabeledContent("Tracking since", value: period.start.formatted(date: .abbreviated, time: .omitted))
                    LabeledContent("Days with symptoms logged", value: "\(loggedDays(in: period))")
                } else {
                    Text("Tracking is off. Turn it on in Settings, from the Focus tab.")
                        .foregroundStyle(.secondary)
                }
                NavigationLink("How this works") { DigestionHowItWorksView() }
            }

            resultSections

            if symptoms.isEmpty {
                Section {
                    Text("No symptoms logged yet.")
                        .foregroundStyle(.secondary)
                } header: {
                    symptomLogTitle
                }
            }
            ForEach(Array(symptomsByDay.enumerated()), id: \.element.day) { index, group in
                Section {
                    ForEach(group.entries) { entry in
                        Button { editing = entry } label: { row(entry) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) {
                                    services.deleteSymptom(entry)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 10) {
                        if index == 0 { symptomLogTitle }
                        Text(dayTitle(group.day))
                    }
                }
            }

            Section {
                Text(DigestionPresentation.disclaimer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Digestion Insights")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { exportMenu }
        }
        .sheet(item: $editing) { entry in
            LogSymptomSheet(existing: entry)
        }
        .task(id: symptoms.count) {
            currentInput = analysis.buildInput()
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultSections: some View {
        if let result = analysis.lastGoodResult {
            let sections = DigestionPresentation.sections(for: result)
            Section {
                if let line = DigestionPresentation.lastRunLine(latest: analysis.latestRun, lastGood: analysis.lastGoodRun) {
                    Text(line).font(.footnote).foregroundStyle(.secondary)
                }
                if sections.allSatisfy({ $0.level == .notEnoughData }) {
                    Text("Nothing to show yet. Keep logging meals and symptoms; patterns need weeks to months of data.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Results")
            }
            ForEach(sections) { section in
                if section.startsCollapsed {
                    Section {
                        DisclosureGroup("\(section.title) (\(section.rows.count))", isExpanded: $showsNotEnoughData) {
                            ForEach(section.rows) { resultRow($0, result: result) }
                        }
                    }
                } else {
                    Section(section.title) {
                        ForEach(section.rows) { resultRow($0, result: result) }
                    }
                }
            }
        } else {
            Section("Results") {
                if let line = DigestionPresentation.lastRunLine(latest: analysis.latestRun, lastGood: nil) {
                    Text(line).font(.footnote).foregroundStyle(.secondary)
                }
                Text("Results appear once there is enough data. Analysis runs overnight while your iPhone charges.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func resultRow(_ row: DigestionPresentation.Row, result: AnalysisResult) -> some View {
        NavigationLink {
            if let feature = result.features.first(where: { $0.featureID == row.featureID }) {
                DigestionFeatureDetailView(feature: feature, input: analysis.lastGoodInput)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name)
                        Text(row.kindLabel).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let confidence = row.confidenceText {
                        Text(confidence).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    DigestionLevelBadge(level: row.level)
                    if let lag = row.lagText {
                        Text(lag).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let confounded = row.confoundedText {
                    Text(confounded).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Export (B15)

    private var exportMenu: some View {
        Menu {
            ShareLink(
                item: DigestionReportDocument(report: report),
                preview: SharePreview("Digestion Insights report")
            ) {
                Label("Doctor report (PDF)", systemImage: "doc.richtext")
            }
            if let export = analysisExport {
                ShareLink(
                    item: DigestionAnalysisDataFile(export: export),
                    preview: SharePreview("Digestion Insights analysis data")
                ) {
                    Label("Analysis data (JSON)", systemImage: "curlybraces")
                }
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
    }

    private var report: DigestionPresentation.Report {
        DigestionPresentation.report(
            periods: periods,
            symptoms: symptoms,
            currentInput: currentInput,
            result: analysis.lastGoodResult,
            resultDate: analysis.lastGoodRun.map { $0.finishedAt ?? $0.startedAt },
            now: .now
        )
    }

    private var analysisExport: DigestionAnalysisExport? {
        guard let input = analysis.lastGoodInput, let result = analysis.lastGoodResult else { return nil }
        return DigestionAnalysisExport(
            exportedAt: .now,
            note: "Exact input and result of the last good Digestion Insights run. Run DigestionAnalysis.run(input) with the same engine build to reproduce the result.",
            input: input,
            result: result
        )
    }

    // MARK: - Symptom log

    /// Group title above the first day, so the log reads apart from the results.
    private var symptomLogTitle: some View {
        Text("Symptom log")
            .font(.title3.weight(.semibold))
            // `Color.primary`, not `.primary`: headers resolve `.primary` to their own grey.
            .foregroundStyle(Color.primary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }

    private func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private func row(_ entry: SymptomEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.kind?.label ?? entry.kindRaw)
                if let level = entry.level, entry.kind?.hasLevelChoice == true {
                    Text(level.label).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(entry.onset.formatted(date: .omitted, time: .shortened))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func loggedDays(in period: DigestionTrackingPeriod) -> Int {
        let cal = Calendar.current
        return Set(symptoms.filter { $0.onset >= period.start }.map { cal.startOfDay(for: $0.onset) }).count
    }
}
