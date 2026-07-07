import XCTest
@testable import MoshPit

final class ReversePlaybackTests: XCTestCase {

    /// At time zero (or never played forward), reverse needs a seek to the
    /// end before rate = -1 is honored.
    func testSeekToEndRequiredAtTimeZero() {
        let target = PlayerSource.reverseSeekTarget(currentSeconds: 0,
                                                    durationSeconds: 10)
        XCTAssertEqual(target ?? -1, 9.95, accuracy: 1e-6,
                       "should land one frame shy of the end")
    }

    func testNoSeekNeededMidClip() {
        // Played forward already: reverse can start from the current position.
        XCTAssertNil(PlayerSource.reverseSeekTarget(currentSeconds: 4.2,
                                                    durationSeconds: 10))
    }

    func testSeekNearZeroThresholdCatchesReverseLoopWrap() {
        // Reverse playback stalls just above zero — the loop wrap must fire.
        XCTAssertNotNil(PlayerSource.reverseSeekTarget(currentSeconds: 0.05,
                                                       durationSeconds: 10))
        // ...but not while there's still clip left to play backwards.
        XCTAssertNil(PlayerSource.reverseSeekTarget(currentSeconds: 0.5,
                                                    durationSeconds: 10))
    }

    func testInvalidDurationNeverSeeks() {
        // Indefinite/unloaded duration (e.g. HLS before metadata): no seek.
        XCTAssertNil(PlayerSource.reverseSeekTarget(currentSeconds: 0,
                                                    durationSeconds: .nan))
        XCTAssertNil(PlayerSource.reverseSeekTarget(currentSeconds: 0,
                                                    durationSeconds: .infinity))
        XCTAssertNil(PlayerSource.reverseSeekTarget(currentSeconds: 0,
                                                    durationSeconds: 0))
    }

    func testShortClipTargetClampsToZero() {
        // Clips shorter than the end inset still get a valid (0) target.
        let target = PlayerSource.reverseSeekTarget(currentSeconds: 0,
                                                    durationSeconds: 0.03)
        XCTAssertEqual(target ?? -1, 0, accuracy: 1e-6)
    }
}
