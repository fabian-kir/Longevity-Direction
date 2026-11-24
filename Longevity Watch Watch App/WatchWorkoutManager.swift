import Foundation
import HealthKit
import IntervalEngine

/// Owns the watch's `HKWorkoutSession` + `HKLiveWorkoutBuilder` — the real
/// beat-to-beat HR source that makes the watch a valid session *primary*
/// (spec §5.2). Live HR samples are pushed to `onHR`; HRmax is estimated from
/// HealthKit DOB + observed 90-day max via the shared `HRMaxEstimator`.
///
/// Sensors don't run in the Simulator (spec §9), so the caller bypasses this
/// entirely under `MockMode`; everything here is exercised only on device.
@MainActor
final class WatchWorkoutManager: NSObject {
    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var onHR: ((Double, Date) -> Void)?
    private var segments = PhaseSegmentTracker()
    private lazy var route = WorkoutRouteRecorder(healthStore: healthStore)

    /// App state/control messages arriving from the mirrored phone session.
    var onRemoteMessage: ((SessionMessage) -> Void)?

    /// Mirroring failure is transport-only: the wrist workout and builder keep
    /// running, and the owner can retry or continue standalone.
    var onRemoteDisconnect: ((Error?) -> Void)?

    /// A local HealthKit session failure removes the sensor source, but must not
    /// stop the protocol engine. The owner can report degradation and retry.
    var onSessionFailure: ((Error) -> Void)?

    /// Fired when HealthKit transitions the source to ended without this manager
    /// initiating teardown. The protocol owner treats it as sensor loss unless a
    /// separately identified `.stop` command arrives.
    var onSessionEnded: (() -> Void)?

    private(set) var isRemoteConnected = false

    // `nonisolated`: pure computed HealthKit lookups with no stored state, so the
    // nonisolated builder delegate (below) can read them off the main actor.
    private nonisolated static var bpmUnit: HKUnit { HKUnit.count().unitDivided(by: .minute()) }
    private nonisolated static var heartRateType: HKQuantityType? {
        HKObjectType.quantityType(forIdentifier: .heartRate)
    }

