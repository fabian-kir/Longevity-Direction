import Foundation
import HealthKit
import IntervalEngine

/// Bridges both HealthKit workout roles used by the phone:
///
/// - A local standalone session reads an external HR source when no Watch is
///   available.
/// - An incoming mirrored session represents the Watch's wrist-sensor workout.
///   It never owns a local builder and is kept separate from the fallback
///   session so a mirroring disconnect cannot stop an already-running protocol.
@MainActor
final class PhoneWorkoutManager: NSObject {
    private let healthStore = HKHealthStore()

    private var localSession: HKWorkoutSession?
    private var localBuilder: HKLiveWorkoutBuilder?
    private var mirroredSession: HKWorkoutSession?
    private var onHR: ((Double, Date) -> Void)?
    private var segments = PhaseSegmentTracker()
    private lazy var route = WorkoutRouteRecorder(healthStore: healthStore)

    /// Called when HealthKit delivers the Watch's mirrored workout session. The
    /// `didSet` replay avoids losing a session that arrived during app launch,
    /// before the session model had installed its callbacks.
    var onMirroredSessionStart: ((HKWorkoutSession) -> Void)? {
        didSet {
            if let mirroredSession {
                onMirroredSessionStart?(mirroredSession)
            }
        }
    }

    /// A dropped mirror is a transport event only. The owner decides whether to
    /// fail over; this manager deliberately does not end the local timer/session.
    var onMirroredSessionDisconnect: ((Error?) -> Void)?

    /// Decoded app state/control data received over HealthKit mirroring.
    var onRemoteMessage: ((SessionMessage) -> Void)?

    /// The local external-sensor workout failed. The protocol owner keeps its
    /// engine running and may retry without treating this as a stop event.
    var onLocalSessionFailure: ((Error) -> Void)?

    var hasMirroredSession: Bool { mirroredSession != nil }
    var hasLocalSession: Bool { localSession != nil && localBuilder != nil }

    // `nonisolated`: pure computed HealthKit lookups with no stored state, so the
    // nonisolated builder delegate (below) can read them off the main actor.
    private nonisolated static var bpmUnit: HKUnit { HKUnit.count().unitDivided(by: .minute()) }
    private nonisolated static var heartRateType: HKQuantityType? {
        HKObjectType.quantityType(forIdentifier: .heartRate)
    }

    override init() {
        super.init()

        // Apple requires this to be installed promptly at app launch. HealthKit
        // invokes it on an arbitrary queue, so hand ownership to the main actor
        // before touching manager state or application callbacks.
        healthStore.workoutSessionMirroringStartHandler = { [weak self] session in
            Task { @MainActor [weak self] in
                self?.acceptMirroredSession(session)
            }
        }
    }

