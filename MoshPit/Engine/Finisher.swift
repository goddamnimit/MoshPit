import Metal
import simd
import CoreGraphics
import CoreText

/// Mirror of FinisherUniforms in Effects.metal.
struct FinisherUniformsSwift {
    var mirrorMode: Int32
    var mirrorRightToLeft: Int32
    var colorMode: Int32
    var shadowHue: Float
    var highlightHue: Float
    var hueShift: Float
    var gridWarpEnabled: Int32
    var gridWarpCellSize: Float
    var gridWarpIntensity: Float
    var gridWarpLineOpacity: Float
    var gridWarpPhase: Float
    var sheetEnabled: Int32
    var sheetCols: Float
    var sheetRows: Float
    var sheetChromeOpacity: Float
    var sheetLineOpacity: Float
    var sheetSelPhase: Float
    var sheetRevealMode: Int32
    var hudEnabled: Int32
    var hudPointCount: Float
    var hudLabelDensity: Float
    var hudLineOpacity: Float
    var hudHue: Float
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
    /// Accumulated grid-warp phase (cells drift by ~gridWarpAnimSpeed per second).
    private var gridWarpPhase: Float = 0
    /// Accumulated spreadsheet selection phase, in cells (selectionSpeed/sec).
    private var sheetSelPhase: Float = 0
    /// 36-slot glyph atlas (0-9 then A-Z), baked once; nil if baking failed.
    private lazy var glyphAtlas: MTLTexture? = Self.makeGlyphAtlas(device: ctx.device)

    init(ctx: MetalContext, params: ParameterStore) {
        self.ctx = ctx
        self.params = params
    }

    /// Bakes the shared glyph atlas (digits, capitals, then ':' for the
    /// tracking HUD's coordinate readouts) into a single-row RGBA texture via
    /// CoreText — no runtime text layout in the render loop, the shaders just
    /// sample this texture. Slot count must match /37.0 in Effects.metal.
    private static func makeGlyphAtlas(device: MTLDevice) -> MTLTexture? {
        let glyphW = 32, glyphH = 48
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ:")
        let width = glyphW * chars.count
        guard let cg = CGContext(
            data: nil, width: width, height: glyphH, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, 34, nil)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        for (i, ch) in chars.enumerated() {
            let attrs = [kCTFontAttributeName: font,
                         kCTForegroundColorAttributeName: white] as CFDictionary
            guard let str = CFAttributedStringCreate(nil, String(ch) as CFString, attrs)
            else { continue }
            let line = CTLineCreateWithAttributedString(str)
            let bounds = CTLineGetBoundsWithOptions(line, [])
            cg.textPosition = CGPoint(
                x: CGFloat(i * glyphW) + (CGFloat(glyphW) - bounds.width) / 2,
                y: (CGFloat(glyphH) - bounds.height) / 2 - bounds.origin.y)
            CTLineDraw(line, cg)
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: glyphH, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc),
              let data = cg.data else { return nil }
        tex.label = "finisher.glyphAtlas"
        tex.replace(region: MTLRegionMake2D(0, 0, width, glyphH), mipmapLevel: 0,
                    withBytes: data, bytesPerRow: width * 4)
        return tex
    }

    /// Returns `input` untouched when every finisher mode is off (zero GPU
    /// cost). `flow` is the freshest Vision optical-flow field, used only by
    /// the decorative tracking HUD.
    func encode(commandBuffer: MTLCommandBuffer, input: MTLTexture, dt: Float = 0,
                flow: MTLTexture? = nil) -> MTLTexture {
        let mirror = Int(params.get(.mirrorMode))
        let color = Int(params.get(.colorMode))
        let gridWarp = params.bool(.gridWarpEnabled)
        let sheet = params.bool(.spreadsheetEnabled)
        let hud = params.bool(.trackingHUDEnabled) && flow != nil && glyphAtlas != nil
        guard mirror != 0 || color != 0 || gridWarp || sheet || hud else { return input }
        if out == nil || out!.width != input.width || out!.height != input.height
            || out!.pixelFormat != input.pixelFormat {
            out = ctx.makeTexture(width: input.width, height: input.height,
                                  format: input.pixelFormat, label: "finisher.out")
        }
        guard let out, let enc = commandBuffer.makeComputeCommandEncoder() else { return input }
        enc.label = "finisherPass"
        if gridWarp {
            gridWarpPhase += params.get(.gridWarpAnimSpeed) * dt
        }
        if sheet {
            sheetSelPhase += params.get(.spreadsheetSelectionSpeed) * dt
        }
        // Columns are the density param; rows follow the frame aspect so the
        // cells stay square-ish (same single-knob precedent as gridWarpCellSize).
        let cols = max(1, params.get(.spreadsheetCellSize).rounded())
        let rows = max(1, (cols * Float(input.height) / Float(input.width)).rounded())
        var u = FinisherUniformsSwift(
            mirrorMode: Int32(mirror),
            mirrorRightToLeft: params.bool(.mirrorRightToLeft) ? 1 : 0,
            colorMode: Int32(color),
            shadowHue: params.get(.duotoneShadowHue),
            highlightHue: params.get(.duotoneHighlightHue),
            hueShift: params.get(.colorHueShift),
            gridWarpEnabled: gridWarp ? 1 : 0,
            gridWarpCellSize: params.get(.gridWarpCellSize),
            gridWarpIntensity: params.get(.gridWarpIntensity),
            gridWarpLineOpacity: params.get(.gridWarpLineOpacity),
            gridWarpPhase: gridWarpPhase,
            sheetEnabled: sheet && glyphAtlas != nil ? 1 : 0,
            sheetCols: cols,
            sheetRows: rows,
            sheetChromeOpacity: params.get(.spreadsheetChromeOpacity),
            sheetLineOpacity: params.get(.spreadsheetGridLineOpacity),
            sheetSelPhase: sheetSelPhase,
            sheetRevealMode: Int32(params.get(.spreadsheetCellRevealMode)),
            hudEnabled: hud ? 1 : 0,
            hudPointCount: params.get(.trackingHUDPointDensity).rounded(),
            hudLabelDensity: params.get(.trackingHUDLabelDensity),
            hudLineOpacity: params.get(.trackingHUDLineOpacity),
            hudHue: params.get(.trackingHUDColor))
        enc.setTexture(input, index: 0)
        enc.setTexture(out, index: 1)
        enc.setTexture(glyphAtlas ?? input, index: 2)  // dummy bind when unused
        enc.setTexture(flow ?? input, index: 3)        // dummy bind when unused
        enc.setBytes(&u, length: MemoryLayout<FinisherUniformsSwift>.stride, index: 0)
        ctx.dispatch(enc, "finisherPass", width: out.width, height: out.height)
        enc.endEncoding()
        return out
    }
}
