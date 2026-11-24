import Foundation

/// Records when each phase started so the saved Apple Health workout can carry
/// one segment per warm-up, interval, recovery and cool-down. Pure value type;
/// the HealthKit conversion lives below.
public struct PhaseSegmentTracker: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public let label: String
        public let start: Date
        public let end: Date
    }

    private var open: (label: String, kind: PhaseKind, start: Date)?
    private var closed: [Segment] = []

    public init() {}

    /// Call on every engine tick; only phase changes are recorded.
    public mutating func observe(kind: PhaseKind, label: String, at date: Date) {
        if let open, open.kind == kind { return }
        close(at: date)
        open = (label, kind, date)
    }

    /// Closes the running segment and returns all of them.
    public mutating func finish(at date: Date) -> [Segment] {
        close(at: date)
        return closed
    }

    public mutating func reset() {
        open = nil
        closed = []
    }

    private mutating func close(at date: Date) {
        guard let open else { return }
        if date > open.start {
            closed.append(Segment(label: open.label, start: open.start, end: date))
        }
        self.open = nil
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.closed == rhs.closed
            && lhs.open?.label == rhs.open?.label
            && lhs.open?.kind == rhs.open?.kind
            && lhs.open?.start == rhs.open?.start
    }
}

#if canImport(HealthKit) && (os(iOS) || os(watchOS))
import CoreLocation
import HealthKit

public enum WorkoutHealthMetadata {
    /// Custom metadata key naming the phase a segment event covers.
    public static let phaseKey = "LongevityDirectionPhase"

    public static func workout(mode: WorkoutMode, sessionID: UUID, equipment: WorkoutEquipment) -> [String: Any] {
        var metadata: [String: Any] = [
            HKMetadataKeyWorkoutBrandName: "Longevity Direction · \(mode.title)",
            HKMetadataKeySyncIdentifier: sessionID.uuidString,
            HKMetadataKeySyncVersion: 1,
        ]
        if let indoor = equipment.isIndoor { metadata[HKMetadataKeyIndoorWorkout] = indoor }
        return metadata
    }

    /// Segment events in the same form Apple's own Workout app uses for
    /// manual segments, so Fitness can list them.
    public static func segmentEvents(_ segments: [PhaseSegmentTracker.Segment]) -> [HKWorkoutEvent] {
        segments.map { segment in
            HKWorkoutEvent(
                type: .segment,
                dateInterval: DateInterval(start: segment.start, end: segment.end),
                metadata: [phaseKey: segment.label]
            )
        }
    }

    /// Types the live builder may write for any supported equipment.
    public static var liveReadTypes: Set<HKObjectType> {
        let identifiers: [HKQuantityTypeIdentifier] = [
            .heartRate, .activeEnergyBurned, .distanceWalkingRunning, .distanceCycling,
            .runningSpeed, .runningPower, .stepCount, .flightsClimbed,
        ]
        var types = Set<HKObjectType>(identifiers.compactMap { HKObjectType.quantityType(forIdentifier: $0) })
        if let dob = HKObjectType.characteristicType(forIdentifier: .dateOfBirth) { types.insert(dob) }
        return types
    }

    public static var liveShareTypes: Set<HKSampleType> {
        [HKQuantityType.workoutType(), HKSeriesType.workoutRoute()]
    }
}

/// Records a GPS route for outdoor sessions and attaches it to the finished
/// workout. Location permission is requested on first use only, so indoor
/// users never see the prompt.
@MainActor
public final class WorkoutRouteRecorder: NSObject, CLLocationManagerDelegate {
    private let healthStore: HKHealthStore
    private let locationManager = CLLocationManager()
    private var routeBuilder: HKWorkoutRouteBuilder?

    public init(healthStore: HKHealthStore) {
        self.healthStore = healthStore
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.activityType = .fitness
    }

    public var isRecording: Bool { routeBuilder != nil }

    public func start() {
        guard routeBuilder == nil else { return }
        routeBuilder = HKWorkoutRouteBuilder(healthStore: healthStore, device: nil)
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        locationManager.startUpdatingLocation()
    }

    /// Stops collecting and hands back the route so far. The caller attaches
    /// it once the workout is saved (`finishRoute(with:metadata:)`) or
    /// discards it; a new session can start recording immediately.
    public func stop() -> HKWorkoutRouteBuilder? {
        locationManager.stopUpdatingLocation()
        defer { routeBuilder = nil }
        return routeBuilder
    }

    public func discard() {
        locationManager.stopUpdatingLocation()
        routeBuilder?.discard()
        routeBuilder = nil
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let usable = locations.filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 50 }
        guard !usable.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let builder = self?.routeBuilder else { return }
            try? await builder.insertRouteData(usable)
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
#endif
