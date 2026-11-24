import Foundation

/// Where the trailing-average HR sits relative to the target band's dead-band.
public enum DeadBandState: Equatable, Sendable, Codable {
    /// No HR target for this phase, or no HR/HRmax available (timer-only).
    case noTarget
    /// Inside the ±8 bpm dead-band around the target.
    case inRange
    /// Below the dead-band — the user should push harder.
    case below
    /// Above the dead-band — the user should ease off.
    case above
}

/// Direction hint for the Live Activity arrow (spec §6.3): shown only when the
/// user is outside the dead-band and needs to adjust.
public enum AdjustmentHint: Equatable, Hashable, Sendable, Codable {
    case none
    case up      // raise HR (currently below target)
    case down    // lower HR (currently above target)
}

/// A coaching haptic the engine wants fired (spec §4). The app layer maps these
/// to concrete Taptic patterns; the engine stays platform-agnostic.
public enum HapticCommand: Equatable, Sendable, Codable {
    case goHarder          // repeating, below target
    case chill             // repeating, above target
    case phaseTransition   // one-shot, on every phase boundary
}

/// Immutable snapshot of engine state at one instant — everything the phone UI,
/// watch UI and Live Activity need to render, and everything the mirror device
/// re-renders when following the primary (spec §5.2).
public struct EngineOutput: Equatable, Sendable, Codable {
    public let phase: PhaseKind
    public let phaseLabel: String
    public let ringColor: RingColor
    /// Current-phase progress 0...1 — resets at each phase boundary (spec §6.1).
    public let phaseProgress: Double
    public let timeRemainingInPhase: TimeInterval
    public let elapsed: TimeInterval
    public let totalRemaining: TimeInterval
    /// Absolute target band in bpm. During the 60s ramp `lowerBound == upperBound`
    /// (a moving line); after the ramp it opens to the full band. `nil` for
    /// warm-up/cooldown and in timer-only mode.
    public let target: ClosedRange<Double>?
    /// Latest heart-rate sample while it is still considered fresh. The
    /// established property name is retained for wire-format compatibility.
    public let trailingHR: Double?
    public let deadBandState: DeadBandState
    public let adjustmentHint: AdjustmentHint
    public let isPaused: Bool
    public let isFinished: Bool
    /// Colour of the following phase, for the anticipatory ring fill. `nil`
    /// during the last phase. Optional so older snapshots still decode.
    public let nextRingColor: RingColor?
}

/// Deterministic interval control engine (spec §5.1). Runs the Norwegian 4x4
/// by default, or any ``ProtocolConfig`` (Hold HR, heart check).
///
/// Given a start timestamp, the fixed config, and a stream of HR samples, it
/// computes current phase, target-line value, dead-band state, ring progress and
/// haptic commands. All time is injected via `at:` parameters — the engine never
/// reads the wall clock itself, which is what makes it unit-testable without a
/// device and keeps two mirrored devices in lockstep by construction.
public final class IntervalEngine {

    // MARK: Tunables (spec §4)
    /// Default dead-band of the standard 4×4 protocol. Each config carries its
    /// own tolerance (``ProtocolConfig/deadBand``).
    public static let deadBandBPM: Double = 8
    /// Apple Watch heart-rate samples can arrive more than ten seconds apart.
    /// Keep the most recent reading visible long enough to avoid flickering to
    /// an unavailable state between valid sensor updates.
    public static let heartRateFreshnessWindow: TimeInterval = 20
    private static let bufferRetention: TimeInterval = 30
    private static let intervalJustOutside: TimeInterval = 20
    private static let intervalFloor: TimeInterval = 5
    private static let intervalFloorDistance: Double = 20

    public let config: ProtocolConfig
    public let hrMax: Double?
    public private(set) var startedAt: Date

    // Clock state (pause/skip shift wall-time → protocol-elapsed).
    private var pausedAt: Date?
    private var accumulatedPause: TimeInterval = 0
    private var skipOffset: TimeInterval = 0

    // HR + guidance state.
    private var hrBuffer: [(t: Date, bpm: Double)] = []
    private var lastPhaseKind: PhaseKind?
    private var phaseStartHR: Double?
    private var lastGuidance: (state: DeadBandState, at: Date)?
    private var finished = false
    /// Protocol-elapsed time at completion; earlier than the total when the
    /// session was finished early.
    private var finishedElapsed: TimeInterval?

    public init(config: ProtocolConfig = .norwegian4x4, hrMax: Double?, startedAt: Date) {
        self.config = config
        self.hrMax = hrMax
        self.startedAt = startedAt
    }