    /// Launch or wake the Watch app with the workout type for `equipment`. The
    /// Watch creates the primary wrist-sensor session and starts mirroring it
    /// back.
    @discardableResult
    func startWatchApp(equipment: WorkoutEquipment, mode: WorkoutMode) async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        do {
            try await healthStore.startWatchApp(toHandle: equipment.workoutConfiguration(for: mode))
            return true
        } catch {
            return false
        }
    }

    /// Start a workout session of the type matching `equipment` and begin
    /// streaming HR. Returns `false` if a session can't be created (no
    /// HealthKit / no sensor) so the caller can degrade to timer-only.
    @discardableResult
    func startLocal(
        equipment: WorkoutEquipment,
        mode: WorkoutMode,
        onHR: @escaping (Double, Date) -> Void
    ) -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        self.onHR = onHR

        if localSession != nil {
            return true
        }

        let config = equipment.workoutConfiguration(for: mode)

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self
            localSession = session
            localBuilder = builder

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

    /// Stop only the phone's standalone source. An incoming Watch mirror is not
    /// touched, which lets the protocol continue while roles are being resynced.
    /// Marks phase boundaries for the saved workout's segments.
    func observePhase(_ kind: PhaseKind, label: String, at date: Date) {
        guard localSession != nil else { return }
        segments.observe(kind: kind, label: label, at: date)
    }

    func stopLocal() {
        if localSession != nil {
            route.discard()
            segments.reset()
        }
        onHR = nil
        localSession?.delegate = nil
        localBuilder?.delegate = nil
        localSession?.end()
        // Handoffs, retries, and explicit stops are not completed workouts.
        // Discard them; the natural completion path finalizes the builder.
        localBuilder?.discardWorkout()
        localSession = nil
        localBuilder = nil
    }

    /// Ends collection and asks HealthKit to create the completed workout with
    /// a segment per phase. State is detached synchronously so ordinary
    /// teardown cannot discard the builder while the asynchronous save is in
    /// flight.
    @discardableResult
    func completeLocalWorkout(
        at endDate: Date,
        sessionID: UUID,
        mode: WorkoutMode,
        equipment: WorkoutEquipment,
        completion: @escaping (Error?) -> Void
    ) -> Bool {
        guard let session = localSession, let builder = localBuilder else { return false }
        let events = WorkoutHealthMetadata.segmentEvents(segments.finish(at: endDate))
        segments.reset()
        let pendingRoute = route.stop()

        onHR = nil
        localSession = nil
        localBuilder = nil
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

    /// Detach all HealthKit transports owned by this run. The mirrored session
    /// is not ended here: ending the Watch's primary is an explicit `.stop`
    /// protocol action, while ordinary view teardown must not interrupt it.
    func teardown() {
        stopLocal()
        mirroredSession?.delegate = nil
        mirroredSession = nil
    }

    /// End the Watch-owned workout through HealthKit as a redundant explicit-stop
    /// signal. The command channel still carries the terminal session ID.
    func endMirroredSession() {
        mirroredSession?.end()
    }

    /// Send current protocol state or a control command to the Watch primary.
    /// This callback-based entry point starts the HealthKit transfer before the
    /// caller can tear down a terminal session, so final/stop packets are not
    /// lost merely because an unstructured Task had not begun executing yet.
    @discardableResult
    func beginSendingToRemote(_ message: SessionMessage) -> Bool {
        guard let mirroredSession,
              let data = try? JSONEncoder().encode(message) else { return false }
        mirroredSession.sendToRemoteWorkoutSession(data: data) { _, _ in }
        return true
    }

    /// Send current protocol state or a control command to the Watch primary.
    @discardableResult
    func sendToRemote(_ message: SessionMessage) async -> Bool {
        guard let mirroredSession,
              let data = try? JSONEncoder().encode(message) else { return false }
        do {
            try await mirroredSession.sendToRemoteWorkoutSession(data: data)
            return true
        } catch {
            return false
        }
    }

    // Compatibility alias while callers migrate to the role-explicit API.
    func stop() {
        teardown()
    }

    private func acceptMirroredSession(_ session: HKWorkoutSession) {
        if mirroredSession !== session {
            mirroredSession?.delegate = nil
            mirroredSession = session
            session.delegate = self
        }
        onMirroredSessionStart?(session)
    }

    private func handleMirroredDisconnect(
        session: HKWorkoutSession,
        error: Error?
    ) {
        guard mirroredSession === session else { return }
        session.delegate = nil
        mirroredSession = nil
        onMirroredSessionDisconnect?(error)
    }

    private func handleSessionFailure(
        session: HKWorkoutSession,
        error: Error
    ) {
        if mirroredSession === session {
            handleMirroredDisconnect(session: session, error: error)
        } else if localSession === session {
            onHR = nil
            route.discard()
            segments.reset()
            localBuilder?.delegate = nil
            localBuilder?.discardWorkout()
            localBuilder = nil
            localSession = nil
            onLocalSessionFailure?(error)
        }
    }

    private func handleRemoteData(
        _ payloads: [Data],
        from session: HKWorkoutSession
    ) {
        guard mirroredSession === session else { return }
        for payload in payloads {
            guard let message = try? JSONDecoder().decode(SessionMessage.self, from: payload) else { continue }
            onRemoteMessage?(message)
        }
    }
}

extension PhoneWorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {}

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
            self?.handleMirroredDisconnect(session: workoutSession, error: error)
        }
    }
}

extension PhoneWorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        guard let hr = PhoneWorkoutManager.heartRateType, collectedTypes.contains(hr) else { return }
        guard let stats = workoutBuilder.statistics(for: hr),
              let bpm = stats.mostRecentQuantity()?.doubleValue(for: PhoneWorkoutManager.bpmUnit) else { return }
        let date = stats.mostRecentQuantityDateInterval()?.end ?? Date()
        Task { @MainActor [weak self] in self?.onHR?(bpm, date) }
    }
}
