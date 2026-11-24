import Foundation
import Observation

/// The user's permission to send data to the AI provider (OpenRouter).
///
/// Stored in UserDefaults on this device only. Consent is tied to a version of
/// what the app sends: when that changes, bump `latestVersion` and everyone who
/// allowed an older version is asked again.
@Observable
final class AIDataConsent {
    /// v1: meal photos (nutrition estimate) and exercise names (icons and muscle groups).
    static let latestVersion = 1

    static let shared = AIDataConsent()

    private static let versionKey = "aiDataConsent.grantedVersion"
    private static let dateKey = "aiDataConsent.grantedAt"

    /// The version the user must have allowed for requests to run.
    let requiredVersion: Int
    private(set) var grantedVersion: Int?
    private(set) var grantedAt: Date?

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, requiredVersion: Int = AIDataConsent.latestVersion) {
        self.defaults = defaults
        self.requiredVersion = requiredVersion
        let stored = defaults.integer(forKey: Self.versionKey)
        self.grantedVersion = stored > 0 ? stored : nil
        self.grantedAt = defaults.object(forKey: Self.dateKey) as? Date
    }

    var isGranted: Bool {
        guard let grantedVersion else { return false }
        return grantedVersion >= requiredVersion
    }

    /// Allowed before, but what gets sent has changed since.
    var needsRenewal: Bool {
        guard let grantedVersion else { return false }
        return grantedVersion < requiredVersion
    }

    func grant(at date: Date = .now) {
        defaults.set(requiredVersion, forKey: Self.versionKey)
        defaults.set(date, forKey: Self.dateKey)
        grantedVersion = requiredVersion
        grantedAt = date
    }

    func withdraw() {
        defaults.removeObject(forKey: Self.versionKey)
        defaults.removeObject(forKey: Self.dateKey)
        grantedVersion = nil
        grantedAt = nil
    }
}
