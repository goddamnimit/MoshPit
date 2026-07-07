import Metal
import UIKit
import CoreText

/// The single watermark choke point for exported artifacts (recordings and
/// snapshots). Encodes the same blit both paths already performed — with the
/// watermark blended in when requested — so watermarking is one code path and
/// zero extra passes. The canvas (RGBA16Float) is never touched; this runs on
/// the output-format (BGRA) texture only.
final class WatermarkCompositor {
    private let ctx: MetalContext
    /// Pre-rendered once (lazily, first watermarked artifact): "MoshPit" in
    /// the Theme label face, white at ~55% opacity with a subtle shadow.
    /// Never rasterized per frame.
    private var markTexture: MTLTexture?

    /// Aspect (h/w) of the rendered mark, captured at texture creation.
    private var markAspect: Float = 0.25

    init(ctx: MetalContext) {
        self.ctx = ctx
    }

    /// Encode src -> dst (scale/format blit, identical semantics to
    /// `blitScale`). When `watermark` is true the mark is composited into the
    /// bottom-right corner: inset = 2% of output width clamped to >= 24 px,
    /// mark width ~= 12% of the long edge.
    func encodeBlit(from src: MTLTexture, to dst: MTLTexture,
                    watermark: Bool, commandBuffer cb: MTLCommandBuffer) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        defer { enc.endEncoding() }
        enc.setTexture(src, index: 0)
        enc.setTexture(dst, index: 1)
        guard watermark, let mark = markTextureIfNeeded() else {
            enc.label = "output.blit"
            ctx.dispatch(enc, "blitScale", width: dst.width, height: dst.height)
            return
        }
        enc.label = "output.blit+watermark"
        let longEdge = Float(max(dst.width, dst.height))
        let w = longEdge * 0.12
        let h = w * markAspect
        let inset = max(24, Float(dst.width) * 0.02)
        var u = SIMD4<Float>(Float(dst.width) - inset - w,
                             Float(dst.height) - inset - h,
                             w, h)   // origin.xy, size.xy — matches WatermarkUniforms
        enc.setTexture(mark, index: 2)
        enc.setBytes(&u, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        ctx.dispatch(enc, "watermarkBlit", width: dst.width, height: dst.height)
    }

    // MARK: mark rendering (CoreText/CoreGraphics -> BGRA MTLTexture, once)

    private func markTextureIfNeeded() -> MTLTexture? {
        if let markTexture { return markTexture }
        let text = "MoshPit" as CFString
        // Render at a generous fixed size; the kernel samples it linearly.
        let fontSize: CGFloat = 96
        let font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white.withAlphaComponent(0.55),
        ]
        let attributed = NSAttributedString(string: text as String, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let pad: CGFloat = 12   // room for the shadow blur
        let w = Int(ceil(bounds.width) + pad * 2)
        let h = Int(ceil(bounds.height) + pad * 2)
        guard w > 0, h > 0,
              let cg = CGContext(data: nil, width: w, height: h,
                                 bitsPerComponent: 8, bytesPerRow: w * 4,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                     | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // BGRA premultiplied. CGBitmapContext memory already has row 0 at the
        // top, matching MTLTexture.replace — no flip needed; CoreText just
        // draws y-up in user space.
        cg.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 4,
                     color: UIColor.black.withAlphaComponent(0.6).cgColor)
        cg.textPosition = CGPoint(x: pad - bounds.origin.x, y: pad - bounds.origin.y)
        CTLineDraw(line, cg)
        guard let data = cg.data else { return nil }

        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let tex = ctx.device.makeTexture(descriptor: d) else { return nil }
        tex.label = "watermark.mark"
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: data, bytesPerRow: w * 4)
        markAspect = Float(h) / Float(w)
        markTexture = tex
        return tex
    }
}
