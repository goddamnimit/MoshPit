import XCTest
import AVFoundation
@testable import MoshPit

/// Generates real clips with AVAssetWriter and runs them through the same
/// extraction path PlayerSource uses (tone-mapped item + BGRA video output),
/// asserting valid BGRA frames arrive at the right dimensions.
final class VideoIngestTests: XCTestCase {

    /// PlayerSource's extraction path, condensed: SDR-tone-mapped item,
    /// BGRA output attached before play, host-time-driven frame pulls.
    private func firstFrame(from url: URL,
                            timeout: TimeInterval = 8) async throws
        -> (width: Int, height: Int, format: OSType) {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = await PlayerSource.sdrToneMapComposition(for: asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)                      // attached BEFORE play
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        defer { player.pause() }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if item.status == .failed {
                throw item.error ?? TestClipGenerator.Failure.encodeFailed
            }
            let t = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: t),
               let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
                return (CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb),
                        CVPixelBufferGetPixelFormatType(pb))
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("no frame within \(timeout)s")
        throw TestClipGenerator.Failure.encodeFailed
    }

    func testSDRH264ClipYieldsBGRAFrames() async throws {
        let url = try TestClipGenerator.generate(hdr: false, duration: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let frame = try await firstFrame(from: url)
        XCTAssertEqual(frame.width, 640)
        XCTAssertEqual(frame.height, 360)
        XCTAssertEqual(frame.format, kCVPixelFormatType_32BGRA)
    }

    func testHDR10BitHEVCClipTonemapsToBGRA() async throws {
        // 10-bit HEVC Main10 tagged HLG/BT.2020 — the iPhone-recording shape.
        let url: URL
        do {
            url = try TestClipGenerator.generate(hdr: true, duration: 1)
        } catch {
            throw XCTSkip("This environment can't encode HEVC Main10: \(error)")
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let frame = try await firstFrame(from: url)
        XCTAssertEqual(frame.width, 640)
        XCTAssertEqual(frame.height, 360)
        XCTAssertEqual(frame.format, kCVPixelFormatType_32BGRA,
                       "HDR source must arrive tone-mapped as BGRA")
    }
}
