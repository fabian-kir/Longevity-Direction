import Foundation

/// The kind of block within a session.
///
/// `round` is 1-based. High-intensity blocks run rounds 1...N; a recovery block
/// carries the round of the high block it *follows*. There is no recovery after
/// the last round — the protocol goes straight to cooldown (spec §2).
public enum PhaseKind: Equatable, Hashable, Sendable, Codable {
    case warmUp
    case highIntensity(round: Int)
    case activeRecovery(round: Int)
    case cooldown
    /// Hold-HR mode: one long block at a set heart rate.
    case steady
    /// Heart check: hold a fixed, repeatable workload.
    case fixedWorkload
    /// Heart check: stand still while the heart-rate drop is measured.
    case stillness
}

extension PhaseKind {
    /// Ring colour for this phase (spec §6): blue for warm-up/cooldown, red for
    /// high intensity, green for recovery and steady holds, amber for the heart
    /// check's fixed workload.
    public var ringColor: RingColor {
        switch self {
        case .warmUp, .cooldown, .stillness: return .blue
        case .highIntensity:                 return .red
        case .activeRecovery, .steady:       return .green
        case .fixedWorkload:                 return .amber
        }
    }

    /// Only warm-up and cooldown are skippable in-session (spec §7).
    public var isSkippable: Bool {
        switch self {
        case .warmUp, .cooldown: return true
        default:                 return false
        }
    }
}

public enum RingColor: Equatable, Hashable, Sendable, Codable {
    case blue, red, green, amber
}

/// What heart rate a phase aims for. Fractions resolve against HRmax at run
/// time; absolute targets work without any HRmax estimate.
public enum HeartRateTarget: Equatable, Hashable, Sendable, Codable {
    case fractionOfMax(lower: Double, upper: Double)
    case beatsPerMinute(lower: Double, upper: Double)

    public var requiresMaxHeartRate: Bool {
        if case .fractionOfMax = self { return true }
        return false
    }

    /// The absolute band in bpm, or `nil` when it needs an unknown HRmax.
    public func resolved(hrMax: Double?) -> ClosedRange<Double>? {
        switch self {
        case let .fractionOfMax(lower, upper):
            guard let hrMax else { return nil }
            return (lower * hrMax)...(upper * hrMax)
        case let .beatsPerMinute(lower, upper):
            return lower...upper
        }
    }
}

/// The guided routines the engine can run.
public enum WorkoutMode: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case n4x4
    case steadyHeartRate
    case heartCheck

    public var title: String {
        switch self {
        case .n4x4:            return "Norwegian 4×4"
        case .steadyHeartRate: return "Hold heart rate"
        case .heartCheck:      return "Heart check"
        }
    }
}

/// One ordered block in the session, with its duration and cumulative start
/// offset from the session origin (before any pauses/skips are applied).
public struct Phase: Equatable, Sendable, Codable {
    public let kind: PhaseKind
    public let duration: TimeInterval
    public let startOffset: TimeInterval
    public let target: HeartRateTarget?
    public let label: String

    public var endOffset: TimeInterval { startOffset + duration }
}

/// The session structure the engine runs. It travels inside every checkpoint,
/// so a mirror or failover device always continues the exact same routine.
public struct ProtocolConfig: Equatable, Sendable, Codable {
    public struct Block: Equatable, Sendable {
        public let kind: PhaseKind
        public let duration: TimeInterval
        public let target: HeartRateTarget?
        public let label: String

        public init(kind: PhaseKind, duration: TimeInterval, target: HeartRateTarget?, label: String) {
            self.kind = kind
            self.duration = duration
            self.target = target
            self.label = label
        }
    }

    public let mode: WorkoutMode
    public let phases: [Phase]
    /// Seconds over which the target line ramps from the phase-start HR to the
    /// band before holding flat (spec §3).
    public let rampDuration: TimeInterval
    /// Tolerance either side of the target band before guidance fires.
    public let deadBand: Double
    /// Protocol-elapsed time from which an explicit End completes and saves
    /// the session instead of discarding it. `nil` means End always discards.
    public let finishesEarlyAfter: TimeInterval?

    public var totalDuration: TimeInterval { phases.last?.endOffset ?? 0 }

    /// Whether any phase needs an HRmax estimate to produce a target.
    public var requiresMaxHeartRate: Bool {
        phases.contains { $0.target?.requiresMaxHeartRate == true }
    }

    public init(
        mode: WorkoutMode,
        blocks: [Block],
        rampDuration: TimeInterval,
        deadBand: Double,
        finishesEarlyAfter: TimeInterval? = nil
    ) {
        var offset: TimeInterval = 0
        var built: [Phase] = []
        built.reserveCapacity(blocks.count)
        for block in blocks {
            built.append(Phase(
                kind: block.kind,
                duration: block.duration,
                startOffset: offset,
                target: block.target,
                label: block.label
            ))
            offset += block.duration
        }
        self.mode = mode
        self.phases = built
        self.rampDuration = rampDuration
        self.deadBand = deadBand
        self.finishesEarlyAfter = finishesEarlyAfter
    }

    /// Builds a 4×4-style protocol from bare blocks, applying the standard
    /// targets and labels for each phase kind.
    public init(blocks: [(kind: PhaseKind, duration: TimeInterval)], rampDuration: TimeInterval) {
        let rounds = blocks.filter {
            if case .highIntensity = $0.kind { return true }
            return false
        }.count
        let standard = N4x4Settings.standard
        self.init(
            mode: .n4x4,
            blocks: blocks.map { block in
                Block(
                    kind: block.kind,
                    duration: block.duration,
                    target: standard.target(for: block.kind),
                    label: N4x4Settings.label(for: block.kind, rounds: rounds)
                )
            },
            rampDuration: rampDuration,
            deadBand: IntervalEngine.deadBandBPM
        )
    }

    /// Canonical Norwegian 4x4 (spec §2). Total runtime = 31 min (warm-up 3 +
    /// 4×4 high + 3×3 recovery + cooldown 3). Note: the spec's prose says
    /// "≈ 34 minutes", but the enumerated block structure sums to 31; the block
    /// structure is authoritative, so total is derived, never hardcoded.
    public static let norwegian4x4 = ProtocolConfig.n4x4(.standard)

    /// Index of the phase active at `elapsed` seconds, or `nil` once the session
    /// has run past its total duration.
    public func phaseIndex(atElapsed elapsed: TimeInterval) -> Int? {
        guard elapsed >= 0, elapsed < totalDuration else { return nil }
        // Phases are contiguous and ordered; linear scan is fine for a few blocks.
        for (index, phase) in phases.enumerated() where elapsed < phase.endOffset {
            return index
        }
        return nil
    }

    /// Colour of the phase after `index`, for the anticipatory fill in the
    /// phase-flow indicator (spec §6). `nil` after the last phase.
    public func nextRingColor(after index: Int) -> RingColor? {
        let next = index + 1
        guard phases.indices.contains(next) else { return nil }
        return phases[next].kind.ringColor
    }
}
