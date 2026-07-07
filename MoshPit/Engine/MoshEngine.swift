import Metal
import simd
import QuartzCore

/// Swift mirror of MoshUniforms in Mosh.metal (field order/types must match).
struct MoshUniformsSwift {
    var mode: Int32 = 0
    var smoothVectors: Int32 = 0
    var driftReplaces: Int32 = 0
    var crossMosh: Int32 = 0
    var drift: simd_float2 = .zero
    var motionGain: Float = 1
    var heal: Float = 0
    var mixAmount: Float = 0
    var bloomThreshold: Float = 0
    var bloomGate: Float = 0
    var fbZoom: Float = 0
    var fbRotate: Float = 0
    var fbOffset: simd_float2 = .zero
    var fbHue: Float = 0
    var canvasSize: simd_float2 = .zero
    var flowScale: simd_float2 = .one
    var hasSource: Int32 = 0
    var hasSourceB: Int32 = 0
    var vectorScale: simd_float2 = .one
    var bFit: simd_float2 = .one
}

struct BloomRegionSwift {
    var bias: simd_float2 = .zero
    var strength: Float = 0
    var active: Float = 0
}

/// One live timed-bloom region on the CPU side.
private struct LiveBloom {
    var bias: simd_float2
    var born: TimeInterval
    var ttl: TimeInterval
}

/// The persistent-canvas mosh core. Owns the ping-pong canvas pair (never
/// cleared while moshing), the estimation-resolution source history, and the
/// per-frame bloom/gate state machine.
final class MoshEngine {
    private let ctx: MetalContext
    private let params: ParameterStore

    // Ping-pong canvas: RGBA16Float so repeated resampling doesn't band.
    private(set) var canvasA: MTLTexture?
    private(set) var canvasB: MTLTexture?
    private var canvasIsA = true
    var canvas: MTLTexture? { canvasIsA ? canvasA : canvasB }

    // Estimation-resolution source history (ping-pong prev/cur).
    private var estCur: MTLTexture?
    private var estPrev: MTLTexture?
    private var estValid = false

    let blockMatch: BlockMatchEstimator
    let visionFlow: VisionFlowEstimator

    private var bloomBuffer: MTLBuffer
    private var liveBlooms: [LiveBloom] = []
    private var lastBloomFire: TimeInterval = 0
    private var needsReset = true
    private var hasEverSeeded = false
    private var seedFramesRemaining = 0
    private(set) var canvasWidth = 0, canvasHeight = 0
    private var estWidth = 0, estHeight = 0

    /// Thermal fallback: when hot, estimation drops one resolution step.
    var thermalDowngrade = false

    init(ctx: MetalContext, params: ParameterStore) {
        self.ctx = ctx
        self.params = params
        blockMatch = BlockMatchEstimator(ctx: ctx)
        visionFlow = VisionFlowEstimator(ctx: ctx)
        bloomBuffer = ctx.device.makeBuffer(
            length: MemoryLayout<BloomRegionSwift>.stride * 8,
            options: .storageModeShared)!
        bloomBuffer.label = "blooms"
    }

    func requestReset() { needsReset = true }

    /// Momentary bloom trigger (spacebar / touch pad tap): opens the pulse on
    /// the next frame regardless of the timer.
    func manualBloom() { lastBloomFire = 0 }

    /// Canvas dimensions from the resolution setting (LONG edge) and the
    /// active source's aspect — the source is never anisotropically scaled.
    static func canvasDimensions(longEdge: Int, srcW: Int, srcH: Int) -> (Int, Int) {
        let clampedW = min(max(srcW, 1), 4096)
        let clampedH = min(max(srcH, 1), 4096)
        let clampedLong = min(max(longEdge, 16), 4096)
        let w: Int, h: Int
        if clampedW >= clampedH {
            w = clampedLong
            h = max(16, clampedLong * clampedH / clampedW)
        } else {
            h = clampedLong
            w = max(16, clampedLong * clampedW / clampedH)
        }
        return (min(w, 4096) & ~1, min(h, 4096) & ~1)
    }

    private var srcAspectKey = 0

