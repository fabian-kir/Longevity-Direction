import XCTest
@testable import Longevity_Compass

final class LiveBarcodeStabilizerTests: XCTestCase {
    func testRequiresSeveralMatchingFramesBeforeDelivery() {
        var stabilizer = LiveBarcodeStabilizer(matchesRequired: 3)

        XCTAssertNil(stabilizer.observe("4006381333931"))
        XCTAssertNil(stabilizer.observe("4006381333931"))
        XCTAssertEqual(stabilizer.observe("4006381333931"), "4006381333931")
    }

    func testDoesNotRepeatUntilBarcodeLeavesFrame() {
        var stabilizer = LiveBarcodeStabilizer(
            matchesRequired: 2,
            missesRequiredToReset: 3
        )

        XCTAssertNil(stabilizer.observe("4006381333931"))
        XCTAssertEqual(stabilizer.observe("4006381333931"), "4006381333931")
        XCTAssertNil(stabilizer.observe("4006381333931"))
        XCTAssertNil(stabilizer.observe("4006381333931"))

        XCTAssertNil(stabilizer.observe(nil))
        XCTAssertNil(stabilizer.observe(nil))
        XCTAssertNil(stabilizer.observe(nil))

        XCTAssertNil(stabilizer.observe("4006381333931"))
        XCTAssertEqual(stabilizer.observe("4006381333931"), "4006381333931")
    }

    func testRepeatsAfterBarcodeIsOutOfViewForAWhile() {
        var stabilizer = LiveBarcodeStabilizer(matchesRequired: 2, absenceToReset: 1)
        let start = Date(timeIntervalSinceReferenceDate: 0)

        XCTAssertNil(stabilizer.observe("4006381333931", at: start))
        XCTAssertEqual(stabilizer.observe("4006381333931", at: start), "4006381333931")
        // Still in view: held back however long it stays.
        XCTAssertNil(stabilizer.observe("4006381333931", at: start.addingTimeInterval(0.5)))
        XCTAssertNil(stabilizer.observe("4006381333931", at: start.addingTimeInterval(1.2)))

        // Unseen for over a second, with no empty frames reported in between.
        XCTAssertNil(stabilizer.observe("4006381333931", at: start.addingTimeInterval(2.5)))
        XCTAssertEqual(stabilizer.observe("4006381333931", at: start.addingTimeInterval(2.6)), "4006381333931")
    }

    func testRestartedAbsenceClockKeepsCodeInViewHeldBack() {
        var stabilizer = LiveBarcodeStabilizer(matchesRequired: 2, absenceToReset: 1)
        let start = Date(timeIntervalSinceReferenceDate: 0)

        XCTAssertNil(stabilizer.observe("4006381333931", at: start))
        XCTAssertEqual(stabilizer.observe("4006381333931", at: start), "4006381333931")

        // Scanning pauses for ten seconds, then resumes with the code still in view.
        stabilizer.restartAbsenceClock(at: start.addingTimeInterval(10))
        XCTAssertNil(stabilizer.observe("4006381333931", at: start.addingTimeInterval(10.1)))
        XCTAssertNil(stabilizer.observe("4006381333931", at: start.addingTimeInterval(10.2)))
    }

    func testAlternatingCodesNeverBecomeStable() {
        var stabilizer = LiveBarcodeStabilizer(matchesRequired: 3)

        XCTAssertNil(stabilizer.observe("111"))
        XCTAssertNil(stabilizer.observe("222"))
        XCTAssertNil(stabilizer.observe("111"))
        XCTAssertNil(stabilizer.observe("222"))
    }
}
