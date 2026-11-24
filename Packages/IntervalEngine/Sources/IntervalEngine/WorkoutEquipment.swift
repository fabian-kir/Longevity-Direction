import Foundation

/// What the session is performed on. Each case maps to one Apple workout type
/// so HealthKit records the matching metrics (distance, pace, running form).
///
/// Raw values are persisted; keep existing ones stable.
public enum WorkoutEquipment: String, CaseIterable, Codable, Identifiable, Sendable {
    case unspecified
    case treadmill
    case treadmillWalk
    case stationaryBike
    case rowingMachine
    case elliptical
    case stepper
    case outdoor
    case outdoorWalk
    case outdoorCycle
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .unspecified:    return "Not set"
        case .treadmill:      return "Treadmill run"
        case .treadmillWalk:  return "Treadmill walk"
        case .stationaryBike: return "Indoor cycle"
        case .rowingMachine:  return "Indoor row"
        case .elliptical:     return "Elliptical"
        case .stepper:        return "Stair stepper"
        case .outdoor:        return "Outdoor run"
        case .outdoorWalk:    return "Outdoor walk"
        case .outdoorCycle:   return "Outdoor cycle"
        case .other:          return "Other"
        }
    }

    public var systemImage: String {
        switch self {
        case .unspecified:    return "figure.run"
        case .treadmill:      return "figure.run.treadmill"
        case .treadmillWalk:  return "figure.walk.treadmill"
        case .stationaryBike: return "figure.indoor.cycle"
        case .rowingMachine:  return "figure.rower"
        case .elliptical:     return "figure.elliptical"
        case .stepper:        return "figure.stair.stepper"
        case .outdoor:        return "figure.run"
        case .outdoorWalk:    return "figure.walk"
        case .outdoorCycle:   return "figure.outdoor.cycle"
        case .other:          return "figure.mixed.cardio"
        }
    }

    public var isIndoor: Bool? {
        switch self {
        case .outdoor, .outdoorWalk, .outdoorCycle: return false
        case .unspecified, .other:                  return nil
        default:                                    return true
        }
    }

    /// Outdoor sessions record a GPS route.
    public var recordsRoute: Bool { isIndoor == false }

    /// Machines whose own distance display can correct the Watch's estimate.
    public var acceptsDistanceCorrection: Bool {
        switch self {
        case .treadmill, .treadmillWalk, .stationaryBike, .rowingMachine, .elliptical: return true
        default: return false
        }
    }

    /// Treadmills have an incline the Watch can't see.
    public var acceptsIncline: Bool {
        self == .treadmill || self == .treadmillWalk
    }

    /// Equipment with a speed setting for the heart check's fixed workload.
    public var hasSpeedSetting: Bool {
        switch self {
        case .treadmill, .treadmillWalk: return true
        default: return false
        }
    }

    /// Picker order: most common first, unspecified last.
    public static let pickerOrder: [WorkoutEquipment] = [
        .treadmill, .treadmillWalk, .stationaryBike, .rowingMachine, .elliptical,
        .stepper, .outdoor, .outdoorWalk, .outdoorCycle, .other, .unspecified,
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = WorkoutEquipment(rawValue: raw) ?? .unspecified
    }
}

#if canImport(HealthKit) && (os(iOS) || os(watchOS))
import HealthKit

extension WorkoutEquipment {
    /// The HealthKit configuration for this equipment. Unknown equipment falls
    /// back to the mode's generic type, as before.
    public func workoutConfiguration(for mode: WorkoutMode) -> HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        switch self {
        case .treadmill, .outdoor:
            configuration.activityType = .running
        case .treadmillWalk, .outdoorWalk:
            configuration.activityType = .walking
        case .stationaryBike, .outdoorCycle:
            configuration.activityType = .cycling
        case .rowingMachine:
            configuration.activityType = .rowing
        case .elliptical:
            configuration.activityType = .elliptical
        case .stepper:
            configuration.activityType = .stairClimbing
        case .unspecified, .other:
            configuration.activityType = mode == .n4x4 ? .highIntensityIntervalTraining : .mixedCardio
        }
        switch isIndoor {
        case true?:  configuration.locationType = .indoor
        case false?: configuration.locationType = .outdoor
        case nil:    configuration.locationType = .unknown
        }
        return configuration
    }

    /// Best-effort reverse mapping for a configuration HealthKit hands the
    /// Watch when the phone launches it.
    public init(configuration: HKWorkoutConfiguration) {
        let indoor = configuration.locationType == .indoor
        switch configuration.activityType {
        case .running:       self = indoor ? .treadmill : .outdoor
        case .walking:       self = indoor ? .treadmillWalk : .outdoorWalk
        case .cycling:       self = indoor ? .stationaryBike : .outdoorCycle
        case .rowing:        self = .rowingMachine
        case .elliptical:    self = .elliptical
        case .stairClimbing: self = .stepper
        default:             self = .unspecified
        }
    }
}
#endif
