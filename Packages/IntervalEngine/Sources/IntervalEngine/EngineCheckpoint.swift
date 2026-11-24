import Foundation

/// Transport-safe continuation state for ``IntervalEngine``.
///
/// Carries the protocol configuration alongside everything mutable at runtime,
/// so the receiving device continues the same routine. `config` is optional
/// only so checkpoints from before configurable protocols still decode.
public struct EngineCheckpoint: Equatable, Sendable, Codable {
    public struct HeartRateSample: Equatable, Sendable, Codable {
        public let timestamp: Date
        public let bpm: Double

        public init(timestamp: Date, bpm: Double) {
            self.timestamp = timestamp
            self.bpm = bpm
        }
    }

    public struct Guidance: Equatable, Sendable, Codable {
        public let state: DeadBandState
        public let timestamp: Date

        public init(state: DeadBandState, timestamp: Date) {
            self.state = state
            self.timestamp = timestamp
        }
    }

    public let hrMax: Double?
    public let startedAt: Date
    public let pausedAt: Date?
    public let accumulatedPause: TimeInterval
    public let skipOffset: TimeInterval
    public let heartRateSamples: [HeartRateSample]
    public let lastPhaseKind: PhaseKind?
    public let phaseStartHR: Double?
    public let lastGuidance: Guidance?
    public let isFinished: Bool
    public let config: ProtocolConfig?
    public let finishedElapsed: TimeInterval?

    public init(
        hrMax: Double?,
        startedAt: Date,
        pausedAt: Date?,
        accumulatedPause: TimeInterval,
        skipOffset: TimeInterval,
        heartRateSamples: [HeartRateSample],
        lastPhaseKind: PhaseKind?,
        phaseStartHR: Double?,
        lastGuidance: Guidance?,
        isFinished: Bool,
        config: ProtocolConfig? = nil,
        finishedElapsed: TimeInterval? = nil
    ) {
        self.hrMax = hrMax
        self.startedAt = startedAt
        self.pausedAt = pausedAt
        self.accumulatedPause = accumulatedPause
        self.skipOffset = skipOffset
        self.heartRateSamples = heartRateSamples
        self.lastPhaseKind = lastPhaseKind
        self.phaseStartHR = phaseStartHR
        self.lastGuidance = lastGuidance
        self.isFinished = isFinished
        self.config = config
        self.finishedElapsed = finishedElapsed
    }
}
