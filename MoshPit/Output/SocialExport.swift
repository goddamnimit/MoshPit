import AVFoundation
import UIKit
import Combine

// MARK: - Social-optimized export (Pro): 1080x1920 H.264 30fps ~8Mbps

/// Render transform for fitting `sourceSize` into `target` (1080x1920).
/// Rule: within 5% of the target aspect -> scale-to-fill (minor crop);
/// otherwise aspect-fit letterbox with black bars. Scaled content dimensions
/// round to even numbers for encoder compatibility; the content is centered.
/// Pure and unit-tested.
func socialExportTransform(sourceSize: CGSize,
                           target: CGSize) -> (transform: CGAffineTransform,
                                               needsLetterbox: Bool) {
    guard sourceSize.width > 0, sourceSize.height > 0,
          target.width > 0, target.height > 0 else { return (.identity, false) }
    let sourceAspect = sourceSize.width / sourceSize.height
    let targetAspect = target.width / target.height
    let fill = abs(sourceAspect / targetAspect - 1) <= 0.05
    let scale = fill
        ? max(target.width / sourceSize.width, target.height / sourceSize.height)
        : min(target.width / sourceSize.width, target.height / sourceSize.height)
    func evenRound(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded() * 2) }
    let scaledW = evenRound(sourceSize.width * scale)
    let scaledH = evenRound(sourceSize.height * scale)
    // Per-axis scale from the even-rounded dims so the content rect is exact.
    let transform = CGAffineTransform(scaleX: scaledW / sourceSize.width,
                                      y: scaledH / sourceSize.height)
        .concatenating(CGAffineTransform(translationX: (target.width - scaledW) / 2,
                                         y: (target.height - scaledH) / 2))
    return (transform, !fill)
}

/// Re-encodes a session clip to 1080x1920 (9:16) H.264 30fps at ~8 Mbps with
/// AAC audio, for direct social posting.
///
/// Writer-based (AVAssetReader -> AVAssetWriter) rather than
/// AVAssetExportSession: export presets don't expose bitrate control, and the
/// ~8 Mbps video target is part of the spec — only AVVideoAverageBitRateKey
/// on a writer input delivers it. The reader still uses the custom
/// AVMutableVideoComposition (transform + 30fps frameDuration), so the
/// letterbox/fill math is identical to the export-session path.
final class SocialExporter: NSObject, ObservableObject {
    static let targetSize = CGSize(width: 1080, height: 1920)

    @Published private(set) var isExporting = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastError: String?

    private let queue = DispatchQueue(label: "moshpit.socialexport", qos: .userInitiated)
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var cancelled = false
    private var outputURL: URL?

    /// Kick off the export. `completion` fires on main with the exported file
    /// URL (in the temp dir, reclaimed by the session sweep — deliberately
    /// NOT added to sessionClips), or nil on failure/cancel.
    func export(clipURL: URL, completion: @escaping (URL?) -> Void) {
        guard !isExporting else { return }
        isExporting = true
        progress = 0
        lastError = nil
        cancelled = false
        let outURL = SessionClipStore.socialExportURL()
        outputURL = outURL
        queue.async { [weak self] in
            self?.run(clipURL: clipURL, outURL: outURL) { url in
                DispatchQueue.main.async {
                    self?.isExporting = false
                    completion(url)
                }
            }
        }
    }

    /// Cancel: tears the reader/writer down and deletes the partial file.
    func cancel() {
        queue.async { [weak self] in
            guard let self, self.isExporting || self.reader != nil else { return }
            self.cancelled = true
            self.reader?.cancelReading()
            self.writer?.cancelWriting()
            if let url = self.outputURL {
                try? FileManager.default.removeItem(at: url)
            }
            DispatchQueue.main.async { self.isExporting = false }
        }
    }

    // MARK: pipeline (runs on `queue`)

    private func fail(_ message: String, _ done: @escaping (URL?) -> Void) {
        if let url = outputURL { try? FileManager.default.removeItem(at: url) }
        DispatchQueue.main.async { self.lastError = message }
        done(nil)
    }

