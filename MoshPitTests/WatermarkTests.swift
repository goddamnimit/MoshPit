import XCTest
import Metal
import MetalKit
@testable import MoshPit

/// Free-tier watermark: placement math, the GPU pass (pixel-sampled against a
/// clean render at several resolutions/orientations), the record-start
/// entitlement latch, and that live outputs stay clean.
final class WatermarkTests: XCTestCase {

    private let sizes: [(Int, Int)] = [(1280, 720), (1920, 1080), (720, 1280),
                                       (1080, 1920), (3840, 2160)]

    // MARK: Placement math

    func testRectIsBottomRightAndScalesWithShortEdge() {
        for (w, h) in sizes {
            let r = WatermarkOverlay.rect(width: w, height: h)
            let short = CGFloat(min(w, h))
            XCTAssertGreaterThan(r.minX, CGFloat(w) / 2, "\(w)x\(h): right half")
            XCTAssertGreaterThan(r.minY, CGFloat(h) / 2, "\(w)x\(h): bottom half")
            XCTAssertLessThan(r.maxX, CGFloat(w), "\(w)x\(h): inside right margin")
            XCTAssertLessThan(r.maxY, CGFloat(h), "\(w)x\(h): inside bottom margin")
            XCTAssertEqual(r.height / short, WatermarkOverlay.heightFraction, accuracy: 0.002)
            XCTAssertEqual(CGFloat(w) - r.maxX, CGFloat(h) - r.maxY, accuracy: 1,
                           "equal margins")
        }
    }

    // MARK: GPU pass vs clean render

    private func render(ctx: MetalContext, width: Int, height: Int,
                        watermarked: Bool) -> [UInt8]? {
        let inD = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        inD.usage = .shaderRead
        inD.storageMode = .shared
        guard let input = ctx.device.makeTexture(descriptor: inD) else { return nil }
        let fill = [UInt8](repeating: 77, count: width * height * 4)   // flat dark gray
        input.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                      withBytes: fill, bytesPerRow: width * 4)
        let outD = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        outD.usage = [.shaderRead, .shaderWrite]
        outD.storageMode = .shared
        guard let out = ctx.device.makeTexture(descriptor: outD),
              let cb = ctx.queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { return nil }
        ctx.encodeOutputBlit(enc, input: input, output: out, watermarked: watermarked)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        out.getBytes(&bytes, bytesPerRow: width * 4,
                     from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return bytes
    }

