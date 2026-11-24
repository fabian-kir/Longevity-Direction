//
//  Longevity_WatchApp.swift
//  Longevity Watch Watch App
//
//  Created by Kirschenmann Fabian on 20.07.26.
//

import HealthKit
import IntervalEngine
import SwiftUI
import WatchKit

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    /// HealthKit invokes this when the iPhone starts a workout on the paired
    /// Watch. The app-lifetime model either adopts the phone's pending checkpoint
    /// or starts immediately and reconciles as soon as that checkpoint arrives.
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        let equipment = WorkoutEquipment(configuration: workoutConfiguration)
        Task { @MainActor in
            await WatchN4x4SessionModel.shared.handleSystemWorkoutStart(equipment: equipment)
        }
    }
}

@main
struct Longevity_Watch_Watch_AppApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(model: WatchN4x4SessionModel.shared)
        }
    }
}
