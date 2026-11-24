import Foundation
import IntervalEngine
import WatchConnectivity

/// Durable phone side of the N4x4 control/state link.
///
/// Immediate messages keep two visible apps responsive. The same latest
/// snapshot and command are also placed in application context, so reconnecting
/// peers receive a checkpoint or terminal stop instead of treating silence as a
/// new session. Duplicate delivery is expected and handled by session IDs,
/// sequence numbers, and command IDs in the model.
@MainActor
final class N4x4ConnectivityManager: NSObject {
    var onRemoteMessage: ((SessionMessage) -> Void)?
    var onReachabilityChanged: ((Bool) -> Void)?
    var onSendFailure: ((SessionMessage) -> Void)?

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
    private var settingsData: Data?

    var isReachable: Bool { session?.isReachable == true }
    var isWatchAvailable: Bool {
        guard let session else { return false }
        return session.isPaired && session.isWatchAppInstalled
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    private func pushPendingSettings() {
        updateApplicationContext()
    }

    /// Sends immediately when possible and always retains the newest state for
    /// background/reconnect delivery. Returns whether live delivery was started.
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

    /// Makes the workout settings available to the Watch, which uses them for
    /// Watch-only starts. Application context delivers them even while the
    /// Watch app isn't running.
    func pushSettings(_ settings: WorkoutSettings) {
        guard let data = try? JSONEncoder().encode(settings), data != settingsData else { return }
        settingsData = data
        updateApplicationContext()
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
        // Before activation the update would fail; activation re-sends it.
        guard let session, session.activationState == .activated else { return }
        var context: [String: Any] = [:]
        if let latestSnapshotData { context[ContextKey.snapshot] = latestSnapshotData }
        if let latestCommandData { context[ContextKey.command] = latestCommandData }
        if !commandLogData.isEmpty { context[ContextKey.commands] = commandLogData }
        if let settingsData { context[ContextKey.settings] = settingsData }
        guard !context.isEmpty else { return }
        try? session.updateApplicationContext(context)
    }

    private func deliver(_ data: Data) {
        guard let message = try? JSONDecoder().decode(SessionMessage.self, from: data) else { return }
        onRemoteMessage?(message)
    }

    private func deliver(_ context: [String: Any]) {
        let commandData: [Data]
        if let commands = context[ContextKey.commands] as? [Data] {
            commandData = commands
        } else if let command = context[ContextKey.command] as? Data {
            commandData = [command]
        } else {
            commandData = []
        }

        // Tombstone terminal sessions before considering their retained running
        // snapshot. Otherwise an old context could replace a newer local run and
        // only then stop the resurrected old one.
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

extension N4x4ConnectivityManager: WCSessionDelegate {
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
            // Settings pushed before activation completed were not delivered.
            self?.pushPendingSettings()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
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
