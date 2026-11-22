import SwiftUI

struct FoodSearchSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onSaved: (String) -> Void

    @State private var query = ""
    @State private var results: [OpenFoodFactsProduct] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var hasSearched = false

    var body: some View {
        NavigationStack {
            content
                .searchable(
                    text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Product name or brand"
                )
                .onSubmit(of: .search) { Task { await runSearch() } }
                .navigationTitle("Search food")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isSearching {
            ProgressView("Searching…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = errorMessage {
            ContentUnavailableView(
                "Search failed",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if hasSearched && results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if !hasSearched {
            ContentUnavailableView(
                "Search for a product",
                systemImage: "magnifyingglass",
                description: Text("Type a product name or brand, then tap Search.")
            )
        } else {
            List {
                Section {
                    ForEach(results, id: \.barcode) { product in
                        NavigationLink {
                            ProductConfirmView(product: product) { savedTitle in
                                onSaved(savedTitle)
                                dismiss()
                            }
                        } label: {
                            ProductSearchRow(product: product)
                        }
                    }
                } footer: {
                    OpenFoodFactsAttribution()
                }
            }
            .listStyle(.plain)
        }
    }

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            results = try await OpenFoodFactsClient.search(query: trimmed)
            hasSearched = true
        } catch {
            errorMessage = error.localizedDescription
            hasSearched = true
        }
    }
}

// MARK: - List row

private struct ProductSearchRow: View {
    let product: OpenFoodFactsProduct

    var body: some View {
        HStack(spacing: 12) {
            ProductThumbnail(url: product.imageURL, size: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(product.name ?? "Unknown product")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let brand = product.brand {
                    Text(brand)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let kcal = product.kcal100g {
                    Text(String(format: "%.0f kcal / 100 g", kcal))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

}

/// Open Food Facts product photo, or a neutral placeholder.
private struct ProductThumbnail: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    private var placeholder: some View {
        Color(.tertiarySystemFill)
            .overlay(Image(systemName: "fork.knife").foregroundStyle(.secondary))
    }
}

// MARK: - Product confirm

struct DetectedBarcodeProductSheet: View {
    @Environment(\.dismiss) private var dismiss

    let product: OpenFoodFactsProduct
    let detectedAt: Date
    let onSaved: (String) -> Void

    var body: some View {
        NavigationStack {
            ProductConfirmView(
                product: product,
                loggedAt: detectedAt,
                fetchesServingDetails: false,
                onSaved: onSaved
            )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }
}

struct ProductConfirmView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    let loggedAt: Date
    /// Search results lack serving and ingredient data; barcode lookups already have it.
    let fetchesServingDetails: Bool
    let onSaved: (String) -> Void

    private enum PortionMode: Hashable { case grams, servings }

    @State private var product: OpenFoodFactsProduct
    @State private var portionGrams: Double
    @State private var portionMode: PortionMode
    @State private var hasEditedPortion = false
    @State private var isSaving = false
    @State private var detailsTask: Task<OpenFoodFactsProduct?, Never>?

    init(
        product: OpenFoodFactsProduct,
        loggedAt: Date = .now,
        fetchesServingDetails: Bool = true,
        onSaved: @escaping (String) -> Void
    ) {
        self.loggedAt = loggedAt
        self.fetchesServingDetails = fetchesServingDetails
        self.onSaved = onSaved
        self._product = State(initialValue: product)
        self._portionGrams = State(initialValue: product.servingSizeGrams ?? 100)
        self._portionMode = State(initialValue: product.servingSizeGrams == nil ? .grams : .servings)
    }

    private var unit: String { product.servingUnit }

    private var servings: Binding<Double> {
        Binding {
            guard let serving = product.servingSizeGrams, serving > 0 else { return 1 }
            return portionGrams / serving
        } set: { count in
            guard let serving = product.servingSizeGrams else { return }
            portionGrams = count * serving
            hasEditedPortion = true
        }
    }

    var body: some View {
        Form {
            Section("Product") {
                HStack(spacing: 12) {
                    ProductThumbnail(url: product.imageURL, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(product.name ?? "Unknown product")
                            .font(.headline)
                            .lineLimit(2)
                        if let brand = product.brand {
                            Text(brand).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text(product.barcode)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }

            Section {
                if product.servingSizeGrams != nil {
                    Picker("Enter as", selection: $portionMode) {
                        Text(unit == "ml" ? "Millilitres" : "Grams").tag(PortionMode.grams)
                        Text("Servings").tag(PortionMode.servings)
                    }
                    .pickerStyle(.segmented)
                }

                switch portionMode {
                case .grams:
                    HStack {
                        Text(unit == "ml" ? "Millilitres drunk" : "Grams eaten")
                        Spacer()
                        TextField(
                            product.servingSizeGrams.map { "\(Int($0))" } ?? "100",
                            value: $portionGrams,
                            format: .number
                        )
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 120)
                        .onChange(of: portionGrams) { hasEditedPortion = true }
                    }
                case .servings:
                    Stepper(value: servings, in: 0.5...50, step: 0.5) {
                        HStack {
                            Text(servingsText(servings.wrappedValue))
                            Spacer()
                            Text("\(amountText(portionGrams)) \(unit)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

                if let pack = product.packageGrams {
                    Button("Whole pack (\(amountText(pack)) \(unit))") {
                        portionGrams = pack
                        hasEditedPortion = true
                    }
                }
            } header: {
                Text("Portion")
            } footer: {
                if let serving = product.servingSizeGrams {
                    Text("1 serving = \(product.servingLabel ?? "\(amountText(serving)) \(unit)")")
                }
            }

            Section {
                if let v = product.kcal100g   { row("Calories",      String(format: "%.0f kcal", v)) }
                if let v = product.protein100g { row("Protein",       String(format: "%.1f g", v)) }
                if let v = product.carbs100g   { row("Carbs",         String(format: "%.1f g", v)) }
                if let v = product.fat100g     { row("Fat",           String(format: "%.1f g", v)) }
                if let v = product.fiber100g   { row("Fibre",         String(format: "%.1f g", v)) }
                if let v = product.satFat100g  { row("Saturated fat", String(format: "%.1f g", v)) }
                if let v = product.sugars100g  { row("Sugars",        String(format: "%.1f g", v)) }
                if let n = product.novaGroup   { row("NOVA group",    "\(n) / 4") }
            } header: {
                Text("Per 100 g (Open Food Facts)")
            } footer: {
                OpenFoodFactsAttribution()
            }

            FormPrimaryButton(title: "Save entry", isBusy: isSaving) { save() }
        }
        .navigationTitle(product.name ?? "Product")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadServingDetails() }
    }

    private var needsFullProduct: Bool {
        fetchesServingDetails && (
            (product.servingSizeGrams == nil && product.packageGrams == nil)
            || product.ingredientProfile == nil
        )
    }

    /// Search results carry no serving, pack or ingredient data, so fetch the
    /// full product once; saving awaits the same fetch. The portion follows the
    /// new serving unless the user already changed it.
    private func loadServingDetails() async {
        guard needsFullProduct else { return }
        let barcode = product.barcode
        let task = detailsTask ?? Task { try? await OpenFoodFactsClient.lookup(barcode: barcode) }
        detailsTask = task
        guard let full = await task.value else { return }
        if product.ingredientProfile == nil {
            product.ingredientProfile = full.ingredientProfile
        }
        guard product.servingSizeGrams == nil, product.packageGrams == nil,
              full.servingSizeGrams != nil || full.packageGrams != nil
        else { return }
        let profile = product.ingredientProfile
        product = full
        product.ingredientProfile = full.ingredientProfile ?? profile
        if let serving = full.servingSizeGrams, !hasEditedPortion {
            portionGrams = serving
            portionMode = .servings
        }
    }

    private func servingsText(_ count: Double) -> String {
        let number = count.formatted(.number.precision(.fractionLength(0...1)))
        return count == 1 ? "1 serving" : "\(number) servings"
    }

    private func amountText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value).monospacedDigit()
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            // A failed lookup saves the entry without an ingredient profile.
            if product.ingredientProfile == nil { await loadServingDetails() }
            let scaled = product.scaled(toGrams: portionGrams)
            let entry = NutritionEntry(
                date: loggedAt,
                source: .barcode,
                rawInput: product.barcode,
                productName: product.name,
                caloriesKcal: scaled.kcalTotal,
                portionGrams: scaled.portionGrams,
                proteinGrams: scaled.protein,
                fiberGrams: scaled.fiber,
                carbsGrams: scaled.carbs,
                fatGrams: scaled.fat,
                saturatedFatGrams: scaled.saturatedFat,
                addedSugarGrams: scaled.addedSugar,
                sodiumMilligrams: scaled.sodiumMg,
                ultraProcessedScore: product.ultraProcessedScore,
                modelUsed: "openfoodfacts",
                costUSD: 0,
                ingredientProfile: product.ingredientProfile
            )
            await services.recordNutritionEntry(entry)
            onSaved(product.name ?? "product")
            dismiss()
        }
    }
}

/// ODbL attribution shown wherever Open Food Facts data appears.
struct OpenFoodFactsAttribution: View {
    var body: some View {
        Link(destination: URL(string: "https://world.openfoodfacts.org")!) {
            Text("Data © Open Food Facts contributors (ODbL)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