    /// Request read access to HR, DOB and the live workout metrics plus workout
    /// and route share. Returns `false` when HealthKit is unavailable or the
    /// user declines.
    func requestAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        do {
            try await healthStore.requestAuthorization(
                toShare: WorkoutHealthMetadata.liveShareTypes,
                read: WorkoutHealthMetadata.liveReadTypes
            )
            return true
        } catch {
            return false
        }
    }

    /// HRmax = higher of Tanaka(age) and observed 90-day max (spec §3), or `nil`
    /// when neither DOB nor any observed max is available (→ timer-only).
    func estimatedHRMax() async -> Double? {
        let dob = (try? healthStore.dateOfBirthComponents())?.date
        let observed = try? await observedMaxHeartRate(days: 90)
        return HRMaxEstimator.estimate(dateOfBirth: dob, observedMaxLast90d: observed)
    }

    private func observedMaxHeartRate(days: Int) async throws -> Double? {
        guard let hr = Self.heartRateType else { return nil }
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -days, to: end) ?? end
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: hr, predicate: predicate),
            options: .discreteMax
        )
        let result = try await descriptor.result(for: healthStore)
        return result?.maximumQuantity()?.doubleValue(for: Self.bpmUnit)
    }

    /// Start a workout session of the type matching `equipment` and begin
    /// streaming HR. Returns `false` if a session can't be created (no
    /// HealthKit) so the caller can degrade.
    @discardableResult
    func start(
        equipment: WorkoutEquipment,
        mode: WorkoutMode,
        onHR: @escaping (Double, Date) -> Void
    ) -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        self.onHR = onHR

        if session != nil {
            return true
        }

        let config = equipment.workoutConfiguration(for: mode)

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder

            // Initiate mirroring before activity starts. Its completion runs on
            // an arbitrary queue and never gates the local wrist session.
            beginMirroringBestEffort(for: session)

            let startDate = Date()
            session.startActivity(with: startDate)
            builder.beginCollection(withStart: startDate) { _, _ in }
            segments.reset()
            if equipment.recordsRoute { route.start() }
            return true
        } catch {
            self.onHR = nil
            return false
        }
    }

    /// Retry mirroring an already-running wrist session without affecting it if
    /// the phone is still unavailable.
    @discardableResult
    func startMirroring() async -> Bool {
        guard let session else { return false }
        do {
            try await session.startMirroringToCompanionDevice()
            isRemoteConnected = true
            return true
        } catch {
            isRemoteConnected = false
            onRemoteDisconnect?(error)
            return false
        }
    }

    /// Send current protocol state or a control command to the mirrored phone.
    /// Starting the callback-based transfer synchronously matters for terminal
    /// packets: callers may end the workout immediately after this method returns.
    @discardableResult
    func beginSendingToRemote(_ message: SessionMessage) -> Bool {
        guard let session,
              let data = try? JSONEncoder().encode(message) else { return false }
        session.sendToRemoteWorkoutSession(data: data) { _, _ in }
        return true
    }

    /// Send current protocol state or a control command to the mirrored phone.
    @discardableResult
    func sendToRemote(_ message: SessionMessage) async -> Bool {
        guard let session,
              let data = try? JSONEncoder().encode(message) else { return false }
        do {
            try await session.sendToRemoteWorkoutSession(data: data)
            return true
        } catch {
            return false
        }
    }

    func pause() {
        guard session?.state == .running else { return }
        session?.pause()
    }

    func resume() {
        guard session?.state == .paused else { return }
        session?.resume()
    }

    /// Marks phase boundaries for the saved workout's segments.
    func observePhase(_ kind: PhaseKind, label: String, at date: Date) {
        guard session != nil else { return }
        segments.observe(kind: kind, label: label, at: date)
    }

    func teardown() {
        route.discard()
        segments.reset()
        onHR = nil
        isRemoteConnected = false
        session?.delegate = nil
        builder?.delegate = nil
        session?.end()
        // Explicit stops and failed/replaced sensor sessions are not completed
        // workouts. The natural completion path finalizes its builder instead.
        builder?.discardWorkout()
        session = nil
        builder = nil
    }

    /// Finalizes a completed session as one HealthKit workout with a segment
    /// per phase. Explicitly stopped sessions continue to use `teardown()` and
    /// are discarded, preserving the distinction between complete and aborted
    /// runs.
    @discardableResult
    func completeWorkout(
        at endDate: Date,
        sessionID: UUID,
        mode: WorkoutMode,
        equipment: WorkoutEquipment,
        completion: @escaping (Error?) -> Void = { _ in }
    ) -> Bool {
        guard let session, let builder else { return false }
        let events = WorkoutHealthMetadata.segmentEvents(segments.finish(at: endDate))
        segments.reset()
        let pendingRoute = route.stop()

        onHR = nil
        isRemoteConnected = false
        self.session = nil
        self.builder = nil
        session.delegate = nil
        builder.delegate = nil
        session.end()

        Task { @MainActor in
            do {
                if !events.isEmpty { try? await builder.addWorkoutEvents(events) }
                try await builder.endCollection(at: endDate)
                try await builder.addMetadata(
                    WorkoutHealthMetadata.workout(mode: mode, sessionID: sessionID, equipment: equipment)
                )
                let (workout, error) = await withCheckedContinuation { continuation in
                    builder.finishWorkout { workout, error in
                        continuation.resume(returning: (workout, error))
                    }
                }
                if let workout {
                    _ = try? await pendingRoute?.finishRoute(with: workout, metadata: nil)
                } else {
                    pendingRoute?.discard()
                }
                completion(error)
            } catch {
                pendingRoute?.discard()
                builder.discardWorkout()
                completion(error)
            }
        }
        return true
    }

    // Compatibility alias for existing callers.
    func stop() {
        teardown()
    }

    private func beginMirroringBestEffort(for session: HKWorkoutSession) {
        session.startMirroringToCompanionDevice { [weak self] success, error in
            Task { @MainActor [weak self] in
                guard let self, self.session === session else { return }
                self.isRemoteConnected = success
                if !success {
                    self.onRemoteDisconnect?(error)
                }
            }
        }
    }

    private func handleRemoteData(
        _ payloads: [Data],
        from sourceSession: HKWorkoutSession
    ) {
        guard session === sourceSession else { return }
        for payload in payloads {
            guard let message = try? JSONDecoder().decode(SessionMessage.self, from: payload) else { continue }
            onRemoteMessage?(message)
        }
    }

    private func handleRemoteDisconnect(
        session sourceSession: HKWorkoutSession,
        error: Error?
    ) {
        guard session === sourceSession else { return }
        isRemoteConnected = false
        onRemoteDisconnect?(error)
        // Do not end/discard: wrist sensing and the local protocol continue.
    }

    private func handleSessionFailure(
        session sourceSession: HKWorkoutSession,
        error: Error
    ) {
        guard session === sourceSession else { return }
        onHR = nil
        isRemoteConnected = false
        sourceSession.delegate = nil
        builder?.delegate = nil
        builder?.discardWorkout()
        route.discard()
        segments.reset()
        session = nil
        builder = nil
        onSessionFailure?(error)
    }

    private func handleStateChange(
        session sourceSession: HKWorkoutSession,
        to state: HKWorkoutSessionState
    ) {
        guard session === sourceSession, state == .ended else { return }
        onHR = nil
        isRemoteConnected = false
        sourceSession.delegate = nil
        builder?.delegate = nil
        builder?.discardWorkout()
        route.discard()
        segments.reset()
        session = nil
        builder = nil
        onSessionEnded?()
    }
}

extension WatchWorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor [weak self] in
            self?.handleStateChange(session: workoutSession, to: toState)
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.handleSessionFailure(session: workoutSession, error: error)
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        Task { @MainActor [weak self] in
            self?.handleRemoteData(data, from: workoutSession)
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didDisconnectFromRemoteDeviceWithError error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.handleRemoteDisconnect(session: workoutSession, error: error)
        }
    }
}

extension WatchWorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        guard let hr = WatchWorkoutManager.heartRateType, collectedTypes.contains(hr) else { return }
        let unit = HKUnit.count().unitDivided(by: .minute())
        guard let stats = workoutBuilder.statistics(for: hr),
              let bpm = stats.mostRecentQuantity()?.doubleValue(for: unit) else { return }
        let date = stats.mostRecentQuantityDateInterval()?.end ?? Date()
        Task { @MainActor [weak self] in self?.onHR?(bpm, date) }
    }
}
