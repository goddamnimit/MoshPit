import Metal
import simd

enum EffectID: String, CaseIterable, Identifiable, Codable {
    case echo, slitscan, weaver, pixelSort, procAmp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .echo: return "Echo"
        case .slitscan: return "SSSScan"
        case .weaver: return "Weaver"
        case .pixelSort: return "PXLMSH"
        case .procAmp: return "Proc-Amp"
        }
    }
    var enableParam: ParameterID {
        switch self {
        case .echo: return .echoEnabled
        case .slitscan: return .slitscanEnabled
        case .weaver: return .weaverEnabled
        case .pixelSort: return .pixelSortEnabled
        case .procAmp: return .procAmpEnabled
        }
    }
}

private struct EchoU { var layers: Int32; var head: Int32; var keyLow: Float; var keyHigh: Float }
private struct SlitU { var head: Int32; var depth: Int32; var phase: Float; var angle: Float
                       var scrub: Float; var useSourceB: Int32; var pad0: Float = 0; var pad1: Float = 0 }
private struct WeaverU { var amount: Float; var p0: Float = 0; var p1: Float = 0; var p2: Float = 0 }
private struct SortU { var threshold: Float; var vertical: Int32; var p0: Float = 0; var p1: Float = 0 }
private struct ProcU { var brightness: Float; var contrast: Float; var saturation: Float
                       var hue: Float; var gamma: Float; var p0: Float = 0; var p1: Float = 0; var p2: Float = 0 }

/// Ordered, toggleable post-canvas effects. Echo and SSSScan share a frame
/// history ring buffer (texture2d_array allocated from an MTLHeap, capped at
/// 540p so 24 frames of history stay memory-sane on phones).
final class EffectChain {
    /// User-reorderable. Persisted by AppModel.
    var order: [EffectID] = [.echo, .slitscan, .weaver, .pixelSort, .procAmp]

    private let ctx: MetalContext
    private let params: ParameterStore
    private var ping: MTLTexture?
    private var pong: MTLTexture?
    private var w = 0, h = 0

    // Frame history ring
    static let ringSlices = 24
    private var heap: MTLHeap?
    private var ring: MTLTexture?
    private var ringHead = 0
    private var slitPhase: Float = 0

    init(ctx: MetalContext, params: ParameterStore) {
        self.ctx = ctx
        self.params = params
    }

    private func ensure(width: Int, height: Int) {
        guard width != w || height != h else { return }
        w = width; h = height
        ping = ctx.makeTexture(width: w, height: h, format: .rgba16Float, label: "fx.ping")
        pong = ctx.makeTexture(width: w, height: h, format: .rgba16Float, label: "fx.pong")

        // Ring buffer at most 540p — history layers don't need full res.
        let rh = min(h, 540), rw = rh * w / max(1, h)
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .bgra8Unorm
        desc.width = rw; desc.height = rh
        desc.arrayLength = Self.ringSlices
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        let sa = ctx.device.heapTextureSizeAndAlign(descriptor: desc)
        let heapDesc = MTLHeapDescriptor()
        heapDesc.size = sa.size + sa.align
        heapDesc.storageMode = .private
        heap = ctx.device.makeHeap(descriptor: heapDesc)
        heap?.label = "fx.ringHeap"
        ring = heap?.makeTexture(descriptor: desc)
        ring?.label = "fx.ring"
        ringHead = 0
    }

    /// Runs the enabled effects over `input`; returns the final texture.
    func encode(commandBuffer: MTLCommandBuffer, input: MTLTexture,
                sourceB: MTLTexture?, dt: Float) -> MTLTexture {
        ensure(width: input.width, height: input.height)
        guard let ping, let pong, let ring else { return input }

        let needsRing = params.bool(.echoEnabled) || params.bool(.slitscanEnabled)
        if needsRing, let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.label = "fx.ringStore"
            ringHead = (ringHead + 1) % Self.ringSlices
            var head = Int32(ringHead)
            enc.setTexture(input, index: 0)
            enc.setTexture(ring, index: 1)
            enc.setBytes(&head, length: 4, index: 0)
            ctx.dispatch(enc, "echoStore", width: ring.width, height: ring.height)
            enc.endEncoding()
        }
        slitPhase += params.get(.slitscanSpeed) * dt * 0.25

        var cur = input
        var dst = ping
        func swapDst() { dst = (dst === ping) ? pong : ping }

        for effect in order where params.bool(effect.enableParam) {
            guard let enc = commandBuffer.makeComputeCommandEncoder() else { continue }
            enc.label = "fx.\(effect.rawValue)"
            enc.setTexture(cur, index: 0)
            enc.setTexture(dst, index: 1)
            switch effect {
            case .echo:
                var u = EchoU(layers: Int32(max(2, Int(params.get(.echoLayers)))),
                              head: Int32(ringHead),
                              keyLow: params.get(.echoKeyLow),
                              keyHigh: params.get(.echoKeyHigh))
                enc.setTexture(ring, index: 2)
                enc.setBytes(&u, length: MemoryLayout<EchoU>.stride, index: 0)
                ctx.dispatch(enc, "echoEffect", width: w, height: h)
            case .slitscan:
                let useB = params.bool(.slitscanUseB) && sourceB != nil
                var u = SlitU(head: Int32(ringHead), depth: Int32(Self.ringSlices),
                              phase: slitPhase, angle: params.get(.slitscanAngle),
                              scrub: params.get(.slitscanScrub), useSourceB: useB ? 1 : 0)
                enc.setTexture(ring, index: 2)
                enc.setTexture(useB ? sourceB! : cur, index: 3)
                enc.setBytes(&u, length: MemoryLayout<SlitU>.stride, index: 0)
                ctx.dispatch(enc, "slitscanEffect", width: w, height: h)
            case .weaver:
                guard let b = sourceB else { enc.endEncoding(); continue }
                var u = WeaverU(amount: params.get(.weaverAmount))
                enc.setTexture(b, index: 2)
                enc.setBytes(&u, length: MemoryLayout<WeaverU>.stride, index: 0)
                ctx.dispatch(enc, "weaverEffect", width: w, height: h)
            case .pixelSort:
                var u = SortU(threshold: params.get(.pixelSortThreshold),
                              vertical: params.bool(.pixelSortVertical) ? 1 : 0)
                enc.setBytes(&u, length: MemoryLayout<SortU>.stride, index: 0)
                ctx.dispatch(enc, "pixelSortEffect", width: w, height: h)
            case .procAmp:
                var u = ProcU(brightness: params.get(.brightness),
                              contrast: params.get(.contrast),
                              saturation: params.get(.saturation),
                              hue: params.get(.hueShift),
                              gamma: params.get(.gamma))
                enc.setBytes(&u, length: MemoryLayout<ProcU>.stride, index: 0)
                ctx.dispatch(enc, "procAmpEffect", width: w, height: h)
            }
            enc.endEncoding()
            cur = dst
            swapDst()
        }
        return cur
    }
}