    /// Restores an engine from a transport-safe checkpoint. The checkpoint's
    /// own config wins; `config` only applies to checkpoints that predate it.
    ///
    /// Keeping the original absolute timestamps is intentional: a running
    /// protocol advances across a connectivity outage, while a paused protocol
    /// remains frozen until it is resumed. Set `includeHeartRateHistory` to
    /// `false` when sensor authority changes so samples from two sensors are not
    /// mixed in the trailing average. Ramp and timeline state are still kept.
    public init(
        config: ProtocolConfig = .norwegian4x4,
        checkpoint: EngineCheckpoint,
        includeHeartRateHistory: Bool = true
    ) {
        self.config = checkpoint.config ?? config
        self.hrMax = checkpoint.hrMax
        self.startedAt = checkpoint.startedAt
        self.pausedAt = checkpoint.pausedAt
        self.accumulatedPause = checkpoint.accumulatedPause
        self.skipOffset = checkpoint.skipOffset
        self.hrBuffer = includeHeartRateHistory
            ? checkpoint.heartRateSamples.map { (t: $0.timestamp, bpm: $0.bpm) }
            : []
        self.lastPhaseKind = checkpoint.lastPhaseKind
        self.phaseStartHR = checkpoint.phaseStartHR
        self.lastGuidance = checkpoint.lastGuidance.map { (state: $0.state, at: $0.timestamp) }
        self.finished = checkpoint.isFinished
        self.finishedElapsed = checkpoint.finishedElapsed
    }

    /// Captures every mutable input needed to continue the deterministic engine
    /// on this or another device without restarting the protocol.
    public func checkpoint() -> EngineCheckpoint {
        EngineCheckpoint(
            hrMax: hrMax,
            startedAt: startedAt,
            pausedAt: pausedAt,
            accumulatedPause: accumulatedPause,
            skipOffset: skipOffset,
            heartRateSamples: hrBuffer.map {
                EngineCheckpoint.HeartRateSample(timestamp: $0.t, bpm: $0.bpm)
            },
            lastPhaseKind: lastPhaseKind,
            phaseStartHR: phaseStartHR,
            lastGuidance: lastGuidance.map {
                EngineCheckpoint.Guidance(state: $0.state, timestamp: $0.at)
            },
            isFinished: finished,
            config: config,
            finishedElapsed: finishedElapsed
        )
    }

    // MARK: - Control (spec §7)

    public var isPaused: Bool { pausedAt != nil }

    public func pause(at now: Date) {
        guard pausedAt == nil else { return }
        pausedAt = now
    }

    public func resume(at now: Date) {
        guard let pausedAt else { return }
        accumulatedPause += now.timeIntervalSince(pausedAt)
        self.pausedAt = nil
    }

    /// Applies desired pause state rather than toggling it. This makes repeated
    /// or retried wire commands idempotent.
    public func setPaused(_ shouldPause: Bool, at now: Date) {
        if shouldPause {
            pause(at: now)
        } else {
            resume(at: now)
        }
    }

    /// Skips the remainder of the current phase, jumping the clock to the next
    /// phase boundary. Only permitted for skippable phases (warm-up/cooldown).
    /// Returns `true` if a skip occurred.
    @discardableResult
    public func skip(at now: Date) -> Bool {
        let e = elapsed(at: now)
        guard let index = config.phaseIndex(atElapsed: e), config.phases[index].kind.isSkippable else {
            return false
        }
        skipOffset += config.phases[index].endOffset - e
        return true
    }

    /// Whether an explicit End at `now` should complete (and save) the session
    /// rather than discard it.
    public func endCompletesSession(at now: Date) -> Bool {
        guard let threshold = config.finishesEarlyAfter else { return false }
        return elapsed(at: now) >= threshold
    }

    /// Completes the session now, as if its last phase had ended. Used by
    /// open-ended routines (Hold HR) whose End means "done", not "abort".
    public func finish(at now: Date) {
        guard !finished else { return }
        finished = true
        finishedElapsed = min(max(elapsed(at: now), 0), config.totalDuration)
        pausedAt = nil
    }

    // MARK: - Input

    public func ingest(hrSample bpm: Double, at t: Date) {
        hrBuffer.append((t, bpm))
        let cutoff = t.addingTimeInterval(-Self.bufferRetention)
        if hrBuffer.first != nil, hrBuffer[0].t < cutoff {
            hrBuffer.removeAll { $0.t < cutoff }
        }
    }

    // MARK: - Timeline

    /// Protocol-elapsed seconds at `now`, accounting for pauses and skips. Frozen
    /// while paused.
    public func elapsed(at now: Date) -> TimeInterval {
        let reference = pausedAt ?? now
        return reference.timeIntervalSince(startedAt) - accumulatedPause + skipOffset
    }

    /// Most recent HR sample at or before `now`, or `nil` once it is older than
    /// `heartRateFreshnessWindow`. The established method name is retained for
    /// compatibility with the existing engine and synchronization API.
    public func trailingHR(at now: Date) -> Double? {
        let freshnessCutoff = now.addingTimeInterval(-Self.heartRateFreshnessWindow)
        return hrBuffer
            .filter { $0.t >= freshnessCutoff && $0.t <= now }
            .max(by: { $0.t < $1.t })?
            .bpm
    }

    // MARK: - Step