    func testWatermarkOnlyChangesTheCornerAtEverySize() throws {
        let ctx = try XCTUnwrap(MetalContext(), "Metal unavailable")
        for (w, h) in sizes {
            let clean = try XCTUnwrap(render(ctx: ctx, width: w, height: h, watermarked: false))
            let marked = try XCTUnwrap(render(ctx: ctx, width: w, height: h, watermarked: true))
            let rect = WatermarkOverlay.rect(width: w, height: h).insetBy(dx: -8, dy: -8)
            var changedInside = 0
            var changedOutside = 0
            var brightened = 0
            for y in 0..<h {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    if clean[i] != marked[i] || clean[i + 1] != marked[i + 1]
                        || clean[i + 2] != marked[i + 2] {
                        if rect.contains(CGPoint(x: x, y: y)) { changedInside += 1 }
                        else { changedOutside += 1 }
                        if marked[i] > clean[i] + 40 { brightened += 1 }
                    }
                }
            }
            XCTAssertEqual(changedOutside, 0, "\(w)x\(h): nothing outside the corner may change")
            XCTAssertGreaterThan(changedInside, 100, "\(w)x\(h): the mark must be drawn")
            XCTAssertGreaterThan(brightened, 50, "\(w)x\(h): wordmark is light on dark")
            // Clean render stays a flat copy of the input.
            XCTAssertTrue(clean.allSatisfy { $0 == 77 || $0 == 255 }, "\(w)x\(h): clean pass-through")
        }
    }

    // MARK: Entitlement latched at record start

    func testRecorderLatchesWatermarkAtStart() throws {
        let ctx = try XCTUnwrap(MetalContext(), "Metal unavailable")
        let rec = MoshRecorder(ctx: ctx)
        var required = true
        rec.watermarkRequired = { required }
        rec.start(width: 64, height: 64)
        XCTAssertTrue(rec.watermarkLatched)
        required = false                     // user "buys" mid-recording
        XCTAssertTrue(rec.watermarkLatched, "free recording stays watermarked")
        rec.stop()

        rec.start(width: 64, height: 64)     // next recording sees the new state
        XCTAssertFalse(rec.watermarkLatched)
        required = true                      // refund / toggle mid-recording
        XCTAssertFalse(rec.watermarkLatched, "entitled recording stays clean")
        rec.stop()
    }

    func testRecorderFailsClosedWithoutGate() throws {
        let ctx = try XCTUnwrap(MetalContext(), "Metal unavailable")
        let rec = MoshRecorder(ctx: ctx)
        rec.start(width: 64, height: 64)
        XCTAssertTrue(rec.watermarkLatched)
        rec.stop()
    }

    // MARK: AppModel decisions

    @MainActor
    func testAppModelWatermarkFollowsEntitlement() {
        let app = AppModel()
        app.debugSetPro(false)
        XCTAssertTrue(app.watermarkRequired())
        app.debugSetPro(true)
        XCTAssertFalse(app.watermarkRequired())
        // nil = DEBUG bypass: entitled, no watermark.
        app.debugSetPro(nil)
        app.debugPreviewFreeTier = false
        XCTAssertFalse(app.watermarkRequired(), "Debug build is fully entitled")
        // DEBUG free-tier preview forces the free tier...
        app.debugPreviewFreeTier = true
        XCTAssertTrue(app.watermarkRequired())
        // ...but debugSetPro still wins.
        app.debugSetPro(true)
        XCTAssertFalse(app.watermarkRequired())
        app.debugSetPro(nil)
        app.debugPreviewFreeTier = false
    }

    @MainActor
    func testRecordingStartedFreeStaysWatermarkedAfterUnlock() throws {
        let app = AppModel()
        try XCTSkipIf(app.recorder == nil, "Metal unavailable")
        app.debugSetPro(false)
        app.recorder?.start(width: 64, height: 64)
        XCTAssertEqual(app.recorder?.watermarkLatched, true)
        app.debugSetPro(true)
        XCTAssertEqual(app.recorder?.watermarkLatched, true)
        app.recorder?.stop()
        app.debugSetPro(nil)
    }

    // MARK: Live outputs stay clean (runtime)

    /// Runtime check on the real frame fan-out: while a FREE recording is
    /// watermarking into its own pixel buffer, the shared frame texture that
    /// NDI / MJPEG consume must be unchanged. A probe consumer before the
    /// recorder and one after it each blit the texture exactly like the NDI
    /// sender does (plain blitScale); the two readbacks must be identical.
    /// (NDI/MJPEG senders themselves need a network peer / the NDI SDK, so
    /// this asserts the shared input they receive; the source-scan test
    /// below pins that their own blit is the plain kernel.)
    @MainActor
    func testSharedFrameStaysCleanWhileFreeRecorderWatermarks() throws {
        let app = AppModel()
        let renderer = try XCTUnwrap(app.renderer, "Metal unavailable")
        let ctx = try XCTUnwrap(app.ctx)
        app.sources?.setTestPattern(slot: .a, inverted: false, portrait: false)
        app.debugSetPro(false)

        func probe(_ tex: MTLTexture) -> [UInt8]? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: tex.width, height: tex.height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .shared
            guard let dst = ctx.device.makeTexture(descriptor: d),
                  let cb = ctx.queue.makeCommandBuffer(),
                  let enc = cb.makeComputeCommandEncoder() else { return nil }
            enc.setTexture(tex, index: 0)
            enc.setTexture(dst, index: 1)
            ctx.dispatch(enc, "blitScale", width: dst.width, height: dst.height)   // NDI's blit
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            var bytes = [UInt8](repeating: 0, count: dst.width * dst.height * 4)
            dst.getBytes(&bytes, bytesPerRow: dst.width * 4,
                         from: MTLRegionMake2D(0, 0, dst.width, dst.height), mipmapLevel: 0)
            return bytes
        }
        var before: [UInt8]?
        var after: [UInt8]?
        renderer.frameConsumers.insert({ tex, _ in if before == nil { before = probe(tex) } }, at: 0)
        renderer.frameConsumers.append({ tex, _ in if after == nil { after = probe(tex) } })

        app.recorder?.start(width: 64, height: 64)
        XCTAssertEqual(app.recorder?.watermarkLatched, true)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), device: ctx.device)
        view.drawableSize = CGSize(width: 320, height: 180)
        renderer.draw(in: view)
        app.recorder?.stop()

        let b = try XCTUnwrap(before, "probe consumer before the recorder never ran")
        let a = try XCTUnwrap(after, "probe consumer after the recorder never ran")
        XCTAssertEqual(b, a, "recorder must not alter the frame other outputs receive")
        app.debugSetPro(nil)
    }

    // MARK: Live outputs stay clean

    func testOnlyRecorderAndSnapshotUseTheWatermarkKernel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MoshPit")
        let fm = FileManager.default
        var users: [String] = []
        for case let url as URL in fm.enumerator(at: root, includingPropertiesForKeys: nil)! {
            guard url.pathExtension == "swift",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if text.contains("encodeOutputBlit(") || text.contains("blitScaleWatermark") {
                users.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(Set(users), ["Watermark.swift", "Outputs.swift", "Renderer.swift",
                                    "MetalContext.swift"])
        // NDI / MJPEG consumers use the plain blit: Outputs.swift's only
        // encodeOutputBlit call is inside MoshRecorder.consume.
        let outputs = try String(contentsOf: root.appendingPathComponent("Output/Outputs.swift"),
                                 encoding: .utf8)
        XCTAssertEqual(outputs.components(separatedBy: "encodeOutputBlit(").count - 1, 1)
        let recorderRange = try XCTUnwrap(outputs.range(of: "func consume(texture"))
        let mjpegRange = try XCTUnwrap(outputs.range(of: "final class MJPEGServer"))
        let callRange = try XCTUnwrap(outputs.range(of: "encodeOutputBlit("))
        XCTAssertTrue(recorderRange.lowerBound < callRange.lowerBound
                      && callRange.lowerBound < mjpegRange.lowerBound)
    }
}

@MainActor
final class RecordingInterruptionTests: XCTestCase {
    func testBackgroundingFinalizesAnActiveRecording() throws {
        let app = AppModel()
        try XCTSkipIf(app.recorder == nil, "Metal unavailable")
        app.recorder?.start(width: 64, height: 64)
        XCTAssertEqual(app.recorder?.isRecording, true)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification,
                                        object: nil)
        let stopped = expectation(description: "stopped")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { stopped.fulfill() }
        wait(for: [stopped], timeout: 2)
        XCTAssertEqual(app.recorder?.isRecording, false)
    }

    func testInterruptionWhileIdleIsANoOp() {
        let app = AppModel()
        app.stopRecordingForInterruption()
        XCTAssertNotEqual(app.recorder?.isRecording, true)
    }
}
