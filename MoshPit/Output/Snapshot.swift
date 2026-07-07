import Metal
import Photos
import UIKit

/// Saves canvas snapshots to the photo library. The renderer hands over a
/// shared-storage BGRA texture (already blitted GPU-side, no render stall);
/// this converts it to a UIImage off-main and runs the Photos dance.
enum SnapshotSaver {
    /// Shared BGRA texture -> UIImage. CPU readback; call off the render loop.
    static func image(from texture: MTLTexture) -> UIImage? {
        let w = texture.width, h = texture.height
        let rowBytes = w * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * h)
        texture.getBytes(&bytes, bytesPerRow: rowBytes,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // BGRA8 little-endian == kCGBitmapByteOrder32Little + premultipliedFirst.
        let info = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8,
                               bitsPerPixel: 32, bytesPerRow: rowBytes,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: info),
                               provider: provider, decode: nil,
                               shouldInterpolate: false,
                               intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Requests add-only Photos access if needed and saves. `onDenied` fires
    /// on main when access is (or becomes) denied; `onSaved` on success.
    static func save(_ image: UIImage,
                     onDenied: @escaping () -> Void,
                     onSaved: @escaping () -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { onDenied() }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, _ in
                if success { DispatchQueue.main.async { onSaved() } }
            }
        }
    }
}
