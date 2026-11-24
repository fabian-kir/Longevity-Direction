import Foundation
import IntervalEngine
import SwiftData

/// Equipment lives in the shared package so the Watch maps it to the same
/// Apple workout type.
typealias N4x4Equipment = WorkoutEquipment

enum N4x4HealthKitSaveState: String, Codable {
    case notRequested
    case requested
    case saved
    case failed
}

struct N4x4WorkoutFrame: Codable, Equatable, Identifiable {
    let capturedAt: Date
    let elapsed: TimeInterval
    let phase: PhaseKind
    let bpm: Double?
    let targetLower: Double?
    let targetUpper: Double?

    var id: Date { capturedAt }

    init(capturedAt: Date = .now, output: EngineOutput) {
        self.capturedAt = capturedAt
        self.elapsed = output.elapsed
        self.phase = output.phase
        self.bpm = output.trailingHR
        self.targetLower = output.target?.lowerBound
        self.targetUpper = output.target?.upperBound
    }

    var targetMidpoint: Double? {
        guard let targetLower, let targetUpper else { return nil }
        return (targetLower + targetUpper) / 2
    }
}

struct N4x4WorkoutDetails: Equatable {
    var equipment: N4x4Equipment = .unspecified
}

/// Heart-check results: how hard the heart works at the fixed workload, and
/// how fast it slows once you stop.
struct HeartCheckResult: Equatable {
    /// Average HR over the last minute of the workload (lower = fitter).
    let workloadHeartRate: Double
    /// HR when the stillness phase began.
    let stopHeartRate: Double
    /// Drop after 60 s / 120 s of standing still (larger = better).
    let dropAfter60: Double?
    let dropAfter120: Double?
}

@Model
final class N4x4WorkoutLog {
    @Attribute(.unique) var sessionID: UUID
    var startedAt: Date
    var endedAt: Date?
    var duration: TimeInterval
    var isCompleted: Bool
    var equipmentRaw: String
    /// Which routine ran (`WorkoutMode` raw value). Logs from before the
    /// other modes existed are 4×4 sessions.
    var modeRaw: String = WorkoutMode.n4x4.rawValue
    /// Tolerance either side of the target used for this session.
    var targetDeadBand: Double?
    /// The machine's distance, when the user corrected the Watch's estimate.
    @Attribute(originalName: "machineDistanceKilometers") var correctedDistanceKilometers: Double?
    /// Treadmill incline, which the Watch can't see.
    var inclinePercent: Double?
    /// Apple effort rating (1–10).
    var effortScore: Int?
    /// The effort sample written to Apple Health, so a changed rating can
    /// replace it. `nil` while the rating is only stored in the app.
    var effortSampleID: UUID?
    /// Values Apple Health measured for the saved workout, read back after the
    /// save so the app shows Apple's numbers rather than its own estimates.
    var appleDistanceKilometers: Double?
    var appleActiveCalories: Double?
    var notes: String
    var estimatedHRMax: Double?
    var averageHeartRate: Double?
    var peakHeartRate: Double?
    var targetAdherence: Double?
    var averageOneMinuteRise: Double?
    var averageOneMinuteRecovery: Double?
    /// Heart-check results (see `HeartCheckResult`).
    var workloadHeartRate: Double?
    var stopHeartRate: Double?
    var recoveryDropAfter60: Double?
    var recoveryDropAfter120: Double?
    /// The fixed workload of a heart check, e.g. "Treadmill walk · 5.5 km/h · 8%".
    /// Checks are only compared with others at the same workload.
    var workloadSummary: String?
    var healthKitSaveStateRaw: String
    var healthKitError: String?
    @Attribute(.externalStorage) var framesData: Data

    init(
        sessionID: UUID,
        startedAt: Date,
        estimatedHRMax: Double?,
        equipment: N4x4Equipment,
        mode: WorkoutMode = .n4x4
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.endedAt = nil
        self.duration = 0
        self.isCompleted = false
        self.equipmentRaw = equipment.rawValue
        self.modeRaw = mode.rawValue
        self.targetDeadBand = nil
        self.correctedDistanceKilometers = nil
        self.inclinePercent = nil
        self.effortScore = nil
        self.effortSampleID = nil
        self.appleDistanceKilometers = nil
        self.appleActiveCalories = nil
        self.notes = ""
        self.estimatedHRMax = estimatedHRMax
        self.averageHeartRate = nil
        self.peakHeartRate = nil
        self.targetAdherence = nil
        self.averageOneMinuteRise = nil
        self.averageOneMinuteRecovery = nil
        self.workloadHeartRate = nil
        self.stopHeartRate = nil
        self.recoveryDropAfter60 = nil
        self.recoveryDropAfter120 = nil
        self.workloadSummary = nil
        self.healthKitSaveStateRaw = N4x4HealthKitSaveState.notRequested.rawValue
        self.healthKitError = nil
        self.framesData = Data()
    }

    var equipment: N4x4Equipment {
        get { N4x4Equipment(rawValue: equipmentRaw) ?? .unspecified }
        set { equipmentRaw = newValue.rawValue }
    }

    var mode: WorkoutMode {
        get { WorkoutMode(rawValue: modeRaw) ?? .n4x4 }
        set { modeRaw = newValue.rawValue }
    }

    var healthKitSaveState: N4x4HealthKitSaveState {
        get { N4x4HealthKitSaveState(rawValue: healthKitSaveStateRaw) ?? .notRequested }
        set { healthKitSaveStateRaw = newValue.rawValue }
    }

    /// Distance to show: the user's machine value wins over Apple's estimate.
    var distanceKilometers: Double? { correctedDistanceKilometers ?? appleDistanceKilometers }

    /// Elevation climbed on a treadmill: distance × incline.
    var elevationGainMeters: Double? {
        guard let distance = distanceKilometers, let incline = inclinePercent, incline > 0 else { return nil }
        return distance * 1000 * incline / 100
    }

    var heartCheckResult: HeartCheckResult? {
        guard let workloadHeartRate, let stopHeartRate else { return nil }
        return HeartCheckResult(
            workloadHeartRate: workloadHeartRate,
            stopHeartRate: stopHeartRate,
            dropAfter60: recoveryDropAfter60,
            dropAfter120: recoveryDropAfter120
        )
    }

    var title: String { mode.title }

    var frames: [N4x4WorkoutFrame] {
        get {
            guard !framesData.isEmpty else { return [] }
            return (try? JSONDecoder().decode([N4x4WorkoutFrame].self, from: framesData)) ?? []
        }
        set {
            framesData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }
}
