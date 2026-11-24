import Foundation
import IntervalEngine
import IntervalUI
import SwiftData
import SwiftUI

enum AppTab: Hashable {
    case focus
    case train
    case nutrition
    case bloodwork
    case n4x4

    var tint: Color {
        switch self {
        case .focus:     return .purple
        case .train:     return .orange
        case .nutrition: return .green
        case .bloodwork: return .red
        case .n4x4:      return N4x4Palette.accent
        }
    }
}

@Observable
@MainActor
final class AppServices {
    let store: LocalDataStore
    let healthKit: HealthKitManager
    let notifications: NotificationManager
    let openRouter: OpenRouterClient
    let mealCapture: MealCaptureCoordinator
    /// App-lifetime ownership is required for Watch workout mirroring: HealthKit
    /// can wake the phone in the background before the N4x4 tab exists.
    let n4x4: N4x4SessionModel
    let digestion: DigestionAnalysisService
    var pendingMeals: PendingMealQueue!

    private(set) var healthSnapshot: HealthKitSnapshot = HealthKitSnapshot()
    private(set) var currentResult: PriorityEngine.Result?
    private(set) var nutritionDigest: NutritionDigest?
    private(set) var exerciseImageDigest: ExerciseImageDigest = .empty
    private(set) var bioAge: BioAgeEstimate?
    private(set) var isRefreshing: Bool = false
    private(set) var hasBootstrapped: Bool = false
    /// True while a Digestion Insights tracking period is active. Toolbar and Settings observe this.
    private(set) var isTrackingDigestion: Bool = false

    /// Cross-view navigation hint. Views observe this and update their TabView selection.
    var selectedTab: AppTab = .focus

    init(context: ModelContext) {
        let store = LocalDataStore(context: context)
        self.store = store
        self.isTrackingDigestion = store.activeTrackingPeriod() != nil
        let healthKit = HealthKitManager()
        self.healthKit = healthKit
        self.notifications = NotificationManager()
        self.openRouter = OpenRouterClient()
        self.mealCapture = MealCaptureCoordinator()
        self.n4x4 = N4x4SessionModel(healthKit: healthKit, store: self.store)
        self.digestion = DigestionAnalysisService(store: store)
        self.pendingMeals = nil
        self.pendingMeals = PendingMealQueue(openRouter: openRouter) { [weak self] entry in
            await self?.recordNutritionEntry(entry)
        }
    }

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        var skipNotificationAuth = false
        #if DEBUG
        skipNotificationAuth = MockMode.isActive
        #endif
        await healthKit.requestAuthorization()
        if !skipNotificationAuth { await notifications.requestAuthorization() }
        if isTrackingDigestion { DigestionBackgroundTask.schedule() }
        await refresh()
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        healthSnapshot = await healthKit.refreshSnapshot()
        let entries = store.fetchAllManualEntries()
        let nutrition = store.fetchAllNutritionEntries()
        let bloodwork = store.fetchAllBloodworkPanels()
        let exercises = store.fetchAllExerciseEntries()
        nutritionDigest = NutritionEngine.digest(nutrition)
        exerciseImageDigest = ExerciseImageDigest(defs: store.fetchAllExerciseDefs())

