import Foundation
import IntervalEngine
import WatchConnectivity

/// Durable Watch side of the N4x4 state/control link. Live delivery is paired
/// with application-context checkpoints so a background launch or reconnect can
/// deterministically adopt the running protocol and its last command.
@MainActor
final class WatchConnectivityManager: NSObject {
    var onRemoteMessage: ((SessionMessage) -> Void)?
    var onReachabilityChanged: ((Bool) -> Void)?
    var onSendFailure: ((SessionMessage) -> Void)?
    /// Workout settings pushed by iPhone (max HR, 4×4 structure, Hold HR,
    /// heart-check workload).
    var onSettings: ((WorkoutSettings) -> Void)?

    private enum ContextKey {
        static let snapshot = "n4x4.snapshot"
        static let command = "n4x4.command"
        static let commands = "n4x4.commands"
        static let settings = "workout.settings"
    }

    private let session: WCSession? = WCSession.isSupported() ? .default : nil
    private var latestSnapshotData: Data?
    private var latestCommandData: Data?
    private var commandLogData: [Data] = []

    var isReachable: Bool { session?.isReachable == true }
    var isCompanionAvailable: Bool { session?.isCompanionAppInstalled == true }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    @discardableResult
    func send(_ message: SessionMessage) -> Bool {
        guard let data = try? JSONEncoder().encode(message) else { return false }
        persist(data, for: message)

        guard let session, session.isReachable else { return false }
        session.sendMessageData(data, replyHandler: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onSendFailure?(message) }
        }
        return true
    }

    private func persist(_ data: Data, for message: SessionMessage) {
        switch message {
        case .snapshot:
            latestSnapshotData = data
        case .command:
            latestCommandData = data
            commandLogData.append(data)
            if commandLogData.count > 32 {
                commandLogData.removeFirst(commandLogData.count - 32)
            }
        }
        updateApplicationContext()
    }

    private func updateApplicationContext() {
        guard let session else { return }
        var context: [String: Any] = [:]
        if let latestSnapshotData { context[ContextKey.snapshot] = latestSnapshotData }
        if let latestCommandData { context[ContextKey.command] = latestCommandData }
        if !commandLogData.isEmpty { context[ContextKey.commands] = commandLogData }
        guard !context.isEmpty else { return }
        try? session.updateApplicationContext(context)
    }

    private func deliver(_ data: Data) {
        guard let message = try? JSONDecoder().decode(SessionMessage.self, from: data) else { return }
        onRemoteMessage?(message)
    }

    private func deliver(_ context: [String: Any]) {
        if let data = context[ContextKey.settings] as? Data,
           let settings = try? JSONDecoder().decode(WorkoutSettings.self, from: data) {
            onSettings?(settings)
        }

        let commandData: [Data]
        if let commands = context[ContextKey.commands] as? [Data] {
            commandData = commands
        } else if let command = context[ContextKey.command] as? Data {
            commandData = [command]
        } else {
            commandData = []
        }

        for data in commandData where isStopCommand(data) { deliver(data) }
        if let data = context[ContextKey.snapshot] as? Data { deliver(data) }
        for data in commandData where !isStopCommand(data) { deliver(data) }
    }

    private func isStopCommand(_ data: Data) -> Bool {
        guard case .command(let command) = try? JSONDecoder().decode(SessionMessage.self, from: data),
              case .stop = command.action else { return false }
        return true
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        var context = session.receivedApplicationContext
        #if DEBUG
        // WatchConnectivity keeps the last context across launches. A mock run
        // starts from fresh synthetic data, so it must not resume a session
        // left over from an earlier run; live messages still arrive normally.
        if MockMode.isActive { context = [:] }
        #endif
        Task { @MainActor [weak self] in
            self?.deliver(context)
            self?.onReachabilityChanged?(session.isReachable)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.onReachabilityChanged?(session.isReachable)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        Task { @MainActor [weak self] in self?.deliver(messageData) }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor [weak self] in self?.deliver(applicationContext) }
    }
}
