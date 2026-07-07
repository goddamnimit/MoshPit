import Metal
import Vision
import CoreVideo
import simd

/// Uniform mirror of BlockMatchUniforms in Mosh.metal.
struct BlockMatchUniformsSwift {
    var blockSize: Int32
    var searchRange: Int32
    var step: Int32
    var pad: Int32 = 0
}

/// A dense(ish) motion field estimator. `flow` is an rg32Float texture whose
/// texel grid is the estimation-resolution frame divided by `blockSize`
/// (blockSize is 1 for per-pixel estimators like Vision optical flow).
protocol MotionEstimator: AnyObject {
    var name: String { get }
    /// Encode/queue estimation from prev -> cur. Must not allocate.
    /// Returns the texture holding the freshest available flow field.
    func estimate(cur: MTLTexture, prev: MTLTexture,
                  commandBuffer: MTLCommandBuffer) -> MTLTexture?
    /// Freshest completed flow field, for stats/debug reads.
    var latestFlow: MTLTexture? { get }
    var lastDurationMS: Double { get }
}

// MARK: - Block matching (default: fast, chunky, authentically MPEG)

final class BlockMatchEstimator: MotionEstimator {
    let name = "Block Match"
    private let ctx: MetalContext
    private(set) var lastDurationMS: Double = 0
    private var flow: MTLTexture?
    var latestFlow: MTLTexture? { flow }
    private var blockSize = 16

    init(ctx: MetalContext) { self.ctx = ctx }

    func configure(estWidth: Int, estHeight: Int, blockSize: Int) {
        let fw = max(1, estWidth / blockSize), fh = max(1, estHeight / blockSize)
        self.blockSize = blockSize
        if flow == nil || flow!.width != fw || flow!.height != fh {
            flow = ctx.makeTexture(width: fw, height: fh, format: .rg32Float, label: "flow.bm")
        }
    }

    func estimate(cur: MTLTexture, prev: MTLTexture,
                  commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let flow, let enc = commandBuffer.makeComputeCommandEncoder() else { return flow }
        enc.label = "blockMatch"
        let t0 = CACurrentMediaTime()
        var u = BlockMatchUniformsSwift(
            blockSize: Int32(blockSize),
            // Wider search for bigger blocks; stride 2 keeps big searches cheap.
            searchRange: Int32(min(16, blockSize)),
            step: blockSize >= 16 ? 2 : 1)
        enc.setTexture(cur, index: 0)
        enc.setTexture(prev, index: 1)
        enc.setTexture(flow, index: 2)
        enc.setBytes(&u, length: MemoryLayout<BlockMatchUniformsSwift>.stride, index: 0)
        ctx.dispatch(enc, "blockMatch", width: flow.width, height: flow.height)
        enc.endEncoding()
        lastDurationMS = (CACurrentMediaTime() - t0) * 1000 // encode time; GPU time on HUD
        return flow
    }
}

// MARK: - Vision optical flow (accurate, heavier, runs async off the render loop)

final class VisionFlowEstimator: MotionEstimator {
    let name = "Vision Flow"
    private let ctx: MetalContext
    private(set) var lastDurationMS: Double = 0

    private var pool: CVPixelBufferPool?
    private var texCache: CVMetalTextureCache?
    private var curPB: CVPixelBuffer?, prevPB: CVPixelBuffer?
    private var curPBTex: MTLTexture?, prevPBTex: MTLTexture?
    private var flow: MTLTexture?          // latest completed field (rg32Float)
    var latestFlow: MTLTexture? { flow }
    private let queue = DispatchQueue(label: "moshpit.visionflow", qos: .userInitiated)
    private var busy = false
    private var estW = 0, estH = 0

    init(ctx: MetalContext) {
        self.ctx = ctx
        CVMetalTextureCacheCreate(nil, nil, ctx.device, nil, &texCache)
    }

    func configure(estWidth: Int, estHeight: Int) {
        guard estWidth != estW || estHeight != estH else { return }
        estW = estWidth; estH = estHeight
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: estWidth,
            kCVPixelBufferHeightKey as String: estHeight,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        curPB = makePB(); prevPB = makePB()
        curPBTex = wrap(curPB); prevPBTex = wrap(prevPB)
        flow = ctx.makeTexture(width: estWidth, height: estHeight,
                               format: .rg32Float, label: "flow.vision")
    }

    private func makePB() -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }

    private func wrap(_ pb: CVPixelBuffer?) -> MTLTexture? {
        guard let pb, let texCache else { return nil }
        var cvTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, texCache, pb, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &cvTex)
        return cvTex.flatMap(CVMetalTextureGetTexture)
    }

    func estimate(cur: MTLTexture, prev: MTLTexture,
                  commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let curPBTex, let prevPBTex, let curPB, let prevPB, let flow,
              !busy else { return flow }
        // Copy frames into Vision-readable pixel buffers on the GPU.
        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.label = "visionFlow.prep"
            enc.setTexture(cur, index: 0); enc.setTexture(curPBTex, index: 1)
            ctx.dispatch(enc, "blitScale", width: curPBTex.width, height: curPBTex.height)
            enc.setTexture(prev, index: 0); enc.setTexture(prevPBTex, index: 1)
            ctx.dispatch(enc, "blitScale", width: prevPBTex.width, height: prevPBTex.height)
            enc.endEncoding()
        }
        busy = true
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.queue.async { self?.runVision(cur: curPB, prev: prevPB) }
        }
        return flow
    }

    private func runVision(cur: CVPixelBuffer, prev: CVPixelBuffer) {
        defer { busy = false }
        let t0 = CACurrentMediaTime()
        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: cur)
        request.computationAccuracy = .low     // still far heavier than block match
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        let handler = VNImageRequestHandler(cvPixelBuffer: prev)
        guard (try? handler.perform([request])) != nil,
              let obs = request.results?.first as? VNPixelBufferObservation,
              let flow, let texCache else { return }

        // Wrap Vision's two-component float buffer and copy it into our field.
        var cvTex: CVMetalTexture?
        let pb = obs.pixelBuffer
        CVMetalTextureCacheCreateTextureFromImage(
            nil, texCache, pb, nil, .rg32Float,
            CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &cvTex)
        guard let src = cvTex.flatMap(CVMetalTextureGetTexture),
              let cb = ctx.queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { return }
        enc.label = "visionFlow.copy"
        enc.setTexture(src, index: 0); enc.setTexture(flow, index: 1)
        ctx.dispatch(enc, "blitScale", width: flow.width, height: flow.height)
        enc.endEncoding()
        cb.commit()
        lastDurationMS = (CACurrentMediaTime() - t0) * 1000
    }
}

import QuartzCore