    /// Advances the engine to `now`, returning the current output snapshot plus
    /// any haptic commands generated since the last tick. Deterministic in
    /// `(startedAt, control events, HR samples, now)`.
    @discardableResult
    public func tick(at now: Date) -> (output: EngineOutput, haptics: [HapticCommand]) {
        var haptics: [HapticCommand] = []
        let e = elapsed(at: now)

        // Completion is terminal. In particular, restoring a finished
        // checkpoint must never resurrect the final phase if a clock moves
        // backwards or a stale tick arrives.
        if finished {
            return (finishedOutput(elapsed: finishedElapsed ?? config.totalDuration, at: now), haptics)
        }

        guard let index = config.phaseIndex(atElapsed: e) else {
            finished = true
            finishedElapsed = config.totalDuration
            return (finishedOutput(elapsed: config.totalDuration, at: now), haptics)
        }

        let phase = config.phases[index]
        let hr = trailingHR(at: now)

        // Phase-transition detection (one-shot haptic, never on the very first tick).
        if let previous = lastPhaseKind, previous != phase.kind {
            haptics.append(.phaseTransition)
            phaseStartHR = hr
            lastGuidance = nil
        } else if lastPhaseKind == nil {
            phaseStartHR = hr
        }
        lastPhaseKind = phase.kind

        // Late-capture the ramp origin if HR wasn't available at the boundary.
        if phaseStartHR == nil { phaseStartHR = hr }

        let tInPhase = e - phase.startOffset
        let target = targetBand(phase: phase, tInPhase: tInPhase)
        let (state, hint) = deadBandState(hr: hr, target: target)

        // Guidance haptics (only when a target exists, HR is known, and we're
        // outside the dead-band). Repeat rate scales with distance (spec §4).
        if state == .below || state == .above, let hr, let target {
            let distance = distanceOutsideDeadBand(hr: hr, target: target, state: state)
            let interval = Self.guidanceInterval(distanceOutside: distance)
            let sideChanged = lastGuidance?.state != state
            let due = lastGuidance.map { now.timeIntervalSince($0.at) >= interval } ?? true
            if sideChanged || due {
                haptics.append(state == .below ? .goHarder : .chill)
                lastGuidance = (state, now)
            }
        } else {
            lastGuidance = nil
        }

        let output = EngineOutput(
            phase: phase.kind,
            phaseLabel: phase.label,
            ringColor: phase.kind.ringColor,
            phaseProgress: min(max(tInPhase / phase.duration, 0), 1),
            timeRemainingInPhase: max(phase.duration - tInPhase, 0),
            elapsed: e,
            totalRemaining: max(config.totalDuration - e, 0),
            target: target,
            trailingHR: hr,
            deadBandState: state,
            adjustmentHint: hint,
            isPaused: isPaused,
            isFinished: false,
            nextRingColor: config.nextRingColor(after: index)
        )
        return (output, haptics)
    }

    // MARK: - Target line (spec §3)

    private func targetBand(phase: Phase, tInPhase: TimeInterval) -> ClosedRange<Double>? {
        guard let band = phase.target?.resolved(hrMax: hrMax) else { return nil }

        // Hold as a full band once the ramp completes, or if we never captured a
        // ramp origin (no HR at phase start → degrade to the band immediately).
        guard tInPhase < config.rampDuration, let origin = phaseStartHR else { return band }

        // Ramp linearly from the phase-start HR to the nearest band edge, then the
        // caller opens it to the full band at ramp end.
        let destination = min(max(origin, band.lowerBound), band.upperBound)
        let progress = min(max(tInPhase / config.rampDuration, 0), 1)
        let value = origin + (destination - origin) * progress
        return value...value
    }

    private func deadBandState(hr: Double?, target: ClosedRange<Double>?) -> (DeadBandState, AdjustmentHint) {
        guard let hr, let target else { return (.noTarget, .none) }
        let low = target.lowerBound - config.deadBand
        let high = target.upperBound + config.deadBand
        if hr < low { return (.below, .up) }
        if hr > high { return (.above, .down) }
        return (.inRange, .none)
    }

    private func distanceOutsideDeadBand(hr: Double, target: ClosedRange<Double>, state: DeadBandState) -> Double {
        switch state {
        case .below: return (target.lowerBound - config.deadBand) - hr
        case .above: return hr - (target.upperBound + config.deadBand)
        default:     return 0
        }
    }

    /// Maps distance outside the dead-band to a repeat interval: ~20s just
    /// outside, tightening linearly to a 5s floor at ≥20 bpm off (spec §4).
    static func guidanceInterval(distanceOutside distance: Double) -> TimeInterval {
        let capped = min(max(distance, 0), intervalFloorDistance)
        let span = intervalJustOutside - intervalFloor
        return intervalJustOutside - span * (capped / intervalFloorDistance)
    }

    private func finishedOutput(elapsed: TimeInterval, at now: Date) -> EngineOutput {
        let lastPhase = config.phases.last
        let last = lastPhase?.kind ?? .cooldown
        return EngineOutput(
            phase: last,
            phaseLabel: lastPhase?.label ?? "Complete",
            ringColor: last.ringColor,
            phaseProgress: 1,
            timeRemainingInPhase: 0,
            elapsed: min(elapsed, config.totalDuration),
            totalRemaining: 0,
            target: nil,
            trailingHR: trailingHR(at: now),
            deadBandState: .noTarget,
            adjustmentHint: .none,
            isPaused: isPaused,
            isFinished: true,
            nextRingColor: nil
        )
    }
}
