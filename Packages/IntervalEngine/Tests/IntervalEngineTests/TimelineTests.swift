import XCTest
@testable import IntervalEngine

final class TimelineTests: XCTestCase {

    private let config = ProtocolConfig.norwegian4x4

    func testBlockOrderAndCount() {
        let kinds = config.phases.map(\.kind)
        XCTAssertEqual(kinds, [
            .warmUp,
            .highIntensity(round: 1), .activeRecovery(round: 1),
            .highIntensity(round: 2), .activeRecovery(round: 2),
            .highIntensity(round: 3), .activeRecovery(round: 3),
            .highIntensity(round: 4),
            .cooldown,
        ])
    }

    func testNoTrailingRecoveryAfterRound4() {
        // The block after the 4th high-intensity is cooldown, not recovery (spec §2).
        let idx = config.phases.firstIndex { $0.kind == .highIntensity(round: 4) }!
        XCTAssertEqual(config.phases[idx + 1].kind, .cooldown)
    }

    func testCumulativeOffsetsAndTotal() {
        XCTAssertEqual(config.phases.map(\.startOffset),
                       [0, 180, 420, 600, 840, 1020, 1260, 1440, 1680])
        // Derived from the block structure: 31 minutes, not the prose's "≈34".
        XCTAssertEqual(config.totalDuration, 1860)
    }

    func testPhaseIndexAtBoundaries() {
        XCTAssertEqual(config.phaseIndex(atElapsed: 0), 0)      // warm-up start
        XCTAssertEqual(config.phaseIndex(atElapsed: 179.9), 0)  // still warm-up
        XCTAssertEqual(config.phaseIndex(atElapsed: 180), 1)    // high 1 start
        XCTAssertEqual(config.phaseIndex(atElapsed: 419.9), 1)  // still high 1 (ends at 420)
        XCTAssertEqual(config.phaseIndex(atElapsed: 420), 2)    // recovery 1 start
        XCTAssertEqual(config.phaseIndex(atElapsed: 1680), 8)   // cooldown start
        XCTAssertEqual(config.phaseIndex(atElapsed: 1859.9), 8) // still cooldown
        XCTAssertNil(config.phaseIndex(atElapsed: 1860))        // finished
        XCTAssertNil(config.phaseIndex(atElapsed: -1))          // before start
    }

    func testSkippableOnlyWarmupAndCooldown() {
        XCTAssertTrue(PhaseKind.warmUp.isSkippable)
        XCTAssertTrue(PhaseKind.cooldown.isSkippable)
        XCTAssertFalse(PhaseKind.highIntensity(round: 2).isSkippable)
        XCTAssertFalse(PhaseKind.activeRecovery(round: 1).isSkippable)
    }

    func testRingColors() {
        XCTAssertEqual(PhaseKind.warmUp.ringColor, .blue)
        XCTAssertEqual(PhaseKind.cooldown.ringColor, .blue)
        XCTAssertEqual(PhaseKind.highIntensity(round: 3).ringColor, .red)
        XCTAssertEqual(PhaseKind.activeRecovery(round: 2).ringColor, .green)
    }

    func testLabels() {
        let labels = ProtocolConfig.norwegian4x4.phases.map(\.label)
        XCTAssertEqual(labels.first, "Warm-up")
        XCTAssertTrue(labels.contains("3/4 (high intensity)"))
        XCTAssertTrue(labels.contains("2/4 (recovery)"))
        XCTAssertEqual(labels.last, "Cool-down")
    }

    func testTargetFractions() {
        let phases = ProtocolConfig.norwegian4x4.phases
        XCTAssertEqual(phases[1].target, .fractionOfMax(lower: 0.85, upper: 0.95))
        XCTAssertEqual(phases[2].target, .fractionOfMax(lower: 0.65, upper: 0.70))
        XCTAssertNil(phases.first?.target)
        XCTAssertNil(phases.last?.target)
    }

    func testNextRingColorFollowsConfig() {
        let config = ProtocolConfig.norwegian4x4
        XCTAssertEqual(config.nextRingColor(after: 0), .red)
        XCTAssertEqual(config.nextRingColor(after: 1), .green)
        // Last round goes straight to the cooldown.
        XCTAssertEqual(config.nextRingColor(after: config.phases.count - 2), .blue)
        XCTAssertNil(config.nextRingColor(after: config.phases.count - 1))
    }
}
