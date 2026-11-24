import Foundation
import Network
import UIKit

/// Disk-backed queue of meal photos awaiting analysis. Used when the user snaps a meal
/// while offline (or when the AI call fails transiently). Retries when connectivity returns.
@Observable
@MainActor
final class PendingMealQueue {

    struct PendingMeal: Codable, Identifiable {
        let id: UUID
        let imageFileName: String
        let capturedAt: Date
        var attempts: Int
        /// Why the last attempt failed. Optional so older manifests still decode.
        var lastError: String?
    }

    private(set) var pending: [PendingMeal] = []
    private(set) var isOnline: Bool = true
    private(set) var isProcessing: Bool = false
    /// The meal being analysed right now, so the pending list can mark it.
    private(set) var processingID: UUID?
    /// False until the network monitor reports its first path. Meals left over
    /// from an earlier launch are processed then, not before we know we're online.
    private var hasCheckedPath = false

    private let openRouter: OpenRouterClient
    private let onEntryReady: (NutritionEntry) async -> Void

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "meal.queue.monitor")
    private let fileManager = FileManager.default

    static let maxAttempts = 5

    /// False while the user hasn't allowed sending meal photos to the AI provider.
    /// Queued photos then wait on the device and are never uploaded.
    var isAISharingAllowed: Bool { openRouter.consent.isGranted }

    init(openRouter: OpenRouterClient, onEntryReady: @escaping (NutritionEntry) async -> Void) {
        self.openRouter = openRouter
        self.onEntryReady = onEntryReady
        loadManifest()
        startMonitor()
    }

    deinit {
        monitor.cancel()
    }

    // MARK: - Enqueue

    func enqueue(image: UIImage, capturedAt: Date = .now) {
        guard let jpeg = image.jpegForAnalysis() else { return }
        let id = UUID()
        let fileName = "\(id.uuidString).jpg"
        let url = imageURL(for: fileName)
        do {
            try ensureDirectoryExists()
            try jpeg.write(to: url, options: .atomic)
        } catch {
            return
        }
        let meal = PendingMeal(id: id, imageFileName: fileName, capturedAt: capturedAt, attempts: 0)
        pending.append(meal)
        saveManifest()

        if isOnline {
            Task { await processQueue() }
        }
    }

    // MARK: - Manage

    /// User-initiated retry. Also retries meals that used up their automatic attempts.
    func retryAll() async {
        await processQueue(includeExhausted: true)
    }

    /// Drops a queued meal and its photo without logging it.
    func discard(_ meal: PendingMeal) {
        remove(meal)
    }

    func image(for meal: PendingMeal) -> UIImage? {
        UIImage(contentsOfFile: imageURL(for: meal.imageFileName).path)
    }

    // MARK: - Process

    /// Meals that failed `maxAttempts` times are skipped unless `includeExhausted`
    /// is set; they stay queued until the user retries or discards them.
    func processQueue(includeExhausted: Bool = false) async {
        guard !isProcessing else { return }
        guard isOnline else { return }
        // Photos stay on the device until the user allows sharing with AI.
        guard isAISharingAllowed else { return }
        isProcessing = true
        defer {
            isProcessing = false
            processingID = nil
        }

        // Re-read `pending` each round: meals can be queued or discarded while
        // a request is in flight.
        var tried: Set<UUID> = []
        while let queued = pending.first(where: {
            !tried.contains($0.id) && (includeExhausted || $0.attempts < Self.maxAttempts)
        }) {
            tried.insert(queued.id)
            // Sharing withdrawn mid-run: stop before sending the next photo.
            guard isAISharingAllowed else { break }
            guard let image = image(for: queued) else {
                remove(queued)
                continue
            }
            processingID = queued.id
            update(queued.id) { $0.attempts += 1 }

            do {
                let analysis = try await MealAnalysisPipeline.analyze(image: image, openRouter: openRouter)
                // Discarded while the request was running: don't log it.
                guard let meal = pending.first(where: { $0.id == queued.id }) else { continue }
                let storedImage = MealImageStore.ingest(jpegAt: imageURL(for: meal.imageFileName))
                // Nobody confirms a weight for a queued meal, so the AI's typical
                // serving stands in. The user can correct the portion later in
                // the edit sheet; without it the meal would count as 0 kcal.
                let fingerprint = analysis.fingerprint
                let entry = NutritionEntry.fromFingerprint(
                    analysis,
                    capturedAt: meal.capturedAt,
                    portionGrams: fingerprint.hasMacroEstimates ? fingerprint.typicalServingGrams : nil,
                    imageFileName: storedImage
                )
                await onEntryReady(entry)
                remove(meal)
            } catch {
                update(queued.id) { $0.lastError = error.localizedDescription }
                // Stop processing this round; try again on next connectivity event.
                break
            }
        }
    }

    // MARK: - Storage helpers

    private func directory() -> URL {
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("PendingMeals", isDirectory: true)
    }

    private func ensureDirectoryExists() throws {
        let dir = directory()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func imageURL(for fileName: String) -> URL {
        directory().appendingPathComponent(fileName)
    }

    private func manifestURL() -> URL {
        directory().appendingPathComponent("manifest.json")
    }

    private func loadManifest() {
        do {
            try ensureDirectoryExists()
            let data = try Data(contentsOf: manifestURL())
            let decoded = try JSONDecoder().decode([PendingMeal].self, from: data)
            pending = decoded
        } catch {
            pending = []
        }
    }

    private func saveManifest() {
        do {
            try ensureDirectoryExists()
            let data = try JSONEncoder().encode(pending)
            try data.write(to: manifestURL(), options: .atomic)
        } catch {
            // Persistence failure is non-fatal — queue stays in memory.
        }
    }

    private func update(_ id: UUID, _ change: (inout PendingMeal) -> Void) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        change(&pending[index])
        saveManifest()
    }

    private func remove(_ meal: PendingMeal) {
        pending.removeAll { $0.id == meal.id }
        try? fileManager.removeItem(at: imageURL(for: meal.imageFileName))
        saveManifest()
    }

    // MARK: - Network monitor

    private func startMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = (path.status == .satisfied)
            Task { @MainActor in
                guard let self else { return }
                let wasOffline = !self.isOnline
                let isFirstPath = !self.hasCheckedPath
                self.isOnline = online
                self.hasCheckedPath = true
                if online && (wasOffline || isFirstPath) && !self.pending.isEmpty {
                    await self.processQueue()
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }

}

