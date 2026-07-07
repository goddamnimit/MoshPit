#if DEBUG
import AVFoundation
import VideoToolbox
import CoreVideo
import UIKit

/// Programmatic test clips (DEBUG only): used by unit tests and the
/// `-testvideo` screenshot hook. `hdr` writes 10-bit HEVC tagged
/// HLG/BT.2020 — the same shape as an iPhone camera recording — exercising
/// the tone-mapped ingest path.
enum TestClipGenerator {
    enum Failure: Error { case writerRejected, encodeFailed }

    @discardableResult
    static func generate(hdr: Bool, duration: Double = 2,
                         width: Int = 640, height: Int = 360) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("moshpit-test-\(hdr ? "hdr" : "sdr")-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(url: url, fileType: .mov)

        var settings: [String: Any] = [
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        if hdr {
            settings[AVVideoCodecKey] = AVVideoCodecType.hevc
            settings[AVVideoCompressionPropertiesKey] = [
                kVTCompressionPropertyKey_ProfileLevel as String:
                    kVTProfileLevel_HEVC_Main10_AutoLevel,
            ]
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        } else {
            settings[AVVideoCodecKey] = AVVideoCodecType.h264
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw Failure.writerRejected }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.startWriting() else { throw Failure.writerRejected }
        writer.startSession(atSourceTime: .zero)

        let fps = 30
        let frames = Int(duration * Double(fps))
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            guard let pool = adaptor.pixelBufferPool else { throw Failure.encodeFailed }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buffer = pb else { throw Failure.encodeFailed }
            fillFrame(buffer, frame: frame, width: width, height: height)
            let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            if !adaptor.append(buffer, withPresentationTime: time) {
                throw Failure.encodeFailed
            }
        }
        input.markAsFinished()
        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
        guard writer.status == .completed else { throw Failure.encodeFailed }
        return url
    }

    /// Animated content: scrolling diagonal color bands + a frame counter
    /// block, so motion is obvious and no frame is a solid color.
    private static func fillFrame(_ pb: CVPixelBuffer, frame: Int,
                                  width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width {
                let band = ((x + y + frame * 6) / 24) % 3
                let bgra: UInt32
                switch band {
                case 0: bgra = 0xFF2020E0    // red-ish (BGRA little endian)
                case 1: bgra = 0xFFE0A020    // teal-ish
                default: bgra = 0xFF20C020   // green
                }
                row[x] = bgra
            }
        }
        // Moving white block marks the frame index position.
        let bx = (frame * 8) % max(1, width - 40)
        for y in 20..<60 where y < height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
            for x in bx..<min(bx + 40, width) { row[x] = 0xFFFFFFFF }
        }
    }
}
#endif
