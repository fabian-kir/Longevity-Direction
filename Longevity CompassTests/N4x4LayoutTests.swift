import IntervalEngine
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import Longevity_Compass

/// Guards against pages that drag sideways: renders the workout screens in
/// narrow and wide windows at large text sizes and fails if any vertical
/// scroll view is wider than the screen or has wider content. The mode pager
/// is the only thing allowed to move horizontally.
@MainActor
final class N4x4LayoutTests: XCTestCase {
    func testWorkoutScreensNeverScrollSideways() throws {
        let schema = Schema([
            ManualEntry.self, HealthMetricSnapshot.self, PriorityHistoryEntry.self, NutritionEntry.self,
            ExerciseDef.self, ExerciseEntry.self, N4x4WorkoutLog.self, BloodworkPanel.self,
            BloodworkMarker.self, SymptomEntry.self, DigestionTrackingPeriod.self, DigestionAnalysisRun.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let services = AppServices(context: container.mainContext)
        services.n4x4.settings.customMaxHeartRate = 186
        let workload = HeartCheckWorkload(equipment: .treadmillWalk, speedKilometersPerHour: 5.5, inclinePercent: 8)
        services.n4x4.settings.heartCheckWorkload = workload

        let log = N4x4WorkoutLog(sessionID: UUID(), startedAt: .now, estimatedHRMax: 186, equipment: .treadmill)
        log.duration = 1860
        log.averageHeartRate = 151
        log.isCompleted = true
        log.appleDistanceKilometers = 4.62
        log.correctedDistanceKilometers = 5.1
        log.inclinePercent = 6
        log.appleActiveCalories = 412
        log.effortScore = 8
        container.mainContext.insert(log)
        let check = N4x4WorkoutLog(sessionID: UUID(), startedAt: .now, estimatedHRMax: 186, equipment: .treadmillWalk, mode: .heartCheck)
        check.isCompleted = true
        check.workloadHeartRate = 128
        check.stopHeartRate = 131
        check.recoveryDropAfter60 = 24
        check.workloadSummary = workload.summary
        container.mainContext.insert(check)
        try container.mainContext.save()

        var details = N4x4WorkoutDetails(equipment: .treadmill)
        var settings = services.n4x4.settings
        let detailsBinding = Binding(get: { details }, set: { details = $0 })
        let settingsBinding = Binding(get: { settings }, set: { settings = $0 })
        let screens: [(String, AnyView)] = [
            ("start", AnyView(NavigationStack { N4x4View() })),
            ("detail", AnyView(NavigationStack { N4x4WorkoutDetailView(log: log) })),
            ("heart check detail", AnyView(NavigationStack { N4x4WorkoutDetailView(log: check) })),
            ("history", AnyView(NavigationStack { N4x4WorkoutHistoryView() })),
            ("trend", AnyView(NavigationStack { HeartCheckTrendView() })),
            ("settings", AnyView(WorkoutSettingsView())),
            ("heart check sheet", AnyView(HeartCheckStartSheet(settings: settingsBinding, details: detailsBinding) {})),
            ("hold setup", AnyView(N4x4SetupSheet(mode: .steadyHeartRate, details: detailsBinding, settings: settingsBinding, hrMax: 186) {})),
            ("details sheet", AnyView(N4x4WorkoutDetailsSheet(log: log))),
        ]

        for (name, screen) in screens {
            for width in [375.0, 440.0] {
                for size in [DynamicTypeSize.large, .xxxLarge, .accessibility2] {
                    let host = UIHostingController(
                        rootView: screen.environment(services).modelContainer(container).dynamicTypeSize(size)
                    )
                    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 852))
                    window.rootViewController = host
                    window.makeKeyAndVisible()
                    for _ in 0..<3 {
                        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                        host.view.layoutIfNeeded()
                    }
                    let scrollViews = Self.scrollViews(in: window)
                    XCTAssertFalse(scrollViews.isEmpty, "\(name): nothing rendered")
                    for scrollView in scrollViews where !scrollView.isPagingEnabled {
                        XCTAssertLessThanOrEqual(
                            scrollView.bounds.width, width + 0.5,
                            "\(name) at \(Int(width)) pt, \(size): scroll view wider than the screen"
                        )
                        XCTAssertLessThanOrEqual(
                            scrollView.contentSize.width, scrollView.bounds.width + 0.5,
                            "\(name) at \(Int(width)) pt, \(size): content wider than its scroll view"
                        )
                    }
                    window.isHidden = true
                }
            }
        }
    }

    private static func scrollViews(in view: UIView) -> [UIScrollView] {
        let own: [UIScrollView] = (view as? UIScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap(scrollViews(in:))
    }
}
