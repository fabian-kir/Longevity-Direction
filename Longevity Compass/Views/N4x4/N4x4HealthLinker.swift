import Foundation
import HealthKit
import IntervalEngine
import SwiftData

/// Connects a workout log to the Apple Health workout saved for it (by this
/// iPhone or synced from the Watch), found by its sync identifier.
///
/// Apple stays the source of truth for measured values: distance and active
/// calories are read back from Health rather than estimated in the app. The
/// user's effort rating is written to Health as Apple's own effort score.
@MainActor
final class N4x4HealthLinker {
    private let healthStore = HKHealthStore()
    private var inFlight: Set<UUID> = []

    private static let distanceTypes: [HKQuantityTypeIdentifier] = [
        .distanceWalkingRunning, .distanceCycling, .distanceRowing, .distanceCrossCountrySkiing,
    ]

    /// Types the phone reads to show Apple's measurements.
    static var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>(distanceTypes.compactMap { HKObjectType.quantityType(forIdentifier: $0) })
        types.insert(HKQuantityType(.workoutEffortScore))
        return types
    }

    static var shareTypes: Set<HKSampleType> {
        [HKQuantityType(.workoutEffortScore)]
    }

    /// Reads Apple's values into `log` and writes a pending effort rating.
    /// Returns `false` while the workout hasn't reached this iPhone yet (a
    /// Watch save can take a moment to sync).
    @discardableResult
    func refresh(_ log: N4x4WorkoutLog) async -> Bool {
        guard HKHealthStore.isHealthDataAvailable(), !inFlight.contains(log.sessionID) else { return false }
        inFlight.insert(log.sessionID)
        defer { inFlight.remove(log.sessionID) }

        guard let workout = await workout(for: log.sessionID) else { return false }
        log.healthKitSaveState = .saved
        log.healthKitError = nil
        log.appleDistanceKilometers = Self.distanceKilometers(of: workout)
        log.appleActiveCalories = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?
            .doubleValue(for: .kilocalorie())
        if log.effortScore != nil, log.effortSampleID == nil {
            await writeEffort(for: log, workout: workout)
        }
        try? log.modelContext?.save()
        return true
    }

    /// Retries `refresh` a few times after a save, covering Watch → iPhone
    /// sync delay without polling indefinitely.
    func refreshSoon(_ log: N4x4WorkoutLog) {
        Task { [weak self] in
            for delay in [3, 15, 60, 180] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                if await self.refresh(log) { return }
            }
        }
    }

    /// Stores a new rating and replaces any rating already in Health.
    func setEffort(_ score: Int?, for log: N4x4WorkoutLog) async {
        log.effortScore = score
        try? log.modelContext?.save()
        guard HKHealthStore.isHealthDataAvailable(),
              let workout = await workout(for: log.sessionID) else { return }
        await removeEffortSample(of: log, workout: workout)
        if score != nil { await writeEffort(for: log, workout: workout) }
        try? log.modelContext?.save()
    }

    private func workout(for sessionID: UUID) async -> HKWorkout? {
        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeySyncIdentifier,
            allowedValues: [sessionID.uuidString]
        )
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        return try? await descriptor.result(for: healthStore).first
    }

    private func writeEffort(for log: N4x4WorkoutLog, workout: HKWorkout) async {
        guard let score = log.effortScore else { return }
        let sample = HKQuantitySample(
            type: HKQuantityType(.workoutEffortScore),
            quantity: HKQuantity(unit: .appleEffortScore(), doubleValue: Double(min(max(score, 1), 10))),
            start: workout.startDate,
            end: workout.endDate
        )
        do {
            try await healthStore.save(sample)
            try await healthStore.relateWorkoutEffortSample(sample, with: workout, activity: nil)
            log.effortSampleID = sample.uuid
        } catch {
            // Missing write permission keeps the rating in the app only.
        }
    }

    private func removeEffortSample(of log: N4x4WorkoutLog, workout: HKWorkout) async {
        guard let sampleID = log.effortSampleID else { return }
        log.effortSampleID = nil
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(
                type: HKQuantityType(.workoutEffortScore),
                predicate: HKQuery.predicateForObject(with: sampleID)
            )],
            sortDescriptors: [],
            limit: 1
        )
        guard let sample = try? await descriptor.result(for: healthStore).first else { return }
        _ = try? await healthStore.unrelateWorkoutEffortSample(sample, from: workout, activity: nil)
        try? await healthStore.delete(sample)
    }

    private static func distanceKilometers(of workout: HKWorkout) -> Double? {
        let meters = distanceTypes.compactMap { identifier -> Double? in
            workout.statistics(for: HKQuantityType(identifier))?.sumQuantity()?.doubleValue(for: .meter())
        }.reduce(0, +)
        return meters > 0 ? meters / 1000 : nil
    }
}
