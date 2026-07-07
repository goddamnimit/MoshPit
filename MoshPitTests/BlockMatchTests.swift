import XCTest
import Metal
@testable import MoshPit

/// Feeds the block-match kernel a synthetic image pair where the second frame
/// is the first translated by a known offset, and asserts the recovered
/// motion vectors match.
final class BlockMatchTests: XCTestCase {
    var ctx: MetalContext!

    override func setUpWithError() throws {
        ctx = try XCTUnwrap(MetalContext(), "Metal unavailable")
    }

    /// Deterministic "random" pattern with enough texture for SAD matching.
    private func makeFrame(width: Int, height: Int, shiftX: Int, shiftY: Int) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        let tex = ctx.device.makeTexture(descriptor: desc)!
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                // Sample the pattern at the un-shifted coordinate.
                let sx = x - shiftX, sy = y - shiftY
                let h = UInt32(truncatingIfNeeded: (sx &* 374761393) &+ (sy &* 668265263))
                let v = UInt8((h ^ (h >> 13)) & 0xFF)
                let i = (y * width + x) * 4
                pixels[i] = v; pixels[i + 1] = v &* 3; pixels[i + 2] = v &* 7; pixels[i + 3] = 255
            }
        }
        tex.replace(region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4)
        return tex
    }

    private func runBlockMatch(blockSize: Int, shift: (Int, Int)) throws -> [SIMD2<Float>] {
        let w = 128, h = 128
        let prev = makeFrame(width: w, height: h, shiftX: 0, shiftY: 0)
        let cur = makeFrame(width: w, height: h, shiftX: shift.0, shiftY: shift.1)

        let fw = w / blockSize, fh = h / blockSize
        let flowDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg32Float, width: fw, height: fh, mipmapped: false)
        flowDesc.usage = [.shaderWrite, .shaderRead]
        flowDesc.storageMode = .shared
        let flow = try XCTUnwrap(ctx.device.makeTexture(descriptor: flowDesc))

        let cb = try XCTUnwrap(ctx.queue.makeCommandBuffer())
        let enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
        var u = BlockMatchUniformsSwift(blockSize: Int32(blockSize),
                                        searchRange: 8, step: 1)
        enc.setTexture(cur, index: 0)
        enc.setTexture(prev, index: 1)
        enc.setTexture(flow, index: 2)
        enc.setBytes(&u, length: MemoryLayout<BlockMatchUniformsSwift>.stride, index: 0)
        ctx.dispatch(enc, "blockMatch", width: fw, height: fh)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        var out = [SIMD2<Float>](repeating: .zero, count: fw * fh)
        flow.getBytes(&out, bytesPerRow: fw * MemoryLayout<SIMD2<Float>>.stride,
                      from: MTLRegionMake2D(0, 0, fw, fh), mipmapLevel: 0)
        return out
    }

    func testRecoversKnownTranslation() throws {
        let shift = (4, 2)
        let vectors = try runBlockMatch(blockSize: 16, shift: shift)
        // Ignore the border blocks where the shifted pattern wraps/clamps.
        let fw = 8
        var inner: [SIMD2<Float>] = []
        for y in 1..<7 { for x in 1..<7 { inner.append(vectors[y * fw + x]) } }
        let matching = inner.filter { $0.x == Float(shift.0) && $0.y == Float(shift.1) }
        XCTAssertGreaterThan(Double(matching.count) / Double(inner.count), 0.9,
                             "most interior blocks should recover (\(shift))")
    }

    func testStaticSceneYieldsZeroVectors() throws {
        let vectors = try runBlockMatch(blockSize: 16, shift: (0, 0))
        XCTAssertTrue(vectors.allSatisfy { $0 == .zero },
                      "identical frames must produce zero motion (zero-bias tie-break)")
    }

    func testSmallBlocksRecoverTranslationToo() throws {
        let shift = (3, 5)
        let vectors = try runBlockMatch(blockSize: 8, shift: shift)
        let fw = 16
        var inner: [SIMD2<Float>] = []
        for y in 2..<14 { for x in 2..<14 { inner.append(vectors[y * fw + x]) } }
        let matching = inner.filter { $0.x == Float(shift.0) && $0.y == Float(shift.1) }
        XCTAssertGreaterThan(Double(matching.count) / Double(inner.count), 0.85)
    }

    func testEstimatorConfiguresFlowTextureAtBlockGranularity() {
        let est = BlockMatchEstimator(ctx: ctx)
        est.configure(estWidth: 960, estHeight: 540, blockSize: 16)
        XCTAssertEqual(est.latestFlow?.width, 60)
        XCTAssertEqual(est.latestFlow?.height, 33)
    }
}