    private func run(clipURL: URL, outURL: URL, done: @escaping (URL?) -> Void) {
        let asset = AVURLAsset(url: clipURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            fail("No video track", done); return
        }
        let duration = asset.duration
        let target = Self.targetSize

        // Oriented source size (session clips are unrotated, but be robust).
        let natural = videoTrack.naturalSize
        let oriented = natural.applying(videoTrack.preferredTransform)
        let sourceSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        let fit = socialExportTransform(sourceSize: sourceSize, target: target)

        // 30fps composition carrying the fill/letterbox transform.
        let composition = AVMutableVideoComposition()
        composition.renderSize = target
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layer.setTransform(videoTrack.preferredTransform.concatenating(fit.transform),
                           at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        do {
            let reader = try AVAssetReader(asset: asset)
            let writer = try AVAssetWriter(url: outURL, fileType: .mp4)
            self.reader = reader
            self.writer = writer

            let videoOut = AVAssetReaderVideoCompositionOutput(
                videoTracks: [videoTrack],
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                    kCVPixelFormatType_32BGRA])
            videoOut.videoComposition = composition
            videoOut.alwaysCopiesSampleData = false
            guard reader.canAdd(videoOut) else { fail("Reader setup failed", done); return }
            reader.add(videoOut)

            let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(target.width),
                AVVideoHeightKey: Int(target.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 8_000_000,
                ],
            ])
            videoIn.expectsMediaDataInRealTime = false
            guard writer.canAdd(videoIn) else { fail("Writer setup failed", done); return }
            writer.add(videoIn)

            // Audio: decode to PCM, re-encode AAC (channel count preserved).
            var audioOut: AVAssetReaderTrackOutput?
            var audioIn: AVAssetWriterInput?
            if let audioTrack = asset.tracks(withMediaType: .audio).first {
                let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                ])
                var channels = 2
                if let desc = audioTrack.formatDescriptions.first,
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(
                    desc as! CMAudioFormatDescription) {
                    channels = max(1, Int(asbd.pointee.mChannelsPerFrame))
                }
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: 128_000,
                ])
                input.expectsMediaDataInRealTime = false
                if reader.canAdd(out), writer.canAdd(input) {
                    reader.add(out)
                    writer.add(input)
                    audioOut = out
                    audioIn = input
                }
            }

            guard reader.startReading() else {
                fail(reader.error?.localizedDescription ?? "Couldn't read clip", done)
                return
            }
            guard writer.startWriting() else {
                fail(writer.error?.localizedDescription ?? "Couldn't start export", done)
                return
            }
            writer.startSession(atSourceTime: .zero)

            let totalSeconds = max(0.001, CMTimeGetSeconds(duration))
            let group = DispatchGroup()

            // Pump pattern: each input's block runs until EOF (nil sample) or
            // cancel, then marks finished and leaves the group EXACTLY once —
            // requestMediaDataWhenReady may re-invoke the block afterwards,
            // so a `finished` flag guards re-entry.
            func pump(input: AVAssetWriterInput, label: String,
                      next: @escaping () -> CMSampleBuffer?,
                      onSample: ((CMSampleBuffer) -> Void)? = nil) {
                group.enter()
                var finished = false
                let q = DispatchQueue(label: "moshpit.socialexport.\(label)")
                input.requestMediaDataWhenReady(on: q) { [weak self] in
                    guard let self, !finished else { return }
                    func finish() {
                        finished = true
                        input.markAsFinished()
                        group.leave()
                    }
                    while input.isReadyForMoreMediaData {
                        if self.cancelled { finish(); return }
                        guard let sample = next() else { finish(); return }   // EOF
                        input.append(sample)
                        onSample?(sample)
                    }
                    // Not ready: return and wait for the next ready callback.
                }
            }

            pump(input: videoIn, label: "video",
                 next: { videoOut.copyNextSampleBuffer() }) { [weak self] sample in
                let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                let p = min(1, max(0, t / totalSeconds))
                DispatchQueue.main.async { self?.progress = p }
            }
            if let audioOut, let audioIn {
                pump(input: audioIn, label: "audio",
                     next: { audioOut.copyNextSampleBuffer() })
            }

            group.notify(queue: queue) { [weak self] in
                guard let self else { return }
                defer { self.reader = nil; self.writer = nil }
                if self.cancelled || reader.status == .cancelled {
                    try? FileManager.default.removeItem(at: outURL)
                    done(nil)
                    return
                }
                guard reader.status != .failed, writer.status != .failed else {
                    self.fail((reader.error ?? writer.error)?.localizedDescription
                              ?? "Export failed", done)
                    return
                }
                writer.finishWriting {
                    if writer.status == .completed {
                        DispatchQueue.main.async { self.progress = 1 }
                        done(outURL)
                    } else {
                        try? FileManager.default.removeItem(at: outURL)
                        self.fail(writer.error?.localizedDescription ?? "Export failed", done)
                    }
                }
            }
        } catch {
            fail(error.localizedDescription, done)
        }
    }
}
