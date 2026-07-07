import MetalKit
import QuartzCore

/// Per-frame stats for the debug HUD and the video-as-controller mod source.
struct FrameStats {
    var fps: Double = 0
    var gpuMS: Double = 0
    var estimatorMS: Double = 0
    var meanMotionMag: Float = 0        // estimation-res px/frame
    var meanMotion: SIMD2<Float> = .zero
    var meanLuma: Float = 0
    var lfo1: Float = 0
    var lfo2: Float = 0
    var thermal: ProcessInfo.ThermalState = .nominal
}

/// MTKView delegate: pulls source frames, runs the engine + effect chain,
/// fans the final texture out to preview / recorder / streamers, and feeds
/// the HUD. Triple-buffered with a semaphore; zero allocation at steady state.
final class MoshRenderer: NSObject, MTKViewDelegate {
    let ctx: MetalContext
    let engine: MoshEngine
    let effects: EffectChain
    let finisher: FinisherPass
    /// Shared watermark/blit choke point for exported artifacts (snapshots
    /// here, recordings in MoshRecorder). Output-format textures only.
    let watermarkCompositor: WatermarkCompositor
    private let params: ParameterStore
    private let sources: SourceManager
    private let automation: AutomationEngine

    /// Preview scaling: true = aspect-fill (center-crop), false = aspect-fit.
    /// Affects the on-screen pass only; frame consumers stay uncropped.
    var previewFill = true

    /// Hold-to-preview: transient clean passthrough while the Reset button is
    /// held. The canvas ping-pong is untouched, so releasing resumes the mosh
    /// exactly where it left off.
    var holdBypass = false
    private var wasClean = false
    #if DEBUG
    private var loggedFirstRender = false
    private var loggedNilDrawable = false
    private var loggedZeroDrawable = false
    /// -nouv: bypass the aspect uv transform (identity) to isolate blit bugs.
    private let debugIdentityUV = ProcessInfo.processInfo.arguments.contains("-nouv")
    #endif

    /// Consumers of the final composited frame (recorder, MJPEG, NDI).
    var frameConsumers: [(MTLTexture, CMTime) -> Void] = []

    /// One-shot snapshot: the NEXT rendered frame is blitted to a shared
    /// BGRA texture inside the frame's own command buffer (no stall) and the
    /// handler fires from its completion — read bytes there, off the render
    /// path. Captures the post-finisher frame: what you see is what you save.
    private var snapshotHandler: ((MTLTexture?) -> Void)?
    private var snapshotTex: MTLTexture?
    /// Latched per snapshot at trigger time (free tier watermarking).
    private var snapshotWatermark = false

    func requestSnapshot(watermark: Bool = false,
                         _ handler: @escaping (MTLTexture?) -> Void) {
        snapshotWatermark = watermark
        snapshotHandler = handler
    }

    private func encodeSnapshotIfNeeded(commandBuffer cb: MTLCommandBuffer,
                                        final: MTLTexture) {
        guard let handler = snapshotHandler else { return }
        snapshotHandler = nil
        if snapshotTex == nil || snapshotTex!.width != final.width
            || snapshotTex!.height != final.height {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: final.width, height: final.height,
                mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .shared            // CPU-readable after completion
            snapshotTex = ctx.device.makeTexture(descriptor: d)
            snapshotTex?.label = "snapshot.readback"
        }
        guard let dst = snapshotTex else {
            DispatchQueue.main.async { handler(nil) }
            return
        }
        // Same compositor as the recorder — the ONLY watermark code path.
        watermarkCompositor.encodeBlit(from: final, to: dst,
                                       watermark: snapshotWatermark,
                                       commandBuffer: cb)
        cb.addCompletedHandler { _ in handler(dst) }
    }
    var onStats: ((FrameStats) -> Void)?
    var modTap: ((FrameStats) -> Void)?

    private let inflight = DispatchSemaphore(value: 3)
    private var statsBuffers: [MTLBuffer] = []
    private var statsIndex = 0
    private var lastFrameTime: TimeInterval = 0
    private var fpsAccum: [Double] = []
    private var startTime = CACurrentMediaTime()

    let strukt: StruktEngine
    private var struktTex: MTLTexture?
    private var struktGates = StruktGates()
    let trace: TraceRenderer
    private var wipeTex: MTLTexture?