        let result = PriorityEngine.evaluate(
            manualEntries: entries,
            nutritionEntries: nutrition,
            exerciseEntries: exercises,
            healthSnapshot: healthSnapshot,
            bloodworkPanels: bloodwork
        )
        currentResult = result
        bioAge = BiologicalAgeEngine.evaluate(
            manualEntries: entries,
            nutritionDigest: nutritionDigest,
            healthSnapshot: healthSnapshot,
            bloodworkPanels: bloodwork
        )
        store.recordPriorityHistory(result.allItems)
        await notifications.scheduleReminders(for: result, manualEntries: entries, nutritionEntries: nutrition)
    }

    func recordManualEntry(_ entry: ManualEntry) async {
        store.insertManualEntry(entry)
        await refresh()
    }

    func recordNutritionEntry(_ entry: NutritionEntry) async {
        store.insertNutritionEntry(entry)
        await refresh()
    }

    func deleteNutritionEntry(_ entry: NutritionEntry) async {
        MealImageStore.delete(fileName: entry.imageFileName)
        store.deleteNutritionEntry(entry)
        await refresh()
    }

    func logBloodPressure(systolic: Double, diastolic: Double, date: Date) async throws {
        try await healthKit.saveBloodPressure(systolic: systolic, diastolic: diastolic, date: date)
        await refresh()
    }

    func deleteManualEntry(_ entry: ManualEntry) async {
        store.deleteManualEntry(entry)
        await refresh()
    }

    func recordBloodworkPanel(_ panel: BloodworkPanel) async {
        evaluateMarkers(in: panel)
        store.insertBloodworkPanel(panel)
        await syncSupportedMarkersToHealthKit(panel)
        await refresh()
    }

    /// Re-runs the evaluator against every marker in the panel using the
    /// current user profile and the panel's acute-phase flag. Called from
    /// save and after in-place edits so the stored `flagRaw` always reflects
    /// the JSON-backed bands rather than a user-picked colour.
    func evaluateMarkers(in panel: BloodworkPanel) {
        for marker in panel.markers {
            marker.reevaluate(
                sex: healthSnapshot.biologicalSex,
                dateOfBirth: healthSnapshot.dateOfBirth,
                acutePhaseAtDraw: panel.acutePhaseAtDraw
            )
        }
    }

    /// HealthKit only supports a handful of blood-lab quantity types natively; lipids,
    /// inflammation markers, hormones, and most others have no HK type. We sync the ones
    /// we can (currently: blood glucose) and silently skip the rest.
    private func syncSupportedMarkersToHealthKit(_ panel: BloodworkPanel) async {
        for marker in panel.markers {
            let lowered = marker.name.lowercased()
            guard lowered.contains("glucose"),
                  let value = Double(marker.value.replacingOccurrences(of: ",", with: "."))
            else { continue }
            let fasting = lowered.contains("fasting")
            _ = try? await healthKit.saveBloodGlucose(
                value: value,
                unit: marker.unit,
                date: panel.date,
                fasting: fasting
            )
        }
    }

    func deleteBloodworkPanel(_ panel: BloodworkPanel) async {
        store.deleteBloodworkPanel(panel)
        await refresh()
    }

    /// Re-runs the engine without inserting anything new (use after in-place edits).
    func refreshAfterEdit() async {
        store.saveContext()
        await refresh()
    }

    /// Re-evaluates all markers in a panel after the user changed a value, unit
    /// or the acute-phase flag, then persists + refreshes.
    func reevaluateAndSaveBloodworkPanel(_ panel: BloodworkPanel) async {
        evaluateMarkers(in: panel)
        await refreshAfterEdit()
    }

    // MARK: - AI data sharing

    /// Records the user's permission to send meal photos and exercise names to
    /// OpenRouter, then analyses any meal photos that were waiting for it.
    func allowAISharing() {
        openRouter.consent.grant()
        Task { await pendingMeals.processQueue() }
    }

    /// Stops all OpenRouter requests. Queued meal photos stay on the device.
    func stopAISharing() {
        openRouter.consent.withdraw()
    }

    // MARK: - Digestion Insights

    func startDigestionTracking(at start: Date = .now) {
        store.startTracking(at: start)
        isTrackingDigestion = true
        DigestionBackgroundTask.schedule()
    }

    func stopDigestionTracking(at end: Date = .now) {
        store.stopTracking(at: end)
        isTrackingDigestion = false
        DigestionBackgroundTask.cancel()
    }

    func recordSymptom(_ entry: SymptomEntry) {
        store.insertSymptom(entry)
    }

    func deleteSymptom(_ entry: SymptomEntry) {
        store.deleteSymptom(entry)
    }

    func deleteAllLocalData() async {
        digestion.cancel()
        store.deleteAllLocalData()
        isTrackingDigestion = false
        DigestionBackgroundTask.cancel()
        digestion.reload()
        MealImageStore.wipeAll()
        notifications.cancelAll()
        await refresh()
    }
}
