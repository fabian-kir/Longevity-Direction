import XCTest
@testable import IntervalEngine

/// Configurable programs: the standard settings must reproduce the canonical
/// protocol exactly, and every program must travel inside its checkpoint.
final class ProgramTests: XCTestCase {

    func testStandardSettingsReproduceCanonicalProtocol() {
        let built = ProtocolConfig.n4x4(.standard)
        XCTAssertEqual(built.totalDuration, 31 * 60)
        XCTAssertEqual(built.phases.count, 9)
        XCTAssertEqual(built.deadBand, IntervalEngine.deadBandBPM)
        XCTAssertEqual(built, ProtocolConfig(blocks: built.phases.map { ($0.kind, $0.duration) }, rampDuration: 60))
    }

    func testCustomN4x4StructureAndZones() {
        var settings = N4x4Settings()
        settings.rounds = 5
        settings.intervalMinutes = 3
        settings.warmUpMinutes = 0
        settings.highLowerPercent = 88
        settings.toleranceBPM = 5
        let config = ProtocolConfig.n4x4(settings)

        XCTAssertEqual(config.phases.first?.kind, .highIntensity(round: 1))
        XCTAssertEqual(config.phases.first?.label, "1/5 (high intensity)")
        XCTAssertEqual(config.totalDuration, TimeInterval(settings.totalMinutes * 60))
        XCTAssertEqual(config.deadBand, 5)

        let engine = IntervalEngine(config: config, hrMax: 200, startedAt: t0)
        engine.feedConstantHR(180, from: 0, through: 90)
        let output = engine.tick(at: at(90)).output
        XCTAssertEqual(output.target, 176...190)
    }

    func testSteadyHoldUsesAbsoluteTargetWithoutHRMax() {
        var settings = SteadySettings()
        settings.targetBPM = 132
        settings.warmUpMinutes = 0
        settings.toleranceBPM = 4
        let config = ProtocolConfig.steadyHeartRate(settings, hrMax: nil)
        XCTAssertFalse(config.requiresMaxHeartRate)

        let engine = IntervalEngine(config: config, hrMax: nil, startedAt: t0)
        engine.feedConstantHR(150, from: 0, through: 400)
        let result = engine.tick(at: at(400))
        XCTAssertEqual(result.output.target, 132...132)
        XCTAssertEqual(result.output.deadBandState, .above)
        XCTAssertEqual(result.output.phaseLabel, "Hold 132 bpm")
    }

    func testSteadyTargetDerivesFromHRMax() {
        XCTAssertEqual(SteadySettings().resolvedTarget(hrMax: 190), 135)
        XCTAssertEqual(SteadySettings().resolvedTarget(hrMax: nil), 130)
    }

    func testFinishEarlyCompletesAtCurrentElapsed() {
        let config = ProtocolConfig.steadyHeartRate(.standard, hrMax: 190)
        let engine = IntervalEngine(config: config, hrMax: 190, startedAt: t0)
        XCTAssertFalse(engine.endCompletesSession(at: at(120)))
        XCTAssertTrue(engine.endCompletesSession(at: at(600)))

        engine.finish(at: at(600))
        let output = engine.tick(at: at(700)).output
        XCTAssertTrue(output.isFinished)
        XCTAssertEqual(output.elapsed, 600)

        let restored = IntervalEngine(checkpoint: engine.checkpoint())
        XCTAssertEqual(restored.tick(at: at(800)).output.elapsed, 600)
    }

    func testN4x4EndNeverCompletes() {
        let engine = IntervalEngine(hrMax: 190, startedAt: t0)
        XCTAssertFalse(engine.endCompletesSession(at: at(30 * 60)))
    }

    func testCheckpointCarriesConfig() throws {
        let config = ProtocolConfig.heartCheck(HeartCheckWorkload(
            equipment: .treadmillWalk,
            speedKilometersPerHour: 5.5,
            inclinePercent: 8
        ))
        let engine = IntervalEngine(config: config, hrMax: 190, startedAt: t0)
        let data = try JSONEncoder().encode(engine.checkpoint())
        let checkpoint = try JSONDecoder().decode(EngineCheckpoint.self, from: data)
        let restored = IntervalEngine(checkpoint: checkpoint)

        XCTAssertEqual(restored.config, config)
        let output = restored.tick(at: at(4 * 60)).output
        XCTAssertEqual(output.phase, .fixedWorkload)
        // Formatting follows the device locale (5.5 or 5,5).
        let speed = 5.5.formatted(.number.precision(.fractionLength(0...1)))
        XCTAssertEqual(output.phaseLabel, "Hold \(speed) km/h · 8%")
        XCTAssertEqual(output.nextRingColor, .blue)
        XCTAssertNil(output.target)
    }

    func testLegacyCheckpointFallsBackToStandardProtocol() throws {
        // A checkpoint encoded before `config` existed has no such key.
        let engine = IntervalEngine(hrMax: 190, startedAt: t0)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(engine.checkpoint())) as! [String: Any]
        json.removeValue(forKey: "config")
        let data = try JSONSerialization.data(withJSONObject: json)
        let checkpoint = try JSONDecoder().decode(EngineCheckpoint.self, from: data)
        XCTAssertEqual(IntervalEngine(checkpoint: checkpoint).config, .norwegian4x4)
    }

    func testSettingsDecodeWithMissingKeys() throws {
        let data = Data(#"{"customMaxHeartRate": 187, "n4x4": {"rounds": 6}}"#.utf8)
        let settings = try JSONDecoder().decode(WorkoutSettings.self, from: data)
        XCTAssertEqual(settings.customMaxHeartRate, 187)
        XCTAssertEqual(settings.n4x4.rounds, 6)
        XCTAssertEqual(settings.n4x4.intervalMinutes, 4)
        XCTAssertEqual(settings.steady, .standard)
        XCTAssertEqual(settings.resolvedMaxHeartRate(estimated: 180), 187)
    }

    func testUnknownEquipmentDecodesAsUnspecified() throws {
        let decoded = try JSONDecoder().decode([WorkoutEquipment].self, from: Data(#"["treadmill","hoverboard"]"#.utf8))
        XCTAssertEqual(decoded, [.treadmill, .unspecified])
    }
}
