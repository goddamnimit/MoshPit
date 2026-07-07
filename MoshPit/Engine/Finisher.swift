import Metal
import simd

/// Mirror of FinisherUniforms in Effects.metal.
struct FinisherUniformsSwift {
    var mirrorMode: Int32
    var mirrorRightToLeft: Int32
    var colorMode: Int32
    var shadowHue: Float
    var highlightHue: Float
    var hueShift: Float
    var pad0: Float = 0, pad1: Float = 0
}

enum MirrorMode: Int, CaseIterable {
    case none = 0, horizontal, vertical, quad
    var title: String {
        switch self {
        case .none: return "None"
        case .horizontal: return "Horiz"
        case .vertical: return "Vert"
        case .quad: return "Quad"
        }
    }
}

enum ColorMode: Int, CaseIterable {
    case none = 0, invert, duotone, hueShift
    var title: String {
        switch self {
        case .none: return "None"
        case .invert: return "Invert"
        case .duotone: return "Duotone"
        case .hueShift: return "Hue Shift"
        }
    }
}

/// Pure math shared conceptually with the finisherPass kernel — unit-tested
/// here so the shader's UV folding and duotone mapping have a CPU reference.
enum FinisherMath {
    /// Where the kernel samples the input for an output pixel at `uv`.
    static func mirroredUV(_ uv: SIMD2<Float>, mode: MirrorMode,
                           rightToLeft: Bool = false) -> SIMD2<Float> {
        var r = uv
        switch mode {
        case .none: break
        case .horizontal:
            r.x = rightToLeft ? max(uv.x, 1 - uv.x) : min(uv.x, 1 - uv.x)
        case .vertical:
            r.y = min(uv.y, 1 - uv.y)
        case .quad:
            r = SIMD2(min(uv.x, 1 - uv.x), min(uv.y, 1 - uv.y))
        }
        return r
    }

    /// Full-saturation hue wheel (degrees) -> RGB. Matches hueWheel in Metal.
    static func hueToRGB(_ degrees: Float) -> SIMD3<Float> {
        let h = (degrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / 60
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        switch h {
        case ..<1: return SIMD3(1, x, 0)
        case ..<2: return SIMD3(x, 1, 0)
        case ..<3: return SIMD3(0, 1, x)
        case ..<4: return SIMD3(0, x, 1)
        case ..<5: return SIMD3(x, 0, 1)
        default: return SIMD3(1, 0, x)
        }
    }

    /// Duotone: luma 0 -> shadow color, luma 1 -> highlight color.
    static func duotone(luma: Float, shadowHue: Float,
                        highlightHue: Float) -> SIMD3<Float> {
        let l = min(max(luma, 0), 1)
        return mix(hueToRGB(shadowHue), hueToRGB(highlightHue), t: SIMD3(repeating: l))
    }
}

/// The post-chain finisher pass (mirror + color modes). Runs after strukt/
/// trace, before the preview blit — its output feeds preview AND all frame
/// consumers, so recordings and snapshots capture the mirrored result.
final class FinisherPass {
    private let ctx: MetalContext
    private let params: ParameterStore
    private var out: MTLTexture?

    init(ctx: MetalContext, params: ParameterStore) {
        self.ctx = ctx
        self.params = params
    }

    /// Returns `input` untouched when both modes are off (zero GPU cost).
    func encode(commandBuffer: MTLCommandBuffer, input: MTLTexture) -> MTLTexture {
        let mirror = Int(params.get(.mirrorMode))
        let color = Int(params.get(.colorMode))
        guard mirror != 0 || color != 0 else { return input }
        if out == nil || out!.width != input.width || out!.height != input.height
            || out!.pixelFormat != input.pixelFormat {
            out = ctx.makeTexture(width: input.width, height: input.height,
                                  format: input.pixelFormat, label: "finisher.out")
        }
        guard let out, let enc = commandBuffer.makeComputeCommandEncoder() else { return input }
        enc.label = "finisherPass"
        var u = FinisherUniformsSwift(
            mirrorMode: Int32(mirror),
            mirrorRightToLeft: params.bool(.mirrorRightToLeft) ? 1 : 0,
            colorMode: Int32(color),
            shadowHue: params.get(.duotoneShadowHue),
            highlightHue: params.get(.duotoneHighlightHue),
            hueShift: params.get(.colorHueShift))
        enc.setTexture(input, index: 0)
        enc.setTexture(out, index: 1)
        enc.setBytes(&u, length: MemoryLayout<FinisherUniformsSwift>.stride, index: 0)
        ctx.dispatch(enc, "finisherPass", width: out.width, height: out.height)
        enc.endEncoding()
        return out
    }
}
