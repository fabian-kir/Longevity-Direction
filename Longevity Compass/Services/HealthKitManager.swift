import Foundation
import HealthKit
import IntervalEngine

struct BloodPressureReading: Hashable, Identifiable {
    let id = UUID()
    let systolic: Double
    let diastolic: Double
    let date: Date
}

struct HealthKitSnapshot {
    var dailyStepsAverage7d: Double?
    var dailyStepsAverage28d: Double?
    var exerciseMinutesPerWeek: Double?
    var exerciseMinutesPriorWeek: Double?
    var workoutsLast7Days: Int?
    var workoutsLast28Days: Int?
    var strengthWorkoutsLast7Days: Int?
    var strengthWorkoutsLast28Days: Int?
    var restingHeartRateAverage28d: Double?
    var restingHeartRateAverage90d: Double?
    var restingHeartRateSeries: [(date: Date, value: Double)] = []
    var hrvAverage28d: Double?
    /// Underlying HKQuantitySample count for HRV (SDNN) over the last 28 days.
    /// Drives the freshness weight on the HRV engine reading — when at or above
    /// `HealthThresholds.BioAge.V2.hrvMinDays`, HRV counts at full weight;
    /// otherwise its contribution is halved.
    var hrvSampleCount28d: Int?
    /// Raw timestamped HRV (SDNN, ms) samples over the recent past. Used by the
    /// engine's continuous-time EWMA smoother — each sample carries its own
    /// timestamp so the smoother weights by real elapsed time (Δt) rather than
    /// sample index. Do NOT pre-bucket this to daily means; that would lose the
    /// density information the smoother relies on.
    var hrvSamples: [(date: Date, value: Double)] = []
    var sleepHoursAverage7d: Double?
    var sleepHoursAverage28d: Double?
    var latestBodyMass: (value: Double, date: Date)?
    var bodyMassSeries: [(date: Date, value: Double)] = []
    var latestVO2Max: (value: Double, date: Date)?
    var vo2MaxSeries: [(date: Date, value: Double)] = []
    var bloodPressureReadings: [BloodPressureReading] = []
    var dateOfBirth: Date?
    var biologicalSex: HKBiologicalSex = .notSet
    var sampledAt: Date = .now
}

@Observable
final class HealthKitManager {

    enum HealthKitError: LocalizedError {
        case notAvailableOnDevice

        var errorDescription: String? {
            switch self {
            case .notAvailableOnDevice:
                return "HealthKit is not available on this device."
            }
        }
    }

