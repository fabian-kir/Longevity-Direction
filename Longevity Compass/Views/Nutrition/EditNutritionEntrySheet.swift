import SwiftUI

/// Edit a previously logged nutrition entry. Photo entries expose the AI fingerprint
/// (categories, plant ingredients, notes) so the user can fix miscategorisations.
/// Any entry with a portion or per-100 g estimates can change its portion; the
/// nutrients scale with it.
struct EditNutritionEntrySheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    let entry: NutritionEntry

    @State private var date: Date = .now
    @State private var productName: String = ""
    @State private var items: [MealFingerprint.Item] = []
    @State private var plantIngredients: [String] = []
    @State private var notes: String = ""
    @State private var newPlantText: String = ""
    @State private var portionGrams: Double = 0
    @State private var profile: IngredientProfile = .emptyPhoto
    @State private var isSaving = false

    private var isFingerprint: Bool { entry.fingerprint != nil }

    private var availableCategoriesToAdd: [MealCategory] {
        let present = Set(items.map(\.category))
        return MealCategory.allCases.filter { !present.contains($0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Date") {
                    DatePicker(
                        "Logged at",
                        selection: $date,
                        in: ...Date.now,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }

                Section("Title") {
                    TextField("Meal name", text: $productName)
                }
                if entry.canRescalePortion {
                    Section {
                        WholeNumberFieldRow(
                            title: "Portion",
                            unit: "g",
                            placeholder: entry.fingerprint?.typicalServingGrams.map { "\(Int($0)) g" } ?? "g",
                            value: $portionGrams
                        )
                    } footer: {
                        Text("Calories, macros and fibre scale with the portion.")
                    }
                }
                if isFingerprint {
                    fingerprintSections
                }
                if entry.source == .photo {
                    profileSections
                }
            }
            .navigationTitle("Edit entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving)
                }
            }
            .onAppear { load() }
        }
    }

    // MARK: - Fingerprint editor

    @ViewBuilder
    private var fingerprintSections: some View {
        Section {
            if items.isEmpty {
                Text("No categories. Add one below.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(items, id: \.category) { item in
                    CategoryEditRow(
                        category: item.category,
                        fraction: binding(for: item.category)
                    )
                }
                .onDelete { offsets in
                    items.remove(atOffsets: offsets)
                }
            }
            if !availableCategoriesToAdd.isEmpty {
                Menu {
                    ForEach(availableCategoriesToAdd) { cat in
                        Button {
                            items.append(MealFingerprint.Item(category: cat, plateFraction: 0.1))
                        } label: {
                            Label(cat.displayLabel, systemImage: cat.systemImage)
                        }
                    }
                } label: {
                    Label("Add category", systemImage: "plus.circle")
                }
            }
        } header: {
            Text("Categories on plate")
        } footer: {
            Text("Plate fractions don't need to sum to 100%. They're a coarse estimate.")
        }

        Section {
            ForEach(plantIngredients, id: \.self) { name in
                Text(name)
            }
            .onDelete { offsets in
                plantIngredients.remove(atOffsets: offsets)
            }
            HStack {
                TextField("Add ingredient", text: $newPlantText)
                    .textInputAutocapitalization(.never)
                    .onSubmit { addPlant() }
                Button("Add") { addPlant() }
                    .disabled(newPlantText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Plant ingredients (\(plantIngredients.count))")
        } footer: {
            Text("Distinct plant names — drives the \"30 plants per week\" tally.")
        }

        Section("AI notes") {
            TextEditor(text: $notes)
                .frame(minHeight: 80)
        }
    }

    // MARK: - Allergens and free-from

    @ViewBuilder
    private var profileSections: some View {
        Section {
            ForEach(EUAllergen.allCases) { allergen in
                Toggle(isOn: allergenBinding(allergen)) {
                    HStack {
                        Text(allergen.label)
                        if profile.source(of: allergen) == .ai {
                            SourceBadge(text: "AI")
                        }
                    }
                }
            }
        } header: {
            Text("Allergens")
        } footer: {
            Text("AI can be wrong. Tick what the meal contained, untick what it did not.")
        }

        Section("Free from") {
            ForEach(FreeFromLabel.allCases) { label in
                Toggle(label.label, isOn: freeFromBinding(label))
            }
        }
    }

    private func allergenBinding(_ allergen: EUAllergen) -> Binding<Bool> {
        Binding(
            get: { profile.contains(allergen) },
            set: { profile = profile.settingAllergen(allergen, present: $0) }
        )
    }

    private func freeFromBinding(_ label: FreeFromLabel) -> Binding<Bool> {
        Binding(
            get: { profile.isFree(from: label) },
            set: { profile = profile.settingFreeFrom(label, present: $0) }
        )
    }

    private func binding(for category: MealCategory) -> Binding<Double> {
        Binding(
            get: { items.first(where: { $0.category == category })?.plateFraction ?? 0 },
            set: { newValue in
                if let idx = items.firstIndex(where: { $0.category == category }) {
                    items[idx] = MealFingerprint.Item(category: category, plateFraction: newValue)
                }
            }
        )
    }

    // MARK: - Logic

    private func load() {
        date = entry.date
        productName = entry.productName ?? ""
        portionGrams = entry.portionGrams ?? 0
        profile = entry.ingredientProfile ?? .emptyPhoto
        if let fp = entry.fingerprint {
            items = fp.items
            plantIngredients = fp.plantIngredients
            notes = fp.aiNotes ?? entry.aiNotes ?? ""
        } else {
            notes = entry.aiNotes ?? ""
        }
    }

    private func addPlant() {
        let trimmed = newPlantText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !plantIngredients.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            plantIngredients.append(trimmed)
        }
        newPlantText = ""
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        entry.date = date

        if let fingerprint = entry.fingerprint {
            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedFraction = items.map {
                MealFingerprint.Item(
                    category: $0.category,
                    plateFraction: max(0, min(1, $0.plateFraction))
                )
            }
            let trimmedTitle = productName.trimmingCharacters(in: .whitespacesAndNewlines)
            let updated = fingerprint.edited(
                items: cleanedFraction,
                plantIngredients: plantIngredients,
                aiNotes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                title: trimmedTitle.isEmpty ? nil : trimmedTitle
            )
            entry.productName = trimmedTitle.isEmpty ? nil : trimmedTitle
            if let data = try? JSONEncoder().encode(updated),
               let json = String(data: data, encoding: .utf8) {
                entry.fingerprintJSON = json
            }
            entry.aiNotes = updated.aiNotes
        } else {
            let trimmedName = productName.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.productName = trimmedName.isEmpty ? nil : trimmedName
        }

        // An untouched legacy entry stays without a profile (unknown).
        if entry.source == .photo, entry.ingredientProfile != nil || profile != .emptyPhoto {
            entry.ingredientProfile = profile
        }

        if portionGrams > 0 && portionGrams != entry.portionGrams {
            entry.rescale(toPortionGrams: portionGrams)
        }

        Task {
            await services.refreshAfterEdit()
            dismiss()
        }
    }
}

private struct CategoryEditRow: View {
    let category: MealCategory
    @Binding var fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: category.systemImage)
                    .frame(width: 22)
                    .foregroundStyle(category.isAvoid ? .orange : .secondary)
                Text(category.displayLabel)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(round(fraction * 100)))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $fraction, in: 0...1, step: 0.05)
        }
        .padding(.vertical, 2)
    }
}
