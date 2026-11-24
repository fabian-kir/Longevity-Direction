import Foundation
import IntervalEngine
import Observation

/// App-lifetime Watch coordinator for every guided routine (4×4, Hold HR,
/// heart check). Whenever a Watch is present it owns the protocol engine and
/// wrist heart-rate stream, regardless of which device the user used to start
/// the session. A phone checkpoint is adopted without
/// resetting elapsed time; connection loss never stops the local workout.
@Observable
@MainActor
final class WatchN4x4SessionModel {
    static let shared = WatchN4x4SessionModel()

    enum Stage: Equatable { case idle, active, mirroring, done }

    enum TimerOnlyReason: Equatable {
        case noHRMax
        case sensorFailed
        case noReadings
    }

    private(set) var stage: Stage = .idle
    private(set) var output: EngineOutput?
    private(set) var hrMax: Double?
    private(set) var heartRateSource: HeartRateSource = .none
    private(set) var latestHR: Double?
    private(set) var timerOnlyReason: TimerOnlyReason = .noHRMax
    var showTimerOnlyWarning = false
    /// Settings synced from iPhone. The equipment choice can also be changed
    /// on the Watch before a start.
    private(set) var settings: WorkoutSettings = WatchSettingsStore.load()
    /// Equipment of the running session (from the start screen, the phone's
    /// snapshot, or the configuration HealthKit launched us with).
    private(set) var equipment: WorkoutEquipment = .unspecified
    /// The running (or last finished) routine.
    private(set) var program: ProtocolConfig?
    /// HRmax for previews on the start screen (custom value or estimate).
    private(set) var displayMaxHR: Double?

    private let workout = WatchWorkoutManager()
    private let haptics = WatchHapticEngine()
    private let connectivity = WatchConnectivityManager()

    private var engine: IntervalEngine?
    private var currentSnapshot: SessionSnapshot?
    private var sessionID: UUID?
    private var sessionCreatedAt: Date?
    private var sequence: UInt64 = 0
    private var ticker: Task<Void, Never>?
    private var graceCheck: Task<Void, Never>?
    private var sensorRetryTask: Task<Void, Never>?
    private var systemStartTask: Task<Void, Never>?
    private var pendingStartID: UUID?
    private var receivedAnyHR = false
    private var heartRateSessionActive = false
    private var authorizationTask: Task<Bool, Never>?
    private var processedCommandIDs: Set<UUID> = []
    private var acknowledgedCommandIDs: [UUID] = []
    private var stoppedSessionIDs: Set<UUID> = []

    private var mockHR: Double = 80
    private var useMockHR = false

    init() {
        #if DEBUG
        useMockHR = MockMode.isActive
        #endif

        connectivity.onRemoteMessage = { [weak self] message in
            self?.handleRemoteMessage(message)
        }
        connectivity.onReachabilityChanged = { [weak self] reachable in
            self?.handleReachabilityChange(reachable)
        }
        connectivity.onSettings = { [weak self] settings in
            self?.applySyncedSettings(settings)
        }
        connectivity.activate()

        workout.onRemoteMessage = { [weak self] message in
            self?.handleRemoteMessage(message)
        }
        workout.onRemoteDisconnect = { _ in
            // Transport loss is deliberately not a workout/session event. The
            // wrist engine, sensor, timer, haptics, and status icon keep running.
        }
        workout.onSessionFailure = { [weak self] _ in
            self?.handleSensorSessionFailure()
        }
        workout.onSessionEnded = { [weak self] in
            // HealthKit's ended state does not identify *why* it ended. Preserve
            // the protocol unless the separately authenticated session command
            // says stop; meanwhile retry wrist sensing like any other failure.
            self?.handleSensorSessionFailure()
        }
    }

    func onAppear() {
        Task {
            _ = await ensureAuthorization()
            if let custom = settings.customMaxHeartRate {
                displayMaxHR = Double(custom)
            } else if !useMockHR {
                displayMaxHR = await workout.estimatedHRMax()
            } else {
                displayMaxHR = 188
            }
        }
    }

