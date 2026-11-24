import Foundation
import IntervalEngine

/// Keeps the last workout settings received from iPhone, so a Watch-only
/// start uses the same max HR, 4×4 structure and Hold-HR target.
enum WatchSettingsStore {
    private static let key = "workout.settings"

    static func load() -> WorkoutSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(WorkoutSettings.self, from: data) else {
            return WorkoutSettings()
        }
        return settings
    }

    static func save(_ settings: WorkoutSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