    init(ctx: MetalContext, params: ParameterStore, sources: SourceManager,
         automation: AutomationEngine) {
        self.ctx = ctx
        self.params = params
        self.sources = sources
        self.automation = automation
        engine = MoshEngine(ctx: ctx, params: params)
        effects = EffectChain(ctx: ctx, params: params)
        finisher = FinisherPass(ctx: ctx, params: params)
        watermarkCompositor = WatermarkCompositor(ctx: ctx)
        strukt = StruktEngine(params: params)
        trace = TraceRenderer(ctx: ctx, params: params)
        super.init()
        for i in 0..<3 {
            let b = ctx.device.makeBuffer(length: 6 * 4, options: .storageModeShared)!
            b.label = "stats.\(i)"
            statsBuffers.append(b)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(thermalChanged),
            name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }

    @objc private func thermalChanged() {
        // Serious/critical: run the estimator two resolution steps down and
        // warn on the HUD. Recovers automatically when the device cools.
        engine.thermalDowngrade = ProcessInfo.processInfo.thermalState.rawValue
            >= ProcessInfo.ThermalState.serious.rawValue
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // Zero-size backing (first layout not committed yet): presenting
        // would show nothing — skip until geometry lands.
        guard view.drawableSize.width >= 1, view.drawableSize.height >= 1 else {
            #if DEBUG
            if !loggedZeroDrawable {
                loggedZeroDrawable = true
                print("Renderer: zero-size drawable, skipping until layout")
            }
            #endif
            return
        }
        inflight.wait()
        guard let cb = ctx.queue.makeCommandBuffer() else { inflight.signal(); return }
        cb.label = "moshpit.frame"

        automation.tick()

        let now = CACurrentMediaTime()
        let dt = lastFrameTime > 0 ? Float(now - lastFrameTime) : 1.0 / 60.0
        lastFrameTime = now

        var texA = sources.texture(for: .a)
        let texB = sources.texture(for: .b)

        #if DEBUG
        if !loggedFirstRender, let t = texA {
            loggedFirstRender = true
            print("Renderer: source texture \(t.width)x\(t.height) " +
                  "pixelFormat=\(t.pixelFormat.rawValue) (bgra8Unorm=\(MTLPixelFormat.bgra8Unorm.rawValue)) " +
                  "present=yes drawable=\(Int(view.drawableSize.width))x\(Int(view.drawableSize.height))")
        }
        #endif

        // Clean mode / hold-to-preview: true passthrough. No estimation, no
        // canvas pass, no effects, no strukt/trace/wipe — source straight to
        // the preview blit and output taps. GPU cost ~= one blit.
        let isCleanMode = params.mode == .clean
        let clean = isCleanMode || holdBypass
        if isCleanMode != wasClean {
            wasClean = isCleanMode
            // Leaving Clean: seed the canvas with the current frame (manual
            // I-frame) so moshing starts from a clean state.
            if !wasClean { engine.requestReset() }
        }
        if clean {
            let final = texA
            if let final {
                if let rpd = view.currentRenderPassDescriptor,
                   let drawable = view.currentDrawable,
                   let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
                    enc.label = "preview.clean"
                    enc.setRenderPipelineState(ctx.previewPipeline)
                    var uvScale = MoshRenderer.previewUVScale(
                        drawableW: Double(view.drawableSize.width),
                        drawableH: Double(view.drawableSize.height),
                        texW: Double(final.width), texH: Double(final.height),
                        fill: previewFill)
                    #if DEBUG
                    if debugIdentityUV { uvScale = SIMD2<Float>(1, 1) }
                    #endif
                    enc.setVertexBytes(&uvScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                    enc.setFragmentTexture(final, index: 0)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    enc.endEncoding()
                    cb.present(drawable)
                } else {
                    #if DEBUG
                    if !loggedNilDrawable {
                        loggedNilDrawable = true
                        print("Renderer: nil drawable, skipping frame")
                    }
                    #endif
                }
            }
            if let final { encodeSnapshotIfNeeded(commandBuffer: cb, final: final) }
            let frameTime = now - startTime
            cb.addCompletedHandler { [weak self] buf in
                guard let self else { return }
                self.inflight.signal()
                var stats = FrameStats()
                stats.gpuMS = (buf.gpuEndTime - buf.gpuStartTime) * 1000
                stats.thermal = ProcessInfo.processInfo.thermalState
                self.fpsAccum.append(frameTime)
                self.fpsAccum.removeAll { frameTime - $0 > 1 }
                stats.fps = Double(self.fpsAccum.count)
                self.modTap?(stats)
                DispatchQueue.main.async { self.onStats?(stats) }
            }
            cb.commit()
            if let final {
                let t = CMTime(seconds: now, preferredTimescale: 240)
                for consumer in frameConsumers { consumer(final, t) }
            }
            return
        }

        // Mixer wipe (pre-canvas): blend A/B into the frame that FEEDS the
        // mosh engine, so wipes get moshed. Crossfader is a prime LFO target.
        let wipeMode = Int(params.get(.wipeMode))
        let crossfade = params.get(.mixCrossfade)
        if let a = texA, let b = texB, crossfade > 0.0001 || wipeMode > 0 {
            if wipeTex == nil || wipeTex!.width != a.width || wipeTex!.height != a.height {
                wipeTex = ctx.makeTexture(width: a.width, height: a.height,
                                          format: .bgra8Unorm, label: "wipe.out")
            }
            let mod = sources.texture(for: .mod)
            let lumaTex: MTLTexture? = wipeMode == 2
                ? mod
                : (params.bool(.wipeLumaFromMod) ? (mod ?? b) : b)
            if let out = wipeTex, let enc = cb.makeComputeCommandEncoder() {
                enc.label = "mixWipe"
                var u = WipeUniformsSwift(crossfade: crossfade,
                                          softness: params.get(.wipeSoftness),
                                          mode: Int32(wipeMode),
                                          hasMask: lumaTex != nil ? 1 : 0)
                u.bFit = aspectFitUVScale(srcW: b.width, srcH: b.height,
                                          dstW: a.width, dstH: a.height)
                if let m = lumaTex {
                    u.maskFit = aspectFitUVScale(srcW: m.width, srcH: m.height,
                                                 dstW: a.width, dstH: a.height)
                }
                enc.setTexture(a, index: 0)
                enc.setTexture(b, index: 1)
                enc.setTexture(lumaTex ?? b, index: 2)
                enc.setTexture(out, index: 3)
                enc.setBytes(&u, length: MemoryLayout<WipeUniformsSwift>.stride, index: 0)
                ctx.dispatch(enc, "mixWipe", width: out.width, height: out.height)
                enc.endEncoding()
                texA = out
            }
        }

        // Cross-mosh source swap: "vectors of A displace pixels of B" is the
        // engine's cross path; the mode itself covers B->A by slot swapping.
        var final: MTLTexture?
        if let moshed = engine.encodeFrame(commandBuffer: cb, sourceA: texA,
                                           sourceB: texB, now: now) {
            final = effects.encode(commandBuffer: cb, input: moshed,
                                   sourceB: texB, dt: dt)
        } else {
            final = nil
        }

        // Strukt strobe pass — the final decision before output.
        struktGates = strukt.tick(now: now)
        if let chained = final, struktGates.active {
            if struktTex == nil || struktTex!.width != chained.width
                || struktTex!.height != chained.height {
                struktTex = ctx.makeTexture(width: chained.width, height: chained.height,
                                            format: .rgba16Float, label: "strukt.out")
            }
            if let out = struktTex, let enc = cb.makeComputeCommandEncoder() {
                enc.label = "struktPass"
                var u = StruktUniformsSwift(
                    flip: struktGates.flip ? 1 : 0,
                    invert: struktGates.invert ? 1 : 0,
                    flash: struktGates.flash,
                    flashWhite: struktGates.flashWhite ? 1 : 0,
                    hasSourceB: texB != nil ? 1 : 0)
                enc.setTexture(chained, index: 0)
                enc.setTexture(out, index: 1)
                enc.setTexture(texB ?? chained, index: 2)
                enc.setBytes(&u, length: MemoryLayout<StruktUniformsSwift>.stride, index: 0)
                ctx.dispatch(enc, "struktPass", width: out.width, height: out.height)
                enc.endEncoding()
                final = out
            }
        }

        // Trace/Mass 3D path: render the (strobed) canvas onto geometry.
        // The 3D frame replaces the flat one for preview AND consumers.
        if params.bool(.trace3D), let canvasFrame = final {
            final = trace.encode(commandBuffer: cb, canvas: canvasFrame, dt: dt) ?? final
        }

        // Finisher (mirror + color modes) — last image pass before output, so
        // preview AND recorder/NDI/MJPEG all see the finished frame.
        if let chained = final {
            final = finisher.encode(commandBuffer: cb, input: chained)
        }

        // Motion statistics for HUD + mod matrix (read back next frame).
        let statsBuf = statsBuffers[statsIndex]
        statsIndex = (statsIndex + 1) % statsBuffers.count
        memset(statsBuf.contents(), 0, statsBuf.length)
        if let flowTex = currentFlowTexture(), let src = texA,
           let enc = cb.makeComputeCommandEncoder() {
            enc.label = "motionStats"
            enc.setTexture(flowTex, index: 0)
            enc.setTexture(src, index: 1)
            enc.setBuffer(statsBuf, offset: 0, index: 0)
            ctx.dispatch(enc, "motionStats",
                         width: max(flowTex.width, src.width / 8),
                         height: max(flowTex.height, src.height / 8))
            enc.endEncoding()
        }

        // Preview render pass. Fill (default) scales the canvas to COVER the
        // drawable, center-cropping the overflow (Instagram-story style);
        // Fit letterboxes so the whole frame is visible. Preview-only:
        // recording/NDI/MJPEG consumers get the full uncropped texture.
        if let final, view.currentRenderPassDescriptor == nil || view.currentDrawable == nil {
            _ = final
            #if DEBUG
            if !loggedNilDrawable {
                loggedNilDrawable = true
                print("Renderer: nil drawable, skipping frame")
            }
            #endif
        }
        if let final, let rpd = view.currentRenderPassDescriptor,
           let drawable = view.currentDrawable,
           let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            enc.label = "preview"
            enc.setRenderPipelineState(ctx.previewPipeline)
            // Full-screen quad; the vertex uv transform does the centered
            // crop (fill) or letterbox expand (fit).
            var uvScale = MoshRenderer.previewUVScale(
                drawableW: Double(view.drawableSize.width),
                drawableH: Double(view.drawableSize.height),
                texW: Double(final.width), texH: Double(final.height),
                fill: previewFill)
            #if DEBUG
            if debugIdentityUV { uvScale = SIMD2<Float>(1, 1) }
            #endif
            enc.setVertexBytes(&uvScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            enc.setFragmentTexture(final, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
            cb.present(drawable)
        }

        if let final { encodeSnapshotIfNeeded(commandBuffer: cb, final: final) }

        let frameTime = now - startTime
        cb.addCompletedHandler { [weak self] buf in
            guard let self else { return }
            self.inflight.signal()
            var stats = FrameStats()
            stats.gpuMS = (buf.gpuEndTime - buf.gpuStartTime) * 1000
            stats.thermal = ProcessInfo.processInfo.thermalState
            let backend = Int(self.params.get(.estimatorBackend))
            stats.estimatorMS = backend == 1
                ? self.engine.visionFlow.lastDurationMS
                : self.engine.blockMatch.lastDurationMS
            // Fixed-point stats readback.
            let p = statsBuf.contents().bindMemory(to: UInt32.self, capacity: 6)
            let count = max(1, Float(p[3]))
            stats.meanMotionMag = Float(p[0]) / 256.0 / count
            stats.meanMotion = SIMD2(Float(p[1]) / 256.0 / count - 64.0,
                                     Float(p[2]) / 256.0 / count - 64.0)
            stats.meanLuma = Float(p[4]) / 256.0 / max(1, Float(p[5]))
            stats.lfo1 = self.strukt.value1
            stats.lfo2 = self.strukt.value2
            self.fpsAccum.append(frameTime)
            self.fpsAccum.removeAll { frameTime - $0 > 1 }
            stats.fps = Double(self.fpsAccum.count)
            self.modTap?(stats)
            DispatchQueue.main.async { self.onStats?(stats) }
        }
        cb.commit()

        // Fan out the final frame to recorder / streamers on this thread —
        // they only enqueue GPU-side blits or grab the texture reference.
        if let final {
            let t = CMTime(seconds: now, preferredTimescale: 240)
            for consumer in frameConsumers { consumer(final, t) }
        }
    }

    /// Pure preview scaling math (unit-tested): fill => both uv components
    /// <= 1 (center-crop covers the screen); fit => both >= 1 (letterbox).
    static func previewUVScale(drawableW dw: Double, drawableH dh: Double,
                               texW tw: Double, texH th: Double,
                               fill: Bool) -> SIMD2<Float> {
        let scale = fill ? max(dw / tw, dh / th) : min(dw / tw, dh / th)
        return SIMD2(Float(dw / (tw * scale)), Float(dh / (th * scale)))
    }

    private func currentFlowTexture() -> MTLTexture? {
        Int(params.get(.estimatorBackend)) == 1
            ? engine.visionFlow.latestFlow
            : engine.blockMatch.latestFlow
    }
}

import AVFoundation


/// Mirror of StruktUniforms in Strukt.metal.
struct StruktUniformsSwift {
    var flip: Int32
    var invert: Int32
    var flash: Float
    var flashWhite: Int32
    var hasSourceB: Int32
    var pad0: Int32 = 0, pad1: Int32 = 0, pad2: Int32 = 0
}

/// Mirror of WipeUniforms in Strukt.metal.
struct WipeUniformsSwift {
    var crossfade: Float
    var softness: Float
    var mode: Int32
    var hasMask: Int32
    var bFit: SIMD2<Float> = .one
    var maskFit: SIMD2<Float> = .one
}
