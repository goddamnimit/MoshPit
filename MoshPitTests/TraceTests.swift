import XCTest
import simd
@testable import MoshPit

final class TraceTests: XCTestCase {
    func testPlaneGridDimensionsAndUVs() {
        let geo = makeTraceGeometry(primitive: .plane, resolution: 32)
        XCTAssertEqual(geo.vertices.count, 32 * 32)
        // (N-1)^2 quads * 2 triangles * 3 indices.
        XCTAssertEqual(geo.triIndices.count, 31 * 31 * 6)
        // UV corners map the full texture.
        XCTAssertEqual(geo.vertices.first?.u, 0)
        XCTAssertEqual(geo.vertices.first?.v, 0)
        XCTAssertEqual(geo.vertices.last?.u, 1)
        XCTAssertEqual(geo.vertices.last?.v, 1)
        // Plane normals all +Z.
        XCTAssertTrue(geo.vertices.allSatisfy { $0.nz == 1 && $0.nx == 0 && $0.ny == 0 })
        // Index bounds sanity.
        XCTAssertTrue(geo.triIndices.allSatisfy { $0 < UInt32(geo.vertices.count) })
        XCTAssertTrue(geo.lineIndices.allSatisfy { $0 < UInt32(geo.vertices.count) })
    }

    func testPrimitiveVertexCounts() {
        for res in [32, 64] {
            XCTAssertEqual(makeTraceGeometry(primitive: .plane, resolution: res).vertices.count,
                           res * res)
            XCTAssertEqual(makeTraceGeometry(primitive: .sphere, resolution: res).vertices.count,
                           res * res)
            XCTAssertEqual(makeTraceGeometry(primitive: .torus, resolution: res).vertices.count,
                           res * res)
            // Cube: one grid per face.
            XCTAssertEqual(makeTraceGeometry(primitive: .cube, resolution: res).vertices.count,
                           6 * res * res)
        }
    }

    func testSphereVerticesLieOnSphereAndNormalsPointOut() {
        let geo = makeTraceGeometry(primitive: .sphere, resolution: 16)
        for v in geo.vertices {
            let r = (v.px * v.px + v.py * v.py + v.pz * v.pz).squareRoot()
            XCTAssertEqual(r, 0.9, accuracy: 1e-4)
            // Normal is the unit position direction.
            XCTAssertEqual(v.nx * 0.9, v.px, accuracy: 1e-4)
        }
    }

    func testTorusRadii() {
        let geo = makeTraceGeometry(primitive: .torus, resolution: 24)
        for v in geo.vertices {
            // Distance from the torus's central ring must equal the tube radius.
            let ringDist = ((v.px * v.px + v.pz * v.pz).squareRoot() - 0.7)
            let tube = (ringDist * ringDist + v.py * v.py).squareRoot()
            XCTAssertEqual(tube, 0.32, accuracy: 1e-3)
        }
    }

    func testPerspectiveMatrixBasics() {
        let m = perspectiveMatrix(fovY: .pi / 2, aspect: 1, near: 0.1, far: 100)
        // A point at the near plane on-axis maps to z(ndc) = 0 in Metal's [0,1].
        let p = m * SIMD4<Float>(0, 0, -0.1, 1)
        XCTAssertEqual(p.z / p.w, 0, accuracy: 1e-4)
    }
}

final class AspectTests: XCTestCase {
    func testCanvasAdoptsSourceAspectLongEdge() {
        // Portrait camera 720x1280 at 1080 long edge -> 1080 tall, ~606 wide.
        var (w, h) = MoshEngine.canvasDimensions(longEdge: 1080, srcW: 720, srcH: 1280)
        XCTAssertEqual(h, 1080)
        assertClose(w, to: 606, within: 2)
        XCTAssertEqual(Float(w) / Float(h), 720.0 / 1280.0, accuracy: 0.01)

        // Landscape 1920x1080 at 540 long edge -> 540 wide? No: long edge
        // means the LONG side, so 960x540.
        (w, h) = MoshEngine.canvasDimensions(longEdge: 540, srcW: 1920, srcH: 1080)
        XCTAssertEqual(w, 540)
        assertClose(h, to: 302, within: 2)

        // Square source.
        (w, h) = MoshEngine.canvasDimensions(longEdge: 360, srcW: 500, srcH: 500)
        XCTAssertEqual(w, 360); XCTAssertEqual(h, 360)
        // Even dimensions for encoders.
        XCTAssertEqual(w % 2, 0); XCTAssertEqual(h % 2, 0)
    }

    func testAspectFitNeverStretches() {
        // 16:9 B into a portrait 9:16 canvas: full width, letterboxed height.
        let fit = aspectFitUVScale(srcW: 1920, srcH: 1080, dstW: 540, dstH: 960)
        XCTAssertEqual(fit.x, 1, accuracy: 1e-4)
        XCTAssertGreaterThan(fit.y, 1)
        // Same aspect: identity.
        let same = aspectFitUVScale(srcW: 1920, srcH: 1080, dstW: 960, dstH: 540)
        XCTAssertEqual(same.x, 1, accuracy: 1e-4)
        XCTAssertEqual(same.y, 1, accuracy: 1e-4)
        // Components are never < 1 (that would crop-stretch).
        let f2 = aspectFitUVScale(srcW: 100, srcH: 400, dstW: 400, dstH: 100)
        XCTAssertGreaterThanOrEqual(f2.x, 1)
        XCTAssertGreaterThanOrEqual(f2.y, 1)
    }

    func testPlaneGeometryMatchesAspect() {
        let portrait = makeTraceGeometry(primitive: .plane, resolution: 8,
                                         planeAspect: 0.5)
        let xs = portrait.vertices.map(\.px), ys = portrait.vertices.map(\.py)
        let width = xs.max()! - xs.min()!, height = ys.max()! - ys.min()!
        XCTAssertEqual(width / height, 0.5, accuracy: 1e-3)
    }
}


