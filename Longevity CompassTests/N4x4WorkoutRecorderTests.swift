import IntervalEngine
import SwiftData
import XCTest
@testable import Longevity_Compass

@MainActor
final class N4x4WorkoutRecorderTests: XCTestCase {
    func testRecorderPersistsFramesAndSummary() throws {
        let schema = Schema([N4x4WorkoutLog.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let recorder = N4x4WorkoutRecorder(context: container.mainContext)
        let sessionID = UUID()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let engine = IntervalEngine(hrMax: 190, startedAt: start)

        recorder.begin(
            sessionID: sessionID,
            startedAt: start,
            hrMax: 190,
            details: N4x4WorkoutDetails(equipment: .treadmill)
        )

        var finalOutput = engine.tick(at: start).output
        for second in stride(from: 0, through: 500, by: 5) {
            let date = start.addingTimeInterval(TimeInterval(second))
            let bpm: Double
            switch second {
            case 180...239: bpm = 120 + Double(second - 180) * (45.0 / 60.0)
            case 240...419: bpm = 165
            case 420...479: bpm = 165 - Double(second - 420) * (35.0 / 60.0)
            default: bpm = 120
            }
            engine.ingest(hrSample: bpm, at: date)
            finalOutput = engine.tick(at: date).output
            recorder.record(
                output: finalOutput,
                sessionID: sessionID,
                startedAt: start,
                hrMax: 190,
                details: N4x4WorkoutDetails(equipment: .treadmill),
                capturedAt: date
            )
        }
        recorder.finish(output: finalOutput, completed: true, healthKitRequested: true)

        let logs = try container.mainContext.fetch(FetchDescriptor<N4x4WorkoutLog>())
        let log = try XCTUnwrap(logs.first)
        XCTAssertEqual(log.sessionID, sessionID)
        XCTAssertEqual(log.equipment, .treadmill)
        XCTAssertTrue(log.isCompleted)
        XCTAssertEqual(log.healthKitSaveState, .requested)
        XCTAssertGreaterThan(log.frames.count, 90)
        XCTAssertNotNil(log.averageHeartRate)
        XCTAssertNotNil(log.peakHeartRate)
        XCTAssertNotNil(log.targetAdherence)
        XCTAssertNotNil(log.averageOneMinuteRise)
        XCTAssertNotNil(log.averageOneMinuteRecovery)
    }

    func testFramePayloadRoundTripsThroughSwiftDataModel() throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let engine = IntervalEngine(hrMax: 190, startedAt: start)
        engine.ingest(hrSample: 150, at: start.addingTimeInterval(200))
        let output = engine.tick(at: start.addingTimeInterval(200)).output
        let frame = N4x4WorkoutFrame(capturedAt: start, output: output)
        let log = N4x4WorkoutLog(
            sessionID: UUID(),
            startedAt: start,
            estimatedHRMax: 190,
            equipment: .stepper
        )

        log.frames = [frame]

        XCTAssertEqual(log.frames, [frame])
        XCTAssertEqual(log.equipment, .stepper)
    }

    /// Drives a full heart check: steady workload HR, then a linear fall while
    /// standing still. The results must read the workload's last minute and
    /// the drops at 60 s and 120 s.
    func testHeartCheckResultsAreRecorded() throws {
        let (container, recorder) = try makeRecorder()
        let sessionID = UUID()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let workload = HeartCheckWorkload(equipment: .treadmillWalk, speedKilometersPerHour: 5.5, inclinePercent: 8)
        let program = ProtocolConfig.heartCheck(workload)
        let engine = IntervalEngine(config: program, hrMax: 190, startedAt: start)

        var output = engine.tick(at: start).output
        for second in 0...Int(program.totalDuration) {
            let date = start.addingTimeInterval(TimeInterval(second))
            let bpm: Double
            switch second {
            case ..<180: bpm = 100
            case 180..<540: bpm = 130
            default: bpm = 130 - Double(second - 540) * 0.4 // 24 bpm/min
            }
            engine.ingest(hrSample: bpm, at: date)
            output = engine.tick(at: date).output
            recorder.record(
                output: output,
                sessionID: sessionID,
                startedAt: start,
                hrMax: 190,
                details: N4x4WorkoutDetails(equipment: .treadmillWalk),
                program: program,
                workloadSummary: workload.summary,
                capturedAt: date
            )
        }
        XCTAssertTrue(output.isFinished)
        recorder.finish(output: output, completed: true, healthKitRequested: true)

        let log = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<N4x4WorkoutLog>()).first)
        XCTAssertEqual(log.mode, .heartCheck)
        XCTAssertEqual(log.workloadSummary, workload.summary)
        XCTAssertEqual(try XCTUnwrap(log.workloadHeartRate), 130, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(log.recoveryDropAfter60), 24, accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(log.recoveryDropAfter120), 48, accuracy: 3)
    }

    func testSteadyHoldUsesItsOwnTolerance() throws {
        let (container, recorder) = try makeRecorder()
        let sessionID = UUID()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        var settings = SteadySettings()
        settings.targetBPM = 130
        settings.toleranceBPM = 3
        settings.warmUpMinutes = 0
        settings.durationMinutes = 10
        let program = ProtocolConfig.steadyHeartRate(settings, hrMax: nil)
        let engine = IntervalEngine(config: program, hrMax: nil, startedAt: start)

        var output = engine.tick(at: start).output
        for second in stride(from: 0, through: 600, by: 2) {
            let date = start.addingTimeInterval(TimeInterval(second))
            // 6 bpm above target after the ramp: outside a ±3 tolerance.
            engine.ingest(hrSample: second < 200 ? 130 : 136, at: date)
            output = engine.tick(at: date).output
            recorder.record(
                output: output,
                sessionID: sessionID,
                startedAt: start,
                hrMax: nil,
                details: N4x4WorkoutDetails(),
                program: program,
                capturedAt: date
            )
        }
        recorder.finish(output: output, completed: true, healthKitRequested: false)

        let log = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<N4x4WorkoutLog>()).first)
        XCTAssertEqual(log.mode, .steadyHeartRate)
        XCTAssertEqual(log.targetDeadBand, 3)
        let adherence = try XCTUnwrap(log.targetAdherence)
        XCTAssertLessThan(adherence, 0.5)
        XCTAssertNil(log.workloadHeartRate)
    }

    func testCorrectedDistanceWinsAndGivesElevation() {
        let log = N4x4WorkoutLog(sessionID: UUID(), startedAt: .now, estimatedHRMax: nil, equipment: .treadmill)
        log.appleDistanceKilometers = 4.6
        XCTAssertEqual(log.distanceKilometers, 4.6)
        log.correctedDistanceKilometers = 5.0
        log.inclinePercent = 6
        XCTAssertEqual(log.distanceKilometers, 5.0)
        XCTAssertEqual(try XCTUnwrap(log.elevationGainMeters), 300, accuracy: 0.001)
    }

    private func makeRecorder() throws -> (ModelContainer, N4x4WorkoutRecorder) {
        let schema = Schema([N4x4WorkoutLog.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        return (container, N4x4WorkoutRecorder(context: container.mainContext))
    }
}
