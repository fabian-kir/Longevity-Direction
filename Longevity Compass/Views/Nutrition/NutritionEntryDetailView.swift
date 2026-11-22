import SwiftUI
import UIKit

struct NutritionEntryDetailView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Bindable var entry: NutritionEntry

    @State private var showDeleteConfirm = false
    @State private var showEditSheet = false
    @State private var photo: UIImage?

    var body: some View {
        Form {
            if let photo {
                Section {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section("Source") {
                LabeledContent {
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                } label: {
                    Label(entry.source.displayLabel, systemImage: entry.source.systemImage)
                }
                if !entry.rawInput.isEmpty {
                    Text(entry.rawInput).font(.subheadline)
                }
                if let notes = entry.aiNotes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI notes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(notes).font(.footnote)
                    }
                }
            }

            if let profile = entry.ingredientProfile {
                switch entry.source {
                case .barcode: declaredProfileSection(profile)
                case .photo:   photoProfileSection(profile)
                }
            }

            if let fp = entry.fingerprint {
                fingerprintSections(fp)
                if hasMacros { macroSection }
            } else if hasMacros {
                macroSection
            }

            Section {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete entry", systemImage: "trash")
                }
            }
        }
        .navigationTitle(entry.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { showEditSheet = true }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            EditNutritionEntrySheet(entry: entry)
        }
        .alert("Delete this entry?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                Task {
                    await services.deleteNutritionEntry(entry)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: entry.imageFileName) {
            photo = MealImageStore.image(for: entry.imageFileName)
        }
    }

    private var hasMacros: Bool {
        entry.caloriesKcal != nil || entry.portionGrams != nil || entry.proteinGrams != nil || entry.fiberGrams != nil
    }

    @ViewBuilder
    private func fingerprintSections(_ fp: MealFingerprint) -> some View {
        Section("Categories on plate") {
            if fp.items.isEmpty {
                Text("No categories detected.").foregroundStyle(.secondary).font(.subheadline)
            } else {
                ForEach(fp.items.sorted { $0.plateFraction > $1.plateFraction }, id: \.category) { item in
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
                Text(fp.plantIngredients.joined(separator: ", ")).font(.subheadline)
            }
        }
    }

    /// Open Food Facts label data, read-only.
    private func declaredProfileSection(_ profile: IngredientProfile) -> some View {
        Section {
            labelRow("Contains", profile.allergens.map(\.allergen.label))
            labelRow("May contain traces", profile.traces.map(\.label))
            labelRow("Free from", profile.freeFrom.map(\.label.label))
        } header: {
            Text("Allergens & labels")
        } footer: {
            OpenFoodFactsAttribution()
        }
    }

    /// AI-detected or user-reviewed data of a photo meal.
    private func photoProfileSection(_ profile: IngredientProfile) -> some View {
        let taxonomy = IngredientTaxonomy.shared
        let matched = profile.ingredientIDs.map { taxonomy.name(of: $0) ?? $0 }
        return Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Contains").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if profile.allergens.isEmpty {
                    Text("None marked").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(profile.allergens, id: \.allergen) { mark in
                        HStack {
                            Text(mark.allergen.label).font(.subheadline)
                            Spacer()
                            SourceBadge(text: mark.source == .user ? "You" : "AI")
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Ingredients").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if matched.isEmpty && profile.unmatchedIngredientNames.isEmpty {
                    Text("None detected").font(.subheadline).foregroundStyle(.secondary)
                }
                if !matched.isEmpty {
                    Text(matched.joined(separator: ", ")).font(.subheadline)
                }
                if !profile.unmatchedIngredientNames.isEmpty {
                    Text(profile.unmatchedIngredientNames.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            labelRow("Free from", profile.freeFrom.map(\.label.label))
        } header: {
            Text("Allergens & ingredients")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI can be wrong. Grey ingredients are not matched to the Open Food Facts list.")
                OpenFoodFactsAttribution()
            }
        }
    }

    private func labelRow(_ title: String, _ values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(values.isEmpty ? "None listed" : values.joined(separator: ", "))
                .font(.subheadline)
                .foregroundStyle(values.isEmpty ? .secondary : .primary)
        }
    }

    private var macroSection: some View {
        Section("Nutrients") {
            if let kcal = entry.caloriesKcal {
                row("Calories", String(format: "%.0f kcal", kcal))
            }
            row("Portion",         entry.portionGrams.map { String(format: "%.0f g", $0) })
            row("Protein",         entry.proteinGrams.map { String(format: "%.0f g", $0) })
            row("Fibre",           entry.fiberGrams.map { String(format: "%.0f g", $0) })
            row("Carbs",           entry.carbsGrams.map { String(format: "%.0f g", $0) })
            row("Fat",             entry.fatGrams.map { String(format: "%.0f g", $0) })
            row("Saturated fat",   entry.saturatedFatGrams.map { String(format: "%.0f g", $0) })
            row("Added sugar",     entry.addedSugarGrams.map { String(format: "%.0f g", $0) })
            row("Sodium",          entry.sodiumMilligrams.map { String(format: "%.0f mg", $0) })
        }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        LabeledContent(label) {
            Text(value ?? "—").monospacedDigit()
        }
    }
}

/// Small capsule that says who set a value ("AI" or "You").
struct SourceBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(.tertiarySystemFill), in: Capsule())
    }
}
