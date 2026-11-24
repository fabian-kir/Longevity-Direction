import Foundation
import IntervalEngine
import Observation
import SwiftData

@Observable
@MainActor
final class N4x4WorkoutRecorder {
    private let context: ModelContext
    private var currentLog: N4x4WorkoutLog?
    private var framesSinceSave = 0

    private(set) var liveFrames: [N4x4WorkoutFrame] = []
    private(set) var lastCompletedLogID: UUID?

    init(context: ModelContext) {
        self.context = context
    }

    func begin(
        sessionID: UUID,
        startedAt: Date,
        hrMax: Double?,
        details: N4x4WorkoutDetails,
        program: ProtocolConfig = .norwegian4x4,
        workloadSummary: String? = nil
    ) {
        if currentLog?.sessionID == sessionID {
            // A Watch snapshot can name the equipment after the log began.
            if let currentLog, details.equipment != .unspecified, currentLog.equipment != details.equipment {
                currentLog.equipment = details.equipment
            }
            return
        }

        let descriptor = FetchDescriptor<N4x4WorkoutLog>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        let existing = try? context.fetch(descriptor).first
        let log = existing ?? N4x4WorkoutLog(
            sessionID: sessionID,
            startedAt: startedAt,
            estimatedHRMax: hrMax,
            equipment: details.equipment,
            mode: program.mode
        )
        if existing == nil {
            log.targetDeadBand = program.deadBand
            if program.mode == .heartCheck { log.workloadSummary = workloadSummary }
            context.insert(log)
        }

        currentLog = log
        liveFrames = log.frames
        framesSinceSave = 0
        try? context.save()
    }

    func record(
        output: EngineOutput,
        sessionID: UUID,
        startedAt: Date,
        hrMax: Double?,
        details: N4x4WorkoutDetails,
        program: ProtocolConfig = .norwegian4x4,
        workloadSummary: String? = nil,
        capturedAt: Date = .now
    ) {
        begin(
            sessionID: sessionID,
            startedAt: startedAt,
            hrMax: hrMax,
            details: details,
            program: program,
            workloadSummary: workloadSummary
        )
        guard let currentLog else { return }

        let frame = N4x4WorkoutFrame(capturedAt: capturedAt, output: output)
        if let last = liveFrames.last,
           abs(last.elapsed - frame.elapsed) < 0.5,
           last.bpm == frame.bpm,
           last.targetLower == frame.targetLower,
           last.targetUpper == frame.targetUpper {
            return
        }

        liveFrames.append(frame)
        currentLog.duration = max(currentLog.duration, output.elapsed)
        framesSinceSave += 1
        if framesSinceSave >= 10 || output.isFinished {
            flush()
        }
    }

    func finish(output: EngineOutput?, completed: Bool, healthKitRequested: Bool) {
        guard let currentLog else { return }
        if let output {
            record(
                output: output,
                sessionID: currentLog.sessionID,
                startedAt: currentLog.startedAt,
                hrMax: currentLog.estimatedHRMax,
                details: N4x4WorkoutDetails(equipment: currentLog.equipment)
            )
            currentLog.duration = output.elapsed
        }
        currentLog.endedAt = .now
        currentLog.isCompleted = completed
        currentLog.healthKitSaveState = healthKitRequested ? .requested : .notRequested
        updateSummary(on: currentLog)
        flush()
        if completed { lastCompletedLogID = currentLog.sessionID }
        self.currentLog = nil
    }

    func updateHealthKitResult(sessionID: UUID, error: Error?) {
        let descriptor = FetchDescriptor<N4x4WorkoutLog>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        guard let log = try? context.fetch(descriptor).first else { return }
        log.healthKitSaveState = error == nil ? .saved : .failed
        log.healthKitError = error?.localizedDescription
        try? context.save()
    }

    func log(for sessionID: UUID) -> N4x4WorkoutLog? {
        let descriptor = FetchDescriptor<N4x4WorkoutLog>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        return try? context.fetch(descriptor).first
    }

    func resetLiveFrames() {
        liveFrames = []
        lastCompletedLogID = nil
    }

    private func flush() {
        guard let currentLog else { return }
        currentLog.frames = liveFrames
        framesSinceSave = 0
        try? context.save()
    }