    private let healthStore = HKHealthStore()

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }
    var authorizationRequested: Bool = false
    var lastSyncDate: Date?
    var lastError: String?

    private var readTypes: Set<HKObjectType> {
        var set: Set<HKObjectType> = []
        let q: [HKQuantityTypeIdentifier] = [
            .stepCount,
            .activeEnergyBurned,
            .appleExerciseTime,
            .heartRate,
            .restingHeartRate,
            .heartRateVariabilitySDNN,
            .bodyMass,
            .waistCircumference,
            .vo2Max,
            .bloodPressureSystolic,
            .bloodPressureDiastolic,
        ]
        for id in q {
            if let t = HKObjectType.quantityType(forIdentifier: id) { set.insert(t) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { set.insert(sleep) }
        set.insert(HKObjectType.workoutType())
        if let dob = HKObjectType.characteristicType(forIdentifier: .dateOfBirth) { set.insert(dob) }
        if let sex = HKObjectType.characteristicType(forIdentifier: .biologicalSex) { set.insert(sex) }
        // Apple's measured workout distance and effort, shown in workout details.
        set.formUnion(N4x4HealthLinker.readTypes)
        return set
    }

    private var writeTypes: Set<HKSampleType> {
        var set: Set<HKSampleType> = []
        if let sys = HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic) { set.insert(sys) }
        if let dia = HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic) { set.insert(dia) }
        if let glu = HKObjectType.quantityType(forIdentifier: .bloodGlucose) { set.insert(glu) }
        // Sharing the workout type is required to open an iOS `HKWorkoutSession`,
        // the phone's standalone HR path (AirPods / Bluetooth sensor, spec §5.2).
        set.insert(HKObjectType.workoutType())
        // Outdoor sessions on iPhone record a route; effort ratings are saved
        // as Apple's workout effort score.
        set.insert(HKSeriesType.workoutRoute())
        set.formUnion(N4x4HealthLinker.shareTypes)
        return set
    }

    func requestAuthorization() async {
        #if DEBUG
        if MockMode.isActive { authorizationRequested = true; return }
        #endif
        guard isAvailable else {
            lastError = HealthKitError.notAvailableOnDevice.localizedDescription
            return
        }
        do {
            try await healthStore.requestAuthorization(toShare: writeTypes, read: readTypes)
            authorizationRequested = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Write

    /// Writes a blood glucose sample. `unit` accepts "mg/dL" (default) or "mmol/L".
    /// Returns true if the sample was written, false if HealthKit is unavailable or the type
    /// can't be resolved. Throws on save failure.
    @discardableResult
    func saveBloodGlucose(value: Double, unit: String?, date: Date, fasting: Bool) async throws -> Bool {
        guard isAvailable,
              let type = HKQuantityType.quantityType(forIdentifier: .bloodGlucose) else { return false }
        let hkUnit: HKUnit = (unit?.lowercased() == "mmol/l")
            ? HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter())
            : HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
        let quantity = HKQuantity(unit: hkUnit, doubleValue: value)
        var metadata: [String: Any] = [:]
        if fasting {
            metadata[HKMetadataKeyBloodGlucoseMealTime] = HKBloodGlucoseMealTime.preprandial.rawValue
        }
        let sample = HKQuantitySample(
            type: type,
            quantity: quantity,
            start: date,
            end: date,
            metadata: metadata.isEmpty ? nil : metadata
        )
        try await healthStore.save(sample)
        return true
    }

    func saveBloodPressure(systolic: Double, diastolic: Double, date: Date) async throws {
        guard
            let sysType = HKQuantityType.quantityType(forIdentifier: .bloodPressureSystolic),
            let diaType = HKQuantityType.quantityType(forIdentifier: .bloodPressureDiastolic),
            let bpType  = HKCorrelationType.correlationType(forIdentifier: .bloodPressure)
        else { return }

        let mmHg = HKUnit.millimeterOfMercury()
        let sysSample = HKQuantitySample(type: sysType, quantity: HKQuantity(unit: mmHg, doubleValue: systolic), start: date, end: date)
        let diaSample = HKQuantitySample(type: diaType, quantity: HKQuantity(unit: mmHg, doubleValue: diastolic), start: date, end: date)
        let correlation = HKCorrelation(type: bpType, start: date, end: date, objects: [sysSample, diaSample])
        try await healthStore.save(correlation)
    }

    // MARK: - Public read

    func refreshSnapshot() async -> HealthKitSnapshot {
        #if DEBUG
        if MockMode.isActive {
            let mock = MockData.snapshot()
            lastSyncDate = mock.sampledAt
            return mock
        }
        #endif
        guard isAvailable else { return HealthKitSnapshot() }

        var snapshot = HealthKitSnapshot()
        snapshot.dailyStepsAverage7d         = try? await averageDailySum(.stepCount, days: 7, unit: .count())
        snapshot.dailyStepsAverage28d        = try? await averageDailySum(.stepCount, days: 28, unit: .count())
        snapshot.exerciseMinutesPerWeek      = try? await totalSum(.appleExerciseTime, days: 7, unit: .minute())
        snapshot.exerciseMinutesPriorWeek    = try? await totalSumBetween(.appleExerciseTime, startDaysAgo: 14, endDaysAgo: 7, unit: .minute())
        snapshot.workoutsLast7Days           = try? await workoutCount(days: 7)
        snapshot.workoutsLast28Days          = try? await workoutCount(days: 28)
        snapshot.strengthWorkoutsLast7Days   = try? await workoutCount(days: 7, activityTypes: HealthKitManager.strengthActivityTypes)
        snapshot.strengthWorkoutsLast28Days  = try? await workoutCount(days: 28, activityTypes: HealthKitManager.strengthActivityTypes)
        snapshot.restingHeartRateAverage28d  = try? await averageDiscrete(.restingHeartRate, days: 28, unit: HKUnit.count().unitDivided(by: .minute()))
        snapshot.restingHeartRateAverage90d  = try? await averageDiscrete(.restingHeartRate, days: 90, unit: HKUnit.count().unitDivided(by: .minute()))
        snapshot.hrvAverage28d               = try? await averageDiscrete(.heartRateVariabilitySDNN, days: 28, unit: .secondUnit(with: .milli))
        snapshot.hrvSampleCount28d           = try? await sampleCount(.heartRateVariabilitySDNN, days: 28)
        snapshot.hrvSamples                  = (try? await sampleSeries(
            .heartRateVariabilitySDNN,
            days: HealthThresholds.BioAge.V2.hrvSeriesLookbackDays,
            unit: .secondUnit(with: .milli)
        )) ?? []
        let (s7, s28) = await sleepAverages()
        snapshot.sleepHoursAverage7d         = s7
        snapshot.sleepHoursAverage28d        = s28
        snapshot.latestBodyMass              = try? await latestSample(.bodyMass, unit: .gramUnit(with: .kilo))
        snapshot.bodyMassSeries              = (try? await bodyMassSeries(days: 180)) ?? []
        snapshot.latestVO2Max                = try? await latestSample(.vo2Max, unit: HKUnit(from: "ml/(kg*min)"))
        snapshot.vo2MaxSeries                = (try? await vo2MaxSeries(days: 365)) ?? []
        snapshot.restingHeartRateSeries      = (try? await restingHeartRateSeries(days: 120)) ?? []
        snapshot.bloodPressureReadings       = (try? await bloodPressureSamples(days: 365)) ?? []
        snapshot.dateOfBirth                 = dateOfBirth()
        snapshot.biologicalSex               = biologicalSex()
        snapshot.sampledAt                   = .now

        lastSyncDate = snapshot.sampledAt
        return snapshot
    }

    // MARK: - Characteristics (DOB, biological sex)

    private func dateOfBirth() -> Date? {
        guard isAvailable else { return nil }
        let components = try? healthStore.dateOfBirthComponents()
        return components?.date
    }

    private func biologicalSex() -> HKBiologicalSex {
        guard isAvailable else { return .notSet }
        return (try? healthStore.biologicalSex().biologicalSex) ?? .notSet
    }

    static let strengthActivityTypes: Set<HKWorkoutActivityType> = [
        .traditionalStrengthTraining,
        .functionalStrengthTraining,
        .coreTraining,
    ]

    // MARK: - Internal helpers

    private func dateRange(days: Int) -> (start: Date, end: Date) {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -days, to: end) ?? end
        return (start, end)
    }

    private func averageDailySum(
        _ identifier: HKQuantityTypeIdentifier,
        days: Int,
        unit: HKUnit
    ) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let (start, end) = dateRange(days: days)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(type: type, predicate: predicate),
            options: .cumulativeSum
        )
        guard let result = try await descriptor.result(for: healthStore),
              let sum = result.sumQuantity()?.doubleValue(for: unit) else { return nil }
        return sum / Double(days)
    }

    private func totalSum(
        _ identifier: HKQuantityTypeIdentifier,
        days: Int,
        unit: HKUnit
    ) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let (start, end) = dateRange(days: days)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(type: type, predicate: predicate),
            options: .cumulativeSum
        )
        guard let result = try await descriptor.result(for: healthStore) else { return nil }
        return result.sumQuantity()?.doubleValue(for: unit)
    }

    private func averageDiscrete(
        _ identifier: HKQuantityTypeIdentifier,
        days: Int,
        unit: HKUnit
    ) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let (start, end) = dateRange(days: days)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(type: type, predicate: predicate),
            options: .discreteAverage
        )
        guard let result = try await descriptor.result(for: healthStore),
              let avg = result.averageQuantity()?.doubleValue(for: unit) else { return nil }
        return avg
    }

    private func maxDiscrete(
        _ identifier: HKQuantityTypeIdentifier,
        days: Int,
        unit: HKUnit
    ) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let (start, end) = dateRange(days: days)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(type: type, predicate: predicate),
            options: .discreteMax
        )
        guard let result = try await descriptor.result(for: healthStore) else { return nil }
        return result.maximumQuantity()?.doubleValue(for: unit)
    }

    // MARK: - Live heart rate (N4x4)

    private static var bpmUnit: HKUnit { HKUnit.count().unitDivided(by: .minute()) }

    /// Highest heart-rate sample recorded in the last `days` days, used as the
    /// personal observed ceiling for the HRmax estimate (spec §3). `nil` if there
    /// is no HR history to draw on.
    func observedMaxHeartRate(days: Int = 90) async throws -> Double? {
        #if DEBUG
        if MockMode.isActive { return 188 }
        #endif
        return try await maxDiscrete(.heartRate, days: days, unit: Self.bpmUnit)
    }

    /// Count of underlying `HKQuantitySample`s for `identifier` over the last
    /// `days` days. Used (e.g. for HRV) to gate freshness on whether enough
    /// distinct samples exist, rather than just whether an average is non-nil.
    private func sampleCount(
        _ identifier: HKQuantityTypeIdentifier,
        days: Int
    ) async throws -> Int {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return 0 }
        let (start, end) = dateRange(days: days)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [HKSamplePredicate.quantitySample(type: type, predicate: predicate)],
            sortDescriptors: []
        )
        let samples = try await descriptor.result(for: healthStore)
        return samples.count
    }

    private func latestSample(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit
    ) async throws -> (Double, Date)? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [HKSamplePredicate.quantitySample(type: type, predicate: nil)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        let samples = try await descriptor.result(for: healthStore)
        guard let s = samples.first else { return nil }
        return (s.quantity.doubleValue(for: unit), s.endDate)
    }

    private func workoutCount(days: Int, activityTypes: Set<HKWorkoutActivityType>? = nil) async throws -> Int {
        let (start, end) = dateRange(days: days)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [HKSamplePredicate.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)]
        )
        let workouts = try await descriptor.result(for: healthStore)
        if let filter = activityTypes {
            return workouts.filter { filter.contains($0.workoutActivityType) }.count
        }
        return workouts.count
    }

    private func totalSumBetween(
        _ identifier: HKQuantityTypeIdentifier,
        startDaysAgo: Int,
        endDaysAgo: Int,
        unit: HKUnit
    ) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let now = Date()
        guard
            let start = Calendar.current.date(byAdding: .day, value: -startDaysAgo, to: now),
            let end   = Calendar.current.date(byAdding: .day, value: -endDaysAgo, to: now)
        else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(type: type, predicate: predicate),
            options: .cumulativeSum
        )
        guard let result = try await descriptor.result(for: healthStore) else { return nil }
        return result.sumQuantity()?.doubleValue(for: unit)
    }

    private func sleepAverages() async -> (Double?, Double?) {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            return (nil, nil)
        }
        let (start28, end28) = dateRange(days: 28)
        let predicate = HKQuery.predicateForSamples(withStart: start28, end: end28, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [HKSamplePredicate.categorySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )
        guard let samples = try? await descriptor.result(for: healthStore), !samples.isEmpty else {
            return (nil, nil)
        }
        let perNight = Self.nightlyAsleepDurations(from: samples)
        let cal = Calendar.current
        let cutoff7 = cal.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let last7 = perNight.filter { $0.key >= cutoff7 }.values
        let last28 = perNight.values

        func hours(_ vals: some Collection<TimeInterval>) -> Double? {
            guard !vals.isEmpty else { return nil }
            return vals.reduce(0, +) / Double(vals.count) / 3600.0
        }
        return (hours(last7), hours(last28))
    }

    /// Buckets asleep samples into per-night totals. For each night, picks the highest-trust
    /// source present (Apple Watch > iPhone/iPad > other) and ignores the rest, so that overlapping
    /// coverage from multiple devices doesn't double-count. Within the chosen source, overlapping
    /// or adjacent intervals are merged before summing.
    private static func nightlyAsleepDurations(from samples: [HKCategorySample]) -> [Date: TimeInterval] {
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        let cal = Calendar.current
        var byNight: [Date: [HKCategorySample]] = [:]
        for s in samples where asleepValues.contains(s.value) {
            let bucket = cal.startOfDay(for: s.startDate)
            byNight[bucket, default: []].append(s)
        }

        var perNight: [Date: TimeInterval] = [:]
        for (bucket, nightSamples) in byNight {
            guard let bestTier = nightSamples.map({ sleepSourceTier(for: $0) }).min() else { continue }
            let chosen = nightSamples.filter { sleepSourceTier(for: $0) == bestTier }
            let intervals = chosen
                .map { (start: $0.startDate, end: $0.endDate) }
                .sorted { $0.start < $1.start }

            var merged: [(start: Date, end: Date)] = []
            for iv in intervals {
                if let last = merged.last, iv.start <= last.end {
                    merged[merged.count - 1] = (last.start, max(last.end, iv.end))
                } else {
                    merged.append(iv)
                }
            }
            perNight[bucket] = merged.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        }
        return perNight
    }

    /// Lower tier = higher trust. Apple Watch wins when worn; iPhone/iPad is fallback.
    private static func sleepSourceTier(for sample: HKCategorySample) -> Int {
        let product = sample.sourceRevision.productType ?? ""
        if product.hasPrefix("Watch") { return 0 }
        if product.hasPrefix("iPhone") || product.hasPrefix("iPad") { return 1 }
        return 2
    }

    // MARK: - Historical series (for trend analysis)

    func dailyStepsSeries(days: Int = 30) async throws -> [(date: Date, value: Double)] {
        #if DEBUG
        if MockMode.isActive { return MockData.stepsSeries(days: days) }
        #endif
        return try await dailyBucketSeries(.stepCount, days: days, unit: .count(), options: .cumulativeSum)
    }

    func dailyExerciseMinutesSeries(days: Int = 30) async throws -> [(date: Date, value: Double)] {
        try await dailyBucketSeries(.appleExerciseTime, days: days, unit: .minute(), options: .cumulativeSum)
    }

    func restingHeartRateSeries(days: Int = 60) async throws -> [(date: Date, value: Double)] {
        #if DEBUG
        if MockMode.isActive { return MockData.rhrSeries(days: days) }
        #endif
        return try await dailyBucketSeries(
            .restingHeartRate,
            days: days,
            unit: HKUnit.count().unitDivided(by: .minute()),
            options: .discreteAverage,
            sumOrAverage: .average
        )
    }

    func bodyMassSeries(days: Int = 180) async throws -> [(date: Date, value: Double)] {
        #if DEBUG
        if MockMode.isActive { return MockData.bodyMassSeries(days: days) }
        #endif
        return try await sampleSeries(.bodyMass, days: days, unit: .gramUnit(with: .kilo))
    }

    func vo2MaxSeries(days: Int = 365) async throws -> [(date: Date, value: Double)] {
        #if DEBUG
        if MockMode.isActive { return MockData.vo2MaxSeries(days: days) }
        #endif
        return try await sampleSeries(.vo2Max, days: days, unit: HKUnit(from: "ml/(kg*min)"))
    }

    func sleepNightlySeries(days: Int = 30) async throws -> [(date: Date, value: Double)] {
        #if DEBUG
        if MockMode.isActive { return MockData.sleepSeries(days: days) }
        #endif
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let (start, end) = dateRange(days: days)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [HKSamplePredicate.categorySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )
        let samples = try await descriptor.result(for: healthStore)
        return Self.nightlyAsleepDurations(from: samples)
            .map { (date: $0.key, value: $0.value / 3600.0) }
            .sorted { $0.date < $1.date }
    }

    func bloodPressureSeries(days: Int = 90) async throws -> [BloodPressureReading] {
        #if DEBUG
        if MockMode.isActive { return MockData.bloodPressureSeries(days: days) }
        #endif
        return try await bloodPressureSamples(days: days)
    }

    // MARK: - Series helpers

    private enum DailyAggregation { case sum, average }

    private func dailyBucketSeries(
        _ identifier: HKQuantityTypeIdentifier,
        days: Int,
        unit: HKUnit,
        options: HKStatisticsOptions,
        sumOrAverage: DailyAggregation = .sum
    ) async throws -> [(date: Date, value: Double)] {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return [] }
        let (start, end) = dateRange(days: days)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let anchor = Calendar.current.startOfDay(for: start)
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(type: type, predicate: predicate),
            options: options,
            anchorDate: anchor,
            intervalComponents: DateComponents(day: 1)
        )
        let collection = try await descriptor.result(for: healthStore)
        var series: [(date: Date, value: Double)] = []
        collection.enumerateStatistics(from: start, to: end) { stat, _ in
            let value: Double? = switch sumOrAverage {
            case .sum:     stat.sumQuantity()?.doubleValue(for: unit)
            case .average: stat.averageQuantity()?.doubleValue(for: unit)
            }
            if let v = value, v > 0 {
                series.append((stat.startDate, v))
            }
        }
        return series
    }

    private func sampleSeries(
        _ identifier: HKQuantityTypeIdentifier,
        days: Int,
        unit: HKUnit
    ) async throws -> [(date: Date, value: Double)] {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return [] }
        let (start, end) = dateRange(days: days)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [HKSamplePredicate.quantitySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )
        let samples = try await descriptor.result(for: healthStore)
        return samples.map { (date: $0.startDate, value: $0.quantity.doubleValue(for: unit)) }
    }

    private func bloodPressureSamples(days: Int) async throws -> [BloodPressureReading] {
        guard
            let sysType = HKQuantityType.quantityType(forIdentifier: .bloodPressureSystolic),
            let diaType = HKQuantityType.quantityType(forIdentifier: .bloodPressureDiastolic)
        else { return [] }
        let (start, end) = dateRange(days: days)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        let sysDesc = HKSampleQueryDescriptor(
            predicates: [HKSamplePredicate.quantitySample(type: sysType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)]
        )
        let diaDesc = HKSampleQueryDescriptor(
            predicates: [HKSamplePredicate.quantitySample(type: diaType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)]
        )
        async let sysSamples = sysDesc.result(for: healthStore)
        async let diaSamples = diaDesc.result(for: healthStore)
        let (sys, dia) = try await (sysSamples, diaSamples)

        let diaByDate = Dictionary(dia.map { ($0.startDate, $0) }, uniquingKeysWith: { first, _ in first })
        let unit = HKUnit.millimeterOfMercury()
        return sys.compactMap { s in
            guard let d = diaByDate[s.startDate] else { return nil }
            return BloodPressureReading(
                systolic: s.quantity.doubleValue(for: unit),
                diastolic: d.quantity.doubleValue(for: unit),
                date: s.startDate
            )
        }
    }
}