    /// (Re)allocate textures when the resolution setting OR the source aspect
    /// changes. An aspect change is inherently an I-frame moment: the canvas
    /// resets to the new source.
    private func ensureResources(source: MTLTexture?) {
        let resIdx = Int(params.get(.processingRes))
        let longEdge = kResolutions[min(resIdx, kResolutions.count - 1)]
        let srcW = source?.width ?? 16, srcH = source?.height ?? 9
        let (canvasW, canvasH) = Self.canvasDimensions(longEdge: longEdge,
                                                       srcW: srcW, srcH: srcH)
        var estIdx = resIdx
        if thermalDowngrade { estIdx = max(0, estIdx - 2) }
        let estLong = kResolutions[max(0, min(estIdx, kResolutions.count - 1))]
        let (estW, estH) = Self.canvasDimensions(longEdge: estLong,
                                                 srcW: srcW, srcH: srcH)

        // Aspect change (camera flip, orientation, new file): full realloc.
        let aspectKey = (srcW * 4096) / max(1, srcH)
        if source != nil, aspectKey != srcAspectKey {
            if srcAspectKey != 0 { needsReset = true }
            srcAspectKey = aspectKey
        }

        if canvasW != canvasWidth || canvasH != canvasHeight {
            canvasA = ctx.makeTexture(width: canvasW, height: canvasH,
                                      format: .rgba16Float, label: "canvas.A")
            canvasB = ctx.makeTexture(width: canvasW, height: canvasH,
                                      format: .rgba16Float, label: "canvas.B")
            canvasWidth = canvasW; canvasHeight = canvasH
            needsReset = true
        }
        if estW != estWidth || estH != estHeight {
            estCur = ctx.makeTexture(width: estW, height: estH,
                                     format: .bgra8Unorm, label: "est.cur")
            estPrev = ctx.makeTexture(width: estW, height: estH,
                                      format: .bgra8Unorm, label: "est.prev")
            estWidth = estW; estHeight = estH
            estValid = false
        }
        let bs = kBlockSizes[Int(params.get(.blockSize))]
        blockMatch.configure(estWidth: estW, estHeight: estH, blockSize: bs)
        visionFlow.configure(estWidth: estW, estHeight: estH)
    }

    private func updateBlooms(now: TimeInterval, mode: MoshMode) -> Float {
        let rate = Double(params.get(.bloomRate))
        let decay = Double(params.get(.bloomDecay))
        var gate: Float = 0

        if mode == .bloom || mode == .timedBloom {
            if now - lastBloomFire >= 1.0 / max(0.01, rate) {
                lastBloomFire = now
                gate = 1
                if mode == .timedBloom, liveBlooms.count < 8 {
                    let angle = params.get(.bloomAngle)
                    let mag = params.get(.bloomBias)
                    liveBlooms.append(LiveBloom(
                        bias: simd_float2(cos(angle), sin(angle)) * mag,
                        born: now, ttl: decay))
                }
            }
            // Bloom pulses also stay open a touch so the burst reads on screen.
            if now - lastBloomFire < 1.0 / 30.0 { gate = 1 }
        }

        liveBlooms.removeAll { now - $0.born > $0.ttl }
        let ptr = bloomBuffer.contents().bindMemory(to: BloomRegionSwift.self, capacity: 8)
        for i in 0..<8 {
            if i < liveBlooms.count {
                let b = liveBlooms[i]
                let age = Float((now - b.born) / max(0.01, b.ttl))
                ptr[i] = BloomRegionSwift(bias: b.bias, strength: 1 - age, active: 1)
            } else {
                ptr[i] = BloomRegionSwift()
            }
        }
        return gate
    }

    /// Encode one mosh step. `sourceA`/`sourceB` are the latest source frames
    /// (nil if a slot is empty). Returns the freshly written canvas texture.
    @discardableResult
    func encodeFrame(commandBuffer: MTLCommandBuffer,
                     sourceA: MTLTexture?, sourceB: MTLTexture?,
                     now: TimeInterval) -> MTLTexture? {
        ensureResources(source: sourceA)
        guard let inCanvas = canvasIsA ? canvasA : canvasB,
              let outCanvas = canvasIsA ? canvasB : canvasA,
              let estCur, let estPrev else { return nil }

        // 1. Downsample source A into the estimation-res "cur" slot.
        if let sourceA, let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.label = "downsampleA"
            enc.setTexture(sourceA, index: 0)
            enc.setTexture(estCur, index: 1)
            ctx.dispatch(enc, "blitScale", width: estCur.width, height: estCur.height)
            enc.endEncoding()
        }

        // 2. Motion estimation between consecutive estimation-res frames.
        var flow: MTLTexture?
        if estValid, sourceA != nil {
            let backend = Int(params.get(.estimatorBackend))
            let estimator: MotionEstimator = backend == 1 ? visionFlow : blockMatch
            flow = estimator.estimate(cur: estCur, prev: estPrev,
                                      commandBuffer: commandBuffer)
        }

