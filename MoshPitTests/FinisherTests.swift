import XCTest
@testable import MoshPit

final class FinisherTests: XCTestCase {

    // MARK: Mirror UV math

    func testHorizontalMirrorFoldsRightHalfOntoLeft() {
        // Left half: identity — those pixels ARE the kept half.
        let left = FinisherMath.mirroredUV(SIMD2(0.25, 0.4), mode: .horizontal)
        XCTAssertEqual(left, SIMD2(0.25, 0.4))
        // Right half samples the mirrored left-half coordinate.
        let right = FinisherMath.mirroredUV(SIMD2(0.75, 0.4), mode: .horizontal)
        XCTAssertEqual(right.x, 0.25, accuracy: 1e-6)
        XCTAssertEqual(right.y, 0.4)
        // Symmetry: a pixel and its reflection sample the SAME source texel.
        XCTAssertEqual(
            FinisherMath.mirroredUV(SIMD2(0.1, 0.5), mode: .horizontal).x,
            FinisherMath.mirroredUV(SIMD2(0.9, 0.5), mode: .horizontal).x,
            accuracy: 1e-6)
    }

    func testHorizontalMirrorRightToLeftKeepsRightHalf() {
        let right = FinisherMath.mirroredUV(SIMD2(0.75, 0.4), mode: .horizontal,
                                            rightToLeft: true)
        XCTAssertEqual(right, SIMD2(0.75, 0.4))          // right half: identity
        let left = FinisherMath.mirroredUV(SIMD2(0.25, 0.4), mode: .horizontal,
                                           rightToLeft: true)
        XCTAssertEqual(left.x, 0.75, accuracy: 1e-6)     // left reflects right
    }

    func testVerticalMirrorFoldsBottomOntoTop() {
        let top = FinisherMath.mirroredUV(SIMD2(0.3, 0.2), mode: .vertical)
        XCTAssertEqual(top, SIMD2(0.3, 0.2))
        let bottom = FinisherMath.mirroredUV(SIMD2(0.3, 0.8), mode: .vertical)
        XCTAssertEqual(bottom.y, 0.2, accuracy: 1e-6)
        XCTAssertEqual(bottom.x, 0.3)
    }

    func testQuadMirrorSamplesTopLeftQuadrantOnly() {
        // All four quadrants must fold into uv <= 0.5 (the top-left quadrant).
        for uv in [SIMD2<Float>(0.2, 0.3), SIMD2(0.8, 0.3),
                   SIMD2(0.2, 0.7), SIMD2(0.8, 0.7)] {
            let m = FinisherMath.mirroredUV(uv, mode: .quad)
            XCTAssertLessThanOrEqual(m.x, 0.5)
            XCTAssertLessThanOrEqual(m.y, 0.5)
            XCTAssertEqual(m.x, 0.2, accuracy: 1e-6)
            XCTAssertEqual(m.y, 0.3, accuracy: 1e-6)
        }
    }

    func testMirrorModeNoneIsIdentity() {
        let uv = SIMD2<Float>(0.83, 0.17)
        XCTAssertEqual(FinisherMath.mirroredUV(uv, mode: .none), uv)
    }

    // MARK: Duotone luma mapping

    func testDuotoneEndpointsHitShadowAndHighlightColors() {
        let shadow: Float = 230, highlight: Float = 20
        // Luma 0 -> exactly the shadow color.
        XCTAssertEqual(FinisherMath.duotone(luma: 0, shadowHue: shadow,
                                            highlightHue: highlight),
                       FinisherMath.hueToRGB(shadow))
        // Luma 1 -> exactly the highlight color.
        XCTAssertEqual(FinisherMath.duotone(luma: 1, shadowHue: shadow,
                                            highlightHue: highlight),
                       FinisherMath.hueToRGB(highlight))
    }

    func testDuotoneClampsOutOfRangeLuma() {
        XCTAssertEqual(FinisherMath.duotone(luma: -0.5, shadowHue: 0, highlightHue: 120),
                       FinisherMath.hueToRGB(0))
        XCTAssertEqual(FinisherMath.duotone(luma: 1.5, shadowHue: 0, highlightHue: 120),
                       FinisherMath.hueToRGB(120))
    }

    func testHueWheelPrimaries() {
        XCTAssertEqual(FinisherMath.hueToRGB(0), SIMD3(1, 0, 0))     // red
        XCTAssertEqual(FinisherMath.hueToRGB(120), SIMD3(0, 1, 0))   // green
        XCTAssertEqual(FinisherMath.hueToRGB(240), SIMD3(0, 0, 1))   // blue
        XCTAssertEqual(FinisherMath.hueToRGB(360), SIMD3(1, 0, 0))   // wraps
    }
}