    private func updateSummary(on log: N4x4WorkoutLog) {
        let heartRates = liveFrames.compactMap(\.bpm)
        if !heartRates.isEmpty {
            log.averageHeartRate = heartRates.reduce(0, +) / Double(heartRates.count)
            log.peakHeartRate = heartRates.max()
        }

        let deadBand = log.targetDeadBand ?? IntervalEngine.deadBandBPM
        let targeted = liveFrames.compactMap { frame -> Bool? in
            guard let bpm = frame.bpm,
                  let low = frame.targetLower,
                  let high = frame.targetUpper else { return nil }
            return bpm >= low - deadBand && bpm <= high + deadBand
        }
        if !targeted.isEmpty {
            log.targetAdherence = Double(targeted.filter { $0 }.count) / Double(targeted.count)
        }

        log.averageOneMinuteRise = averageOneMinuteChange(for: .highIntensity, descending: false)
        log.averageOneMinuteRecovery = averageOneMinuteChange(for: .activeRecovery, descending: true)

        if log.mode == .heartCheck, let result = Self.heartCheckResult(from: liveFrames) {
            log.workloadHeartRate = result.workloadHeartRate
            log.stopHeartRate = result.stopHeartRate
            log.recoveryDropAfter60 = result.dropAfter60
            log.recoveryDropAfter120 = result.dropAfter120
        }
    }

    /// Workload HR is the mean of the workload's last minute; the drops are
    /// measured from the last workload reading to the readings nearest 60 s and
    /// 120 s into the stillness phase.
    static func heartCheckResult(from frames: [N4x4WorkoutFrame]) -> HeartCheckResult? {
        let workload = frames.filter { $0.phase == .fixedWorkload && $0.bpm != nil }
            .sorted { $0.elapsed < $1.elapsed }
        guard let lastWorkload = workload.last, let stopHR = lastWorkload.bpm else { return nil }
        let lastMinute = workload.filter { $0.elapsed >= lastWorkload.elapsed - 60 }.compactMap(\.bpm)
        guard !lastMinute.isEmpty else { return nil }

        let stillness = frames.filter { $0.phase == .stillness && $0.bpm != nil }
        let stopElapsed = stillness.map(\.elapsed).min() ?? lastWorkload.elapsed
        func reading(after seconds: TimeInterval) -> Double? {
            stillness
                .filter { abs($0.elapsed - (stopElapsed + seconds)) <= 6 }
                .min { abs($0.elapsed - (stopElapsed + seconds)) < abs($1.elapsed - (stopElapsed + seconds)) }?
                .bpm
        }

        return HeartCheckResult(
            workloadHeartRate: lastMinute.reduce(0, +) / Double(lastMinute.count),
            stopHeartRate: stopHR,
            dropAfter60: reading(after: 60).map { stopHR - $0 },
            dropAfter120: reading(after: 120).map { stopHR - $0 }
        )
    }

    private enum PhaseFamily { case highIntensity, activeRecovery }

    private func averageOneMinuteChange(for family: PhaseFamily, descending: Bool) -> Double? {
        let grouped = Dictionary(grouping: liveFrames) { frame -> String in
            switch frame.phase {
            case .highIntensity(let round): return "high-\(round)"
            case .activeRecovery(let round): return "recovery-\(round)"
            case .warmUp: return "warmup"
            case .cooldown: return "cooldown"
            case .steady: return "steady"
            case .fixedWorkload: return "workload"
            case .stillness: return "stillness"
            }
        }

        let values = grouped.values.compactMap { phaseFrames -> Double? in
            guard let phase = phaseFrames.first?.phase else { return nil }
            let matches = switch (family, phase) {
            case (.highIntensity, .highIntensity): true
            case (.activeRecovery, .activeRecovery): true
            default: false
            }
            guard matches,
                  let startFrame = phaseFrames.first(where: { $0.bpm != nil }),
                  let startBPM = startFrame.bpm else { return nil }
            let targetElapsed = startFrame.elapsed + 60
            guard let oneMinuteFrame = phaseFrames
                .filter({ $0.bpm != nil && $0.elapsed >= targetElapsed })
                .min(by: { $0.elapsed < $1.elapsed }),
                  let oneMinuteBPM = oneMinuteFrame.bpm else { return nil }
            return descending ? startBPM - oneMinuteBPM : oneMinuteBPM - startBPM
        }

        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