extension NutritionEntry {
    /// Builds a photo-source entry from an AI fingerprint analysis.
    /// Pass `portionGrams` to scale the per-100 g macro estimates into absolute values;
    /// nil leaves macro fields empty.
    @MainActor static func fromFingerprint(
        _ analysis: MealFingerprintAnalysis,
        capturedAt: Date,
        portionGrams: Double? = nil,
        imageFileName: String? = nil
    ) -> NutritionEntry {
        let fp = analysis.fingerprint
        let json: String? = {
            guard let data = try? JSONEncoder().encode(fp) else { return nil }
            return String(data: data, encoding: .utf8)
        }()
        let title = fp.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scaled = portionGrams.flatMap { fp.scaledMacros(toGrams: $0) }
        return NutritionEntry(
            date: capturedAt,
            source: .photo,
            rawInput: "",
            productName: (title?.isEmpty == false) ? title : nil,
            caloriesKcal: scaled?.kcal,
            portionGrams: portionGrams,
            proteinGrams: scaled?.protein,
            fiberGrams: scaled?.fiber,
            carbsGrams: scaled?.carbs,
            fatGrams: scaled?.fat,
            saturatedFatGrams: nil,
            addedSugarGrams: nil,
            sodiumMilligrams: nil,
            isFattyFish: nil,
            leafyGreenServings: nil,
            ultraProcessedScore: nil,
            aiNotes: fp.aiNotes,
            modelUsed: analysis.model,
            inputTokens: analysis.inputTokens,
            outputTokens: analysis.outputTokens,
            costUSD: analysis.costUSD,
            fingerprintJSON: json,
            imageFileName: imageFileName,
            ingredientProfile: IngredientProfile.fromFingerprint(fp, taxonomy: .shared)
        )
    }
}
