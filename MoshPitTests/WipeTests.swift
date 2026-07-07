import XCTest
@testable import MoshPit

final class WipeTests: XCTestCase {
    func testCrossfadeEndpoints() {
        // Fully A at crossfade 0, fully B at 1 — for any luma.
        for luma: Float in [0, 0.3, 0.7, 1] {
            XCTAssertEqual(lumaWipeBlend(luma: luma, crossfade: 0, softness: 0.15), 0,
                           accuracy: 1e-4)
            XCTAssertEqual(lumaWipeBlend(luma: luma, crossfade: 1, softness: 0.15), 1,
                           accuracy: 1e-4)
        }
    }

    func testBrightAreasTransitionFirst() {
        let mid: Float = 0.5
        let bright = lumaWipeBlend(luma: 0.9, crossfade: mid, softness: 0.15)
        let dark = lumaWipeBlend(luma: 0.1, crossfade: mid, softness: 0.15)
        XCTAssertGreaterThan(bright, dark)
        XCTAssertGreaterThan(bright, 0.9)
        XCTAssertLessThan(dark, 0.1)
    }

    func testMonotonicInCrossfade() {
        var prev: Float = -1
        for step in 0...20 {
            let t = lumaWipeBlend(luma: 0.5, crossfade: Float(step) / 20,
                                  softness: 0.2)
            XCTAssertGreaterThanOrEqual(t, prev - 1e-5)
            prev = t
        }
    }

    func testSoftnessFeathersTheEdge() {
        // With a hard edge, mid-luma pixels snap; softer widens the ramp.
        let cross: Float = 0.5
        let hardBand = (0...20).map {
            lumaWipeBlend(luma: Float($0) / 20, crossfade: cross, softness: 0.01)
        }.filter { $0 > 0.05 && $0 < 0.95 }.count
        let softBand = (0...20).map {
            lumaWipeBlend(luma: Float($0) / 20, crossfade: cross, softness: 0.4)
        }.filter { $0 > 0.05 && $0 < 0.95 }.count
        XCTAssertGreaterThan(softBand, hardBand)
    }
}

final class PreviewScaleTests: XCTestCase {
    /// Fill must center-crop (both uv components <= 1, at least one == 1);
    /// Fit must letterbox (both >= 1). Same math runs on device and sim.
    func testFillCoversFitLetterboxes() {
        // iPhone portrait drawable vs 16:9 canvas.
        let fill = MoshRenderer.previewUVScale(drawableW: 1206, drawableH: 2622,
                                               texW: 960, texH: 540, fill: true)
        XCTAssertLessThanOrEqual(fill.x, 1.0001)
        XCTAssertLessThanOrEqual(fill.y, 1.0001)
        XCTAssertEqual(max(fill.x, fill.y), 1, accuracy: 1e-4)

        let fit = MoshRenderer.previewUVScale(drawableW: 1206, drawableH: 2622,
                                              texW: 960, texH: 540, fill: false)
        XCTAssertGreaterThanOrEqual(fit.x, 0.9999)
        XCTAssertGreaterThanOrEqual(fit.y, 0.9999)
        XCTAssertEqual(min(fit.x, fit.y), 1, accuracy: 1e-4)

        // Matching aspect: fill == fit == identity.
        let same = MoshRenderer.previewUVScale(drawableW: 1920, drawableH: 1080,
                                               texW: 960, texH: 540, fill: true)
        XCTAssertEqual(same.x, 1, accuracy: 1e-4)
        XCTAssertEqual(same.y, 1, accuracy: 1e-4)
    }
}
