import Foundation

/// The device currently responsible for advancing a shared session.
public enum SessionDevice: Equatable, Hashable, Sendable, Codable {
    case phone
    case watch
}

/// The sensor feeding heart-rate samples into the authoritative engine.
public enum HeartRateSource: Equatable, Hashable, Sendable, Codable {
    case watch
    case phoneExternal
    case none
}

/// A complete, ordered rendering and continuation snapshot.
///
/// `sessionID` is stable for the lifetime of one protocol. Receivers use
/// `sequence` to reject stale or duplicated snapshots, while `createdAt` is
/// useful for transport diagnostics and countdown projection.
public struct SessionSnapshot: Equatable, Sendable, Codable {
    public let sessionID: UUID
    public let createdAt: Date
    public let sequence: UInt64
    public let authority: SessionDevice
    public let heartRateSource: HeartRateSource
    /// True once the authority has successfully opened its live HealthKit
    /// workout/sensor session. This is distinct from receiving the first sample.
    public let heartRateSessionActive: Bool
    /// Recently applied control IDs. Mirrors use these acknowledgements to keep
    /// retrying outage-time controls until the authoritative device incorporated
    /// them, without ever applying a skip twice.
    public let acknowledgedCommandIDs: [UUID]
    public let output: EngineOutput
    public let checkpoint: EngineCheckpoint
    /// What the session is performed on, so the receiving device records the
    /// matching Apple workout type. Optional for older peers.
    public let equipment: WorkoutEquipment?

    public init(
        sessionID: UUID,
        createdAt: Date,
        sequence: UInt64,
        authority: SessionDevice,
        heartRateSource: HeartRateSource,
        heartRateSessionActive: Bool = false,
        acknowledgedCommandIDs: [UUID] = [],
        output: EngineOutput,
        checkpoint: EngineCheckpoint,
        equipment: WorkoutEquipment? = nil
    ) {
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.sequence = sequence
        self.authority = authority
        self.heartRateSource = heartRateSource
        self.heartRateSessionActive = heartRateSessionActive
        self.acknowledgedCommandIDs = acknowledgedCommandIDs
        self.output = output
        self.checkpoint = checkpoint
        self.equipment = equipment
    }
}

/// A retry-safe user intent sent to the current session authority.
public struct SessionCommand: Equatable, Sendable, Codable {
    public enum Action: Equatable, Sendable, Codable {
        /// Desired pause state, not a toggle, so duplicate delivery is safe.
        case setPaused(Bool)
        case skip
        case stop
        /// Complete and save an open-ended session now (Hold HR's End).
        case finish
        case requestSync
    }

    /// Stable identifier used by receivers to deduplicate command delivery.
    public let id: UUID
    public let sessionID: UUID
    /// The original control-event time. Replaying an offline pause/resume or skip
    /// at this timestamp preserves the shared protocol clock after reconnecting.
    public let issuedAt: Date
    public let action: Action

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        issuedAt: Date = .now,
        action: Action
    ) {
        self.id = id
        self.sessionID = sessionID
        self.issuedAt = issuedAt
        self.action = action
    }
}

/// Shared phone/watch wire contract. Every message either publishes the latest
/// complete state or requests one idempotent session action.
public enum SessionMessage: Equatable, Sendable, Codable {
    case snapshot(SessionSnapshot)
    case command(SessionCommand)
}
