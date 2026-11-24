import SwiftUI
import SwiftData

struct AddEditExerciseView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var services

    private let existing: ExerciseDef?

    @State private var name: String
    @State private var photoData: Data?
    @State private var existingSymbol: String

    @State private var primaryMuscles: [MuscleGroup]
    @State private var secondaryMuscles: [MuscleGroup]
    @State private var isClassifying = false

    // Session-only usage tracking (accumulates across regenerations in this sheet).
    @State private var sessionModel: String?
    @State private var sessionInputTokens: Int = 0
    @State private var sessionOutputTokens: Int = 0
    @State private var sessionCostUSD: Double = 0

    @State private var isGenerating = false
    @State private var generationError: String?
    @FocusState private var nameFocused: Bool

    @State private var consentRequest: AIConsentRequest?
    /// "Not now" in this sheet: don't ask again on blur or save.
    @State private var declinedAISharing = false
    /// Save was tapped while the consent sheet was up or about to show:
    /// save once the user has answered, whatever the answer.
    @State private var saveAfterConsent = false

    init(existing: ExerciseDef? = nil) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _photoData = State(initialValue: existing?.photoData)
        _existingSymbol = State(initialValue: existing?.sfSymbol ?? "dumbbell.fill")
        _primaryMuscles = State(initialValue: existing?.primaryMuscles ?? [])
        _secondaryMuscles = State(initialValue: existing?.secondaryMuscles ?? [])
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Exercise name", text: $name)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit { triggerAutoGenIfNeeded() }
            }

            Section {
                HStack(alignment: .top, spacing: 14) {
                    iconPreview
                    VStack(alignment: .leading, spacing: 6) {
                        statusLine
                        if sessionCostUSD > 0 {
                            Text(String(format: "This session: %d in + %d out tokens · $%.4f",
                                        sessionInputTokens, sessionOutputTokens, sessionCostUSD))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Icon")
            } footer: {
                Text("Auto-generated via OpenRouter's Auto mode (\(HealthThresholds.OpenRouter.autoModel)), which picks the image model per request. If generation is skipped or fails, the exercise saves without an image and a default symbol is used.")
            }

            Section {
                musclesContent
            } header: {
                Text("Muscles worked")
            } footer: {
                Text("Auto-detected from the exercise name via OpenRouter. Runs once, alongside icon generation.")
            }
        }
        .navigationTitle(existing == nil ? "New Exercise" : "Edit Exercise")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: nameFocused) { _, focused in
            if !focused { triggerAutoGenIfNeeded() }
        }
        .aiConsentSheet($consentRequest)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await saveTapped() }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isGenerating)
            }
            if existing == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var iconPreview: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let data = photoData, let img = UIImage(data: data) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                        .overlay {
                            Image(systemName: existingSymbol)
                                .font(.title)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 84, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if isGenerating {
                    ZStack {
                        Color.black.opacity(0.45)
                        ProgressView().tint(.white)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }

            if !isGenerating && services.openRouter.hasAPIKey && !name.trimmingCharacters(in: .whitespaces).isEmpty {
                Button {
                    // An explicit tap asks again, even after "Not now".
                    withAISharing(askAgain: true) {
                        Task { await generate() }
                        Task { await classifyMusclesIfNeeded() }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(4)
                .accessibilityLabel("Regenerate icon")
            }
        }
    }

    @ViewBuilder
    private var musclesContent: some View {
        if isClassifying && primaryMuscles.isEmpty {
            HStack(spacing: 8) {
                ProgressView()
                Text("Detecting muscles…").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        } else if primaryMuscles.isEmpty && secondaryMuscles.isEmpty {
            Text(muscleEmptyHint)
                .font(.caption).foregroundStyle(.secondary)
        } else {
            FlowLayout(spacing: 6) {
                ForEach(primaryMuscles) { MuscleChip(group: $0, emphasized: true) }
                ForEach(secondaryMuscles) { MuscleChip(group: $0, emphasized: false) }
            }
            .padding(.vertical, 2)
        }
    }

    private var muscleEmptyHint: String {
        if !services.openRouter.hasAPIKey {
            "Add an OpenRouter API key in Settings to auto-detect muscle groups."
        } else if !isAISharingAllowed {
            "Sharing with AI is off, so muscle groups aren't detected."
        } else if name.trimmingCharacters(in: .whitespaces).isEmpty {
            "Enter a name — muscle groups are detected automatically."
        } else {
            "No muscles detected yet. They're tagged when the icon is generated."
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if isGenerating {
            Text("Generating icon…").font(.subheadline).foregroundStyle(.secondary)
        } else if let err = generationError {
            Text(err).font(.caption).foregroundStyle(.red).lineLimit(4)
        } else if photoData != nil {
            Text("Tap the arrow to try a different version.")
                .font(.caption).foregroundStyle(.secondary)
        } else if !services.openRouter.hasAPIKey {
            Text("Add an OpenRouter API key in Settings to auto-generate icons. Saves without an icon for now.")
                .font(.caption).foregroundStyle(.secondary)
        } else if !isAISharingAllowed && !name.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("Sharing with AI is off, so no icon is generated. Tap the arrow to turn it on.")
                .font(.caption).foregroundStyle(.secondary)
        } else if name.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("Enter a name — an icon will be generated automatically.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Tap Done on the keyboard, or hit Save — an icon will be generated.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Generation

    private var isAISharingAllowed: Bool { services.openRouter.consent.isGranted }

    /// Runs `action` when the user has allowed sharing exercise names with AI.
    /// Otherwise shows the consent sheet once and runs it only on "Allow".
    private func withAISharing(askAgain: Bool = false, _ action: @escaping () -> Void) {
        if isAISharingAllowed {
            action()
            return
        }
        guard askAgain || !declinedAISharing, consentRequest == nil else { return }
        consentRequest = AIConsentRequest(
            onAllow: {
                // Saving generates the icon and muscle groups itself.
                if saveAfterConsent { Task { await saveTapped() } } else { action() }
            },
            onNotNow: {
                declinedAISharing = true
                if saveAfterConsent { Task { await saveTapped() } }
            }
        )
    }

    private func triggerAutoGenIfNeeded() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              services.openRouter.hasAPIKey,
              !isGenerating,
              photoData == nil   // only auto-fire when there's no image yet; regenerate is explicit
        else { return }
        withAISharing {
            Task { await generate() }
            Task { await classifyMusclesIfNeeded() }
        }
    }

    /// One-shot muscle classification. Cheap text call, runs alongside image
    /// generation; skipped once tags exist so name-blur / regenerate don't refire.
    private func classifyMusclesIfNeeded() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              services.openRouter.hasAPIKey,
              isAISharingAllowed,
              !isClassifying,
              primaryMuscles.isEmpty
        else { return }
        isClassifying = true
        defer { isClassifying = false }
        do {
            let result = try await services.openRouter.classifyExerciseMuscles(exerciseName: trimmed)
            // Guard against a late response for a name the user has since changed.
            guard trimmed == name.trimmingCharacters(in: .whitespaces) else { return }
            primaryMuscles = result.primary
            secondaryMuscles = result.secondary
        } catch {
            // Non-critical: exercise still saves without muscle tags.
        }
    }

    private func generate() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isGenerating = true
        generationError = nil
        defer { isGenerating = false }
        do {
            let result = try await services.openRouter.generateExerciseImage(exerciseName: trimmed)
            photoData = result.imageData
            sessionModel = result.model
            sessionInputTokens  += result.inputTokens
            sessionOutputTokens += result.outputTokens
            sessionCostUSD      += result.costUSD
        } catch {
            generationError = error.localizedDescription
        }
    }

    // MARK: - Save

    private func saveTapped() async {
        let wantsAI = photoData == nil || primaryMuscles.isEmpty
        if wantsAI, services.openRouter.hasAPIKey, !isAISharingAllowed, !declinedAISharing {
            // Ask first (or let the sheet the name field opened answer for us),
            // then save either way.
            saveAfterConsent = true
            withAISharing {}
            return
        }
        saveAfterConsent = false
        if photoData == nil, generationError == nil, services.openRouter.hasAPIKey, isAISharingAllowed {
            await generate()
        }
        await classifyMusclesIfNeeded()
        let trimmed = name.trimmingCharacters(in: .whitespaces)

        if let ex = existing {
            ex.name = trimmed
            ex.photoData = photoData
            applySessionUsage(to: ex)
            applyMuscleTags(to: ex)
        } else {
            let def = ExerciseDef(name: trimmed, sfSymbol: existingSymbol, photoData: photoData)
            applySessionUsage(to: def)
            applyMuscleTags(to: def)
            context.insert(def)
        }
        try? context.save()
        await services.refresh()
        dismiss()
    }

    private func applyMuscleTags(to def: ExerciseDef) {
        def.primaryMuscles = primaryMuscles
        def.secondaryMuscles = secondaryMuscles
        if !primaryMuscles.isEmpty || !secondaryMuscles.isEmpty {
            def.musclesClassifiedAt = .now
        }
    }

    private func applySessionUsage(to def: ExerciseDef) {
        guard sessionCostUSD > 0 else { return }
        def.imageModel = sessionModel ?? def.imageModel
        def.imageInputTokens  = (def.imageInputTokens  ?? 0) + sessionInputTokens
        def.imageOutputTokens = (def.imageOutputTokens ?? 0) + sessionOutputTokens
        def.imageCostUSD      = (def.imageCostUSD      ?? 0) + sessionCostUSD
        def.imageGeneratedAt  = .now
    }
}
