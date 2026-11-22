import SwiftUI
import UIKit

/// Presented after a meal photo is captured. Runs the analysis pipeline,
/// shows the result, and saves the entry — or queues it if offline.
struct PostCaptureSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    let image: UIImage
    let capturedAt: Date
    let onFinish: (Outcome) -> Void

    enum Outcome {
        case saved(title: String)
        case queued
        case cancelled
        case failed(String)
    }

    private enum Phase {
        case analyzing
        case aiFingerprint(MealFingerprintAnalysis)
        case offline(String)
        case failed(String)
    }

    @State private var phase: Phase = .analyzing
    @State private var mealWeightGrams: Double = 350
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            onFinish(.cancelled)
                            dismiss()
                        }
                    }
                }
        }
        .task { await analyze() }
    }

    private var title: String {
        switch phase {
        case .analyzing:        "Analysing meal…"
        case .aiFingerprint:    "Confirm meal"
        case .offline:          "Saved for later"
        case .failed:           "Could not analyse"
        }
    }

    // MARK: - Content per phase

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .analyzing:
            analyzingView
        case .aiFingerprint(let analysis):
            fingerprintConfirm(analysis: analysis)
        case .offline(let message):
            offlineView(message: message)
        case .failed(let message):
            failedView(message: message)
        }
    }

    private var analyzingView: some View {
        VStack(spacing: 20) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal)
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.large)
                Text("Identifying foods and portions…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity)
    }

    private func offlineView(message: String) -> some View {
        ContentUnavailableView {
            Label("You’re offline", systemImage: "wifi.slash")
        } description: {
            Text(message)
        } actions: {
            Button("Done") {
                onFinish(.queued)
                dismiss()
            }
            .buttonStyle(.glassProminent)
        }
    }

    private func failedView(message: String) -> some View {
        ContentUnavailableView {
            Label("Something went wrong", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            HStack(spacing: 10) {
                Button("Retry") {
                    Task { await analyze() }
                }
                .buttonStyle(.glass)
                Button("Save for later") {
                    services.pendingMeals.enqueue(image: image, capturedAt: capturedAt)
                    onFinish(.queued)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
            }
        }
    }

    private func fingerprintConfirm(analysis: MealFingerprintAnalysis) -> some View {
        let fp = analysis.fingerprint
        let sortedItems = fp.items.sorted { $0.plateFraction > $1.plateFraction }
        return Form {
            Section {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            if let title = fp.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                Section("Meal") {
                    Text(title).font(.headline)
                }
            }
            Section("Categories on plate") {
                if sortedItems.isEmpty {
                    Text("No categories detected.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(sortedItems, id: \.category) { item in
                        HStack {
                            Image(systemName: item.category.systemImage)
                                .frame(width: 22)
                                .foregroundStyle(item.category.isAvoid ? .orange : .secondary)
                            Text(item.category.displayLabel)
                            Spacer()
                            Text("\(Int(round(item.plateFraction * 100)))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            if !fp.plantIngredients.isEmpty {
                Section("Plant ingredients (\(fp.plantIngredients.count))") {
                    Text(fp.plantIngredients.joined(separator: ", "))
                        .font(.subheadline)
                }
            }
            if fp.allergens != nil || fp.ingredients != nil {
                Section {
                    detectedRow("Allergens", EUAllergen.parse(fp.allergens ?? []).map(\.label))
                    detectedRow("Ingredients", fp.ingredients ?? [])
                } header: {
                    Text("Allergens & ingredients")
                } footer: {
                    Text("AI can be wrong. Check the meal later if you cooked it.")
                }
            }
            if let notes = fp.aiNotes, !notes.isEmpty {
                Section("AI notes") { Text(notes).font(.footnote) }
            }
            if fp.hasMacroEstimates {
                Section {
                    HStack {
                        Text("Estimated weight")
                        Spacer()
                        TextField("g", value: $mealWeightGrams, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 80)
                        Text("g")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Adjust to match how much you ate. Macros scale accordingly.")
                }
                if let scaled = fp.scaledMacros(toGrams: mealWeightGrams) {
                    Section("Estimated macros at \(Int(mealWeightGrams)) g") {
                        row("Calories", String(format: "%.0f kcal", scaled.kcal))
                        row("Protein",  String(format: "%.0f g",    scaled.protein))
                        row("Carbs",    String(format: "%.0f g",    scaled.carbs))
                        row("Fat",      String(format: "%.0f g",    scaled.fat))
                        if let fiber = scaled.fiber {
                            row("Fibre", String(format: "%.0f g", fiber))
                        }
                    }
                }
            }
            FormPrimaryButton(title: "Save entry", isBusy: isSaving) {
                saveFingerprint(analysis: analysis)
            }
        }
    }

    private func detectedRow(_ title: String, _ values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(values.isEmpty ? "None detected" : values.joined(separator: ", "))
                .font(.subheadline)
                .foregroundStyle(values.isEmpty ? .secondary : .primary)
        }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        LabeledContent(label) {
            Text(value ?? "—").monospacedDigit()
        }
    }

    // MARK: - Pipeline

    private func analyze() async {
        phase = .analyzing
        do {
            let analysis = try await MealAnalysisPipeline.analyze(image: image, openRouter: services.openRouter)
            phase = .aiFingerprint(analysis)
            mealWeightGrams = analysis.fingerprint.typicalServingGrams ?? 350
        } catch {
            if isNetworkRelated(error) {
                services.pendingMeals.enqueue(image: image, capturedAt: capturedAt)
                phase = .offline("No network — we’ll analyse this when you’re back online.")
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func isNetworkRelated(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return true }
        if let mae = error as? MealAnalysisError {
            switch mae {
            case .noNetwork: return true
            case .noUsableResult(let underlying):
                let u = underlying as NSError
                return u.domain == NSURLErrorDomain
            }
        }
        return false
    }

    // MARK: - Save

    private func saveFingerprint(analysis: MealFingerprintAnalysis) {
        guard !isSaving else { return }
        isSaving = true
        Task {
            let imageFileName = MealImageStore.save(image: image)
            let weight = analysis.fingerprint.hasMacroEstimates ? mealWeightGrams : nil
            let entry = NutritionEntry.fromFingerprint(
                analysis,
                capturedAt: capturedAt,
                portionGrams: weight,
                imageFileName: imageFileName
            )
            await services.recordNutritionEntry(entry)
            let aiTitle = analysis.fingerprint.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let fallback = analysis.fingerprint.plantIngredients.prefix(3).joined(separator: ", ")
            let title = !aiTitle.isEmpty ? aiTitle : (fallback.isEmpty ? "meal" : fallback)
            onFinish(.saved(title: title))
            dismiss()
        }
    }
}
