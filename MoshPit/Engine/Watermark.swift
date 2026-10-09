import Metal
import CoreGraphics
import CoreText

/// Mirror of WatermarkUniforms in Watermark.metal.
struct WatermarkUniformsSwift {
    var rect: SIMD4<Float>
    var shadowOffset: Float
    var shadowSoft: Float
    var opacity: Float
    var pad: Float = 0
}

/// Free-tier watermark: a "MoshPit" wordmark (system font rasterized once into
/// an alpha mask — no external assets) composited bottom-right by
/// `blitScaleWatermark`. Resolution independent: size and margin derive from
/// the output's short edge.
final class WatermarkOverlay {
    static let maskWidth = 1024, maskHeight = 192
    static let heightFraction: CGFloat = 0.045   // mark height / short edge
    static let marginFraction: CGFloat = 0.03    // margin / short edge
    static let opacity: Float = 0.6

    let mask: MTLTexture

    init?(device: MTLDevice) {
        let w = Self.maskWidth, h = Self.maskHeight
        guard let cg = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 120, nil)
        let attrs = [kCTFontAttributeName: font,
                     kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1)] as CFDictionary
        guard let str = CFAttributedStringCreate(nil, "MoshPit" as CFString, attrs) else { return nil }
        let line = CTLineCreateWithAttributedString(str)
        let b = CTLineGetBoundsWithOptions(line, [])
        // Fit the text into the mask with a small pad, right-aligned.
        let scale = min(CGFloat(w - 24) / b.width, CGFloat(h - 24) / b.height)
        cg.translateBy(x: CGFloat(w) - 12 - b.width * scale, y: (CGFloat(h) - b.height * scale) / 2)
        cg.scaleBy(x: scale, y: scale)
        cg.textPosition = CGPoint(x: -b.origin.x, y: -b.origin.y)
        CTLineDraw(line, cg)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc), let data = cg.data else { return nil }
        tex.label = "watermark.mask"
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: data, bytesPerRow: w * 4)
        mask = tex
    }

    /// Mark rectangle in output pixels (top-left origin). Pure; unit-tested.
    static func rect(width: Int, height: Int) -> CGRect {
        let short = CGFloat(min(width, height))
        let markH = (short * heightFraction).rounded()
        let markW = markH * CGFloat(maskWidth) / CGFloat(maskHeight)
        let margin = (short * marginFraction).rounded()
        return CGRect(x: CGFloat(width) - margin - markW,
                      y: CGFloat(height) - margin - markH,
                      width: markW, height: markH)
    }

    func uniforms(width: Int, height: Int) -> WatermarkUniformsSwift {
        let r = Self.rect(width: width, height: height)
        let markH = Float(r.height)
        return WatermarkUniformsSwift(
            rect: SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)),
            shadowOffset: max(1, markH * 0.04), shadowSoft: max(1, markH * 0.05),
            opacity: Self.opacity)
    }
}

extension MetalContext {
    /// The ONE texture -> BGRA output blit for the recorder and snapshot.
    /// `watermarked == false` is the plain, zero-extra-cost blitScale.
    func encodeOutputBlit(_ enc: MTLComputeCommandEncoder, input: MTLTexture,
                          output: MTLTexture, watermarked: Bool) {
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        guard watermarked, let overlay = watermark else {
            if watermarked { assertionFailure("watermark mask unavailable") }
            dispatch(enc, "blitScale", width: output.width, height: output.height)
            return
        }
        enc.setTexture(overlay.mask, index: 2)
        var u = overlay.uniforms(width: output.width, height: output.height)
        enc.setBytes(&u, length: MemoryLayout<WatermarkUniformsSwift>.stride, index: 0)
        dispatch(enc, "blitScaleWatermark", width: output.width, height: output.height)
    }
}