        // 3. Reset = manual I-frame (or first frame ever). The FIRST seed
        // ever extends into a short window of continuous reseeding: the
        // camera's auto-exposure is still converging at launch, and a canvas
        // seeded from an underexposed frame would stay dark forever in the
        // smear modes (they never admit fresh pixels). Manual resets
        // mid-session stay single-frame.
        if needsReset || seedFramesRemaining > 0, let sourceA,
           let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.label = "resetCanvas"
            enc.setTexture(sourceA, index: 0)
            enc.setTexture(inCanvas, index: 1)
            ctx.dispatch(enc, "resetCanvas", width: inCanvas.width, height: inCanvas.height)
            enc.endEncoding()
            if needsReset, !hasEverSeeded {
                hasEverSeeded = true
                seedFramesRemaining = 45   // ~0.75 s at 60 fps
            } else if seedFramesRemaining > 0 {
                seedFramesRemaining -= 1
            }
            needsReset = false
        }

        // 4. The mosh pass itself.
        let mode = params.mode
        var u = MoshUniformsSwift()
        u.mode = Int32(mode.rawValue)
        u.smoothVectors = params.bool(.smoothVectors) ? 1 : 0
        u.driftReplaces = (mode == .drift && params.bool(.driftReplaces)) ? 1 : 0
        u.crossMosh = params.bool(.crossMosh) ? 1 : 0
        let driftScale = Float(canvasWidth) * 0.01
        u.drift = simd_float2(params.get(.driftX), params.get(.driftY)) * driftScale
        if mode != .drift && u.drift == .zero { u.driftReplaces = 0 }
        u.motionGain = params.get(.motionGain)
        u.heal = params.get(.heal)
        u.mixAmount = params.get(.mixAmount)
        u.bloomThreshold = params.get(.bloomThreshold) * Float(canvasWidth) * 0.05
        u.bloomGate = updateBlooms(now: now, mode: mode)
        u.fbZoom = params.get(.feedbackZoom)
        u.fbRotate = params.get(.feedbackRotate)
        u.fbOffset = simd_float2(params.get(.feedbackX), params.get(.feedbackY))
        u.fbHue = params.get(.feedbackHue)
        u.canvasSize = simd_float2(Float(canvasWidth), Float(canvasHeight))
        let vScale = simd_float2(Float(canvasWidth) / Float(max(1, estWidth)),
                                 Float(canvasHeight) / Float(max(1, estHeight)))
        u.vectorScale = vScale
        if let flow {
            u.flowScale = simd_float2(Float(canvasWidth) / Float(flow.width),
                                      Float(canvasHeight) / Float(flow.height))
        }
        u.hasSource = sourceA != nil ? 1 : 0
        u.hasSourceB = sourceB != nil ? 1 : 0
        if let b = sourceB {
            u.bFit = aspectFitUVScale(srcW: b.width, srcH: b.height,
                                      dstW: canvasWidth, dstH: canvasHeight)
        }

        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.label = "moshCanvas.\(mode.title)"
            enc.setTexture(inCanvas, index: 0)
            enc.setTexture(outCanvas, index: 1)
            enc.setTexture(sourceA ?? inCanvas, index: 2)
            enc.setTexture(sourceB ?? sourceA ?? inCanvas, index: 3)
            enc.setTexture(flow ?? inCanvas, index: 4)
            enc.setBytes(&u, length: MemoryLayout<MoshUniformsSwift>.stride, index: 0)
            enc.setBuffer(bloomBuffer, offset: 0, index: 1)
            ctx.dispatch(enc, "moshCanvas", width: canvasWidth, height: canvasHeight)
            enc.endEncoding()
        }

        // 5. Swap history & canvas for next frame.
        if sourceA != nil {
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "historySwap"
                enc.setTexture(estCur, index: 0)
                enc.setTexture(estPrev, index: 1)
                ctx.dispatch(enc, "blitScale", width: estPrev.width, height: estPrev.height)
                enc.endEncoding()
            }
            estValid = true
        }
        canvasIsA.toggle()
        return outCanvas
    }
}

/// UV scale that aspect-FITS a source of one aspect into a destination of
/// another (letterboxing via clamp-to-edge; components >= 1, never stretch).
func aspectFitUVScale(srcW: Int, srcH: Int, dstW: Int, dstH: Int) -> simd_float2 {
    guard srcW > 0, srcH > 0, dstW > 0, dstH > 0 else { return .one }
    let sa = Float(srcW) / Float(srcH)
    let da = Float(dstW) / Float(dstH)
    return simd_float2(max(1, da / sa), max(1, sa / da))
}