    func selectEquipment(_ equipment: WorkoutEquipment) {
        settings.lastEquipment = equipment
        WatchSettingsStore.save(settings)
    }

    private func applySyncedSettings(_ synced: WorkoutSettings) {
        settings = synced
        WatchSettingsStore.save(synced)
        if let custom = synced.customMaxHeartRate { displayMaxHR = Double(custom) }
    }

    private func ensureAuthorization() async -> Bool {
        if useMockHR { return true }
        if let authorizationTask { return await authorizationTask.value }

        let task = Task { [workout] in
            await workout.requestAuthorization()
        }
        authorizationTask = task
        return await task.value
    }

    /// Called by `WKApplicationDelegate` after iPhone uses HealthKit's
    /// `startWatchApp`. Give the pending WCSession checkpoint a short chance to
    /// arrive; if it does not, begin locally and reconcile when it does. The
    /// configuration tells us the phone's equipment choice.
    func handleSystemWorkoutStart(equipment launchEquipment: WorkoutEquipment) async {
        if stage != .active { equipment = launchEquipment }
        _ = await ensureAuthorization()
        if stage == .active {
            publishCurrentFrame()
            _ = await workout.startMirroring()
            return
        }

        systemStartTask?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled,
                  self.stage == .idle || self.stage == .done else { return }
            await self.startPrimary(mode: .n4x4, equipment: launchEquipment)
        }
        systemStartTask = task
        await task.value
    }

    // MARK: - Watch authority

    func startPrimary(mode: WorkoutMode, equipment requestedEquipment: WorkoutEquipment? = nil) async {
        guard stage == .idle || stage == .done else { return }
        _ = await ensureAuthorization()
        guard stage == .idle || stage == .done else { return }

        let startID = UUID()
        pendingStartID = startID
        let estimated: Double?
        if settings.customMaxHeartRate != nil {
            estimated = nil
        } else if useMockHR {
            estimated = 188
        } else {
            estimated = await workout.estimatedHRMax()
        }
        let maxHR = settings.resolvedMaxHeartRate(estimated: estimated)

        // A phone checkpoint or stop may have arrived while HealthKit queried.
        guard pendingStartID == startID,
              stage == .idle || stage == .done else { return }
        pendingStartID = nil

        let now = Date()
        equipment = requestedEquipment
            ?? (mode == .heartCheck ? settings.heartCheckWorkload?.equipment : nil)
            ?? settings.lastEquipment
        beginWatchAuthority(
            engine: IntervalEngine(
                config: settings.program(for: mode, hrMax: maxHR),
                hrMax: maxHR,
                startedAt: now
            ),
            sessionID: UUID(),
            createdAt: now,
            startingSequence: 0
        )
    }

    private func beginWatchAuthority(
        engine: IntervalEngine,
        sessionID: UUID,
        createdAt: Date,
        startingSequence: UInt64,
        initialAcknowledgedCommandIDs: [UUID] = [],
        lastKnownHR: Double? = nil
    ) {
        let continuesExistingSession = self.sessionID == sessionID
        cancelRuntimeTasks()

        // Swapping protocol checkpoints must not restart a healthy optical
        // workout. `start` reuses the existing session and only updates its HR
        // callback, avoiding a sensor/indicator gap during phone handoff.
        if !continuesExistingSession {
            acknowledgedCommandIDs = initialAcknowledgedCommandIDs
        } else {
            for commandID in initialAcknowledgedCommandIDs { acknowledge(commandID) }
        }
        processedCommandIDs.formUnion(initialAcknowledgedCommandIDs)

        self.engine = engine
        self.sessionID = sessionID
        sessionCreatedAt = createdAt
        sequence = startingSequence
        hrMax = engine.hrMax
        program = engine.config
        receivedAnyHR = false
        latestHR = nil
        heartRateSource = .none
        heartRateSessionActive = false
        showTimerOnlyWarning = false
        // Taking over a running session must continue from its last heart
        // rate; restarting the simulated pulse at rest draws a false dip.
        mockHR = lastKnownHR ?? 80
        stage = .active

        let result = engine.tick(at: Date())
        output = result.output
        _ = beginSensing()
        publish(result.output)
        ticker = Task { [weak self, weak engine] in
            guard let engine else { return }
            await self?.runLoop(engine: engine, sessionID: sessionID)
        }
    }

    @discardableResult
    private func beginSensing() -> Bool {
        guard stage == .active else { return false }
        if useMockHR {
            heartRateSessionActive = true
            return true
        }
        let opened = workout.start(
            equipment: equipment,
            mode: engine?.config.mode ?? .n4x4
        ) { [weak self] bpm, date in
            self?.ingest(bpm: bpm, at: date)
        }
        heartRateSessionActive = opened
        if !opened {
            timerOnlyReason = .sensorFailed
            showTimerOnlyWarning = true
            scheduleSensorRetry()
        } else if hrMax == nil, engine?.config.requiresMaxHeartRate == true {
            timerOnlyReason = .noHRMax
            showTimerOnlyWarning = true
            scheduleHRArrivalCheck()
        } else {
            scheduleHRArrivalCheck()
        }
        if opened {
            if engine?.isPaused == true { workout.pause() } else { workout.resume() }
        }
        return opened
    }

    private func scheduleSensorRetry() {
        guard sensorRetryTask == nil else { return }
        sensorRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.stage == .active else { return }
                if self.beginSensing() {
                    self.sensorRetryTask = nil
                    self.showTimerOnlyWarning = self.hrMax == nil
                        && self.engine?.config.requiresMaxHeartRate == true
                    self.publishCurrentFrame()
                    return
                }
            }
        }
    }

    private func handleSensorSessionFailure() {
        guard stage == .active else { return }
        heartRateSessionActive = false
        receivedAnyHR = false
        heartRateSource = .none
        timerOnlyReason = .sensorFailed
        showTimerOnlyWarning = true
        publishCurrentFrame()
        scheduleSensorRetry()
    }

    private func scheduleHRArrivalCheck() {
        graceCheck?.cancel()
        graceCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, self.stage == .active, !self.useMockHR else { return }
            if !self.receivedAnyHR {
                self.timerOnlyReason = .noReadings
                self.showTimerOnlyWarning = true
            }
        }
    }

    // MARK: - Reconciliation

    private func handleRemoteMessage(_ message: SessionMessage) {
        switch message {
        case .snapshot(let snapshot):
            handleRemoteSnapshot(snapshot)
        case .command(let command):
            handleRemoteCommand(command)
        }
    }

    private func handleRemoteSnapshot(_ remote: SessionSnapshot) {
        guard !stoppedSessionIDs.contains(remote.sessionID) else { return }

        let localForConflict = stage == .active ? currentSnapshot : nil
        guard SessionReconciliation.shouldAdopt(
            remote: remote,
            over: localForConflict,
            localDevice: .watch
        ) else {
            if stage == .active { publishCurrentFrame() }
            return
        }

        guard remote.authority == .phone else { return }
        if remote.output.isFinished {
            stoppedSessionIDs.insert(remote.sessionID)
            trimTerminalHistory()
            stopRuntime(clearOutput: false, finalStage: .done)
            output = remote.output
            currentSnapshot = remote
            return
        }

        if let remoteEquipment = remote.equipment, remote.sessionID != sessionID {
            equipment = remoteEquipment
        }

        // Preserve all clock/pause/skip/ramp state, but start a clean HR buffer:
        // from this moment the Watch optical sensor is the sole HR authority.
        let restored = IntervalEngine(
            checkpoint: remote.checkpoint,
            includeHeartRateHistory: false
        )
        beginWatchAuthority(
            engine: restored,
            sessionID: remote.sessionID,
            createdAt: remote.createdAt,
            startingSequence: remote.sequence,
            initialAcknowledgedCommandIDs: remote.acknowledgedCommandIDs,
            lastKnownHR: remote.output.trailingHR
        )
    }

    private func handleReachabilityChange(_ reachable: Bool) {
        guard stage == .active else { return }
        if reachable {
            publishCurrentFrame()
            Task { _ = await workout.startMirroring() }
        }
        // On loss there is intentionally nothing to do: Watch is already the
        // local authority and its HKWorkoutSession keeps it alive in background.
    }

    // MARK: - Controls

    func pauseResume() {
        guard let output else { return }
        performLocalAction(.setPaused(!output.isPaused), broadcastCommand: true)
    }

    @discardableResult
    func skip() -> Bool {
        guard canSkip else { return false }
        performLocalAction(.skip, broadcastCommand: true)
        return true
    }

    var canSkip: Bool {
        stage == .active
            && output?.phase.isSkippable == true
            && !(output?.isFinished ?? false)
    }

    var canControl: Bool { stage == .active }

    /// True when End would complete and save the session (Hold HR after five
    /// minutes) rather than discard it.
    var endCompletesSession: Bool {
        stage == .active && engine?.endCompletesSession(at: .now) == true
    }

    func end() {
        guard let sessionID else { return }
        if endCompletesSession {
            performLocalAction(.finish, broadcastCommand: true)
            return
        }
        let command = SessionCommand(sessionID: sessionID, action: .stop)
        stoppedSessionIDs.insert(sessionID)
        trimTerminalHistory()
        broadcast(.command(command))
        stopRuntime(clearOutput: true, finalStage: .idle)
    }

    private func handleRemoteCommand(_ command: SessionCommand) {
        guard !processedCommandIDs.contains(command.id),
              !acknowledgedCommandIDs.contains(command.id) else { return }
        remember(command.id)

        if case .stop = command.action {
            stoppedSessionIDs.insert(command.sessionID)
            trimTerminalHistory()
            guard command.sessionID == sessionID else { return }
            stopRuntime(clearOutput: true, finalStage: .idle)
            return
        }

        guard command.sessionID == sessionID,
              !stoppedSessionIDs.contains(command.sessionID) else { return }
        acknowledge(command.id)

        switch command.action {
        case .setPaused, .skip, .finish:
            performLocalAction(
                command.action,
                at: command.issuedAt,
                broadcastCommand: false
            )
        case .requestSync:
            publishCurrentFrame()
        case .stop:
            break
        }
    }

    private func performLocalAction(
        _ action: SessionCommand.Action,
        at now: Date = .now,
        broadcastCommand: Bool
    ) {
        guard stage == .active, let engine else { return }
        let outgoingCommand: SessionCommand? = if broadcastCommand, let sessionID {
            SessionCommand(sessionID: sessionID, issuedAt: now, action: action)
        } else {
            nil
        }
        if let outgoingCommand {
            remember(outgoingCommand.id)
            acknowledge(outgoingCommand.id)
        }
        switch action {
        case .setPaused(let paused):
            engine.setPaused(paused, at: now)
            if paused { workout.pause() } else { workout.resume() }
        case .skip:
            _ = engine.skip(at: now)
        case .finish:
            engine.finish(at: now)
        case .stop, .requestSync:
            return
        }

        let result = engine.tick(at: now)
        output = result.output
        if let outgoingCommand {
            broadcast(.command(outgoingCommand))
        }
        publish(result.output)
        if result.output.isFinished, let sessionID {
            completeSession(sessionID)
        }
    }

    // MARK: - Engine loop / HR

    private func ingest(bpm: Double, at date: Date) {
        guard stage == .active, let engine else { return }
        receivedAnyHR = true
        latestHR = bpm
        heartRateSource = .watch
        if timerOnlyReason == .noReadings || timerOnlyReason == .sensorFailed {
            showTimerOnlyWarning = false
        }
        engine.ingest(hrSample: bpm, at: date)
    }

    private func runLoop(engine: IntervalEngine, sessionID expectedSessionID: UUID) async {
        while !Task.isCancelled,
              stage == .active,
              sessionID == expectedSessionID,
              self.engine === engine {
            let now = Date()
            if useMockHR, !engine.isPaused {
                let bpm = nextMockHR()
                engine.ingest(hrSample: bpm, at: now)
                latestHR = bpm
                receivedAnyHR = true
                heartRateSource = .watch
            }

            let result = engine.tick(at: now)
            output = result.output
            publish(result.output)
            for command in result.haptics { haptics.play(command) }

            if result.output.isFinished {
                completeSession(expectedSessionID)
                return
            }
            workout.observePhase(result.output.phase, label: result.output.phaseLabel, at: now)
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func completeSession(_ completedSessionID: UUID) {
        stoppedSessionIDs.insert(completedSessionID)
        trimTerminalHistory()
        stopRuntime(
            clearOutput: false,
            finalStage: .done,
            completedSessionID: completedSessionID
        )
    }

    private func publishCurrentFrame() {
        guard stage == .active, let engine else { return }
        let result = engine.tick(at: Date())
        output = result.output
        publish(result.output)
    }

    private func publish(_ engineOutput: EngineOutput) {
        guard let engine, let sessionID, let createdAt = sessionCreatedAt else { return }
        sequence &+= 1
        let snapshot = SessionSnapshot(
            sessionID: sessionID,
            createdAt: createdAt,
            sequence: sequence,
            authority: .watch,
            heartRateSource: receivedAnyHR ? .watch : .none,
            heartRateSessionActive: heartRateSessionActive,
            acknowledgedCommandIDs: acknowledgedCommandIDs,
            output: engineOutput,
            checkpoint: engine.checkpoint(),
            equipment: equipment
        )
        currentSnapshot = snapshot
        heartRateSource = snapshot.heartRateSource
        broadcast(.snapshot(snapshot))
    }

    private func broadcast(_ message: SessionMessage) {
        connectivity.send(message)
        workout.beginSendingToRemote(message)
    }

    private func stopRuntime(
        clearOutput: Bool,
        finalStage: Stage,
        completedSessionID: UUID? = nil
    ) {
        pendingStartID = nil
        cancelRuntimeTasks()
        if let completedSessionID {
            _ = workout.completeWorkout(
                at: .now,
                sessionID: completedSessionID,
                mode: engine?.config.mode ?? .n4x4,
                equipment: equipment
            )
        } else {
            workout.teardown()
        }
        engine = nil
        stage = finalStage
        receivedAnyHR = false
        latestHR = nil
        heartRateSource = .none
        heartRateSessionActive = false
        acknowledgedCommandIDs.removeAll(keepingCapacity: true)
        sessionID = nil
        sessionCreatedAt = nil
        if clearOutput {
            output = nil
            currentSnapshot = nil
        }
    }

    private func cancelRuntimeTasks() {
        ticker?.cancel(); ticker = nil
        graceCheck?.cancel(); graceCheck = nil
        sensorRetryTask?.cancel(); sensorRetryTask = nil
        systemStartTask?.cancel(); systemStartTask = nil
    }

    private func remember(_ commandID: UUID) {
        processedCommandIDs.insert(commandID)
        if processedCommandIDs.count > 128 {
            processedCommandIDs.removeAll(keepingCapacity: true)
            processedCommandIDs.insert(commandID)
        }
    }

    private func acknowledge(_ commandID: UUID) {
        guard !acknowledgedCommandIDs.contains(commandID) else { return }
        acknowledgedCommandIDs.append(commandID)
        if acknowledgedCommandIDs.count > 32 {
            acknowledgedCommandIDs.removeFirst(acknowledgedCommandIDs.count - 32)
        }
    }

    private func trimTerminalHistory() {
        if stoppedSessionIDs.count > 32 {
            let current = sessionID
            stoppedSessionIDs.removeAll(keepingCapacity: true)
            if let current { stoppedSessionIDs.insert(current) }
        }
    }

    private func nextMockHR() -> Double {
        let desired: Double
        if let target = output?.target {
            desired = (target.lowerBound + target.upperBound) / 2
        } else if output?.phase == .fixedWorkload {
            desired = (hrMax ?? 190) * 0.72
        } else if output?.phase == .stillness {
            desired = (hrMax ?? 190) * 0.48
        } else {
            desired = (hrMax ?? 190) * 0.55
        }
        mockHR += (desired - mockHR) * 0.22 + Double.random(in: -2...2)
        return mockHR
    }
}
