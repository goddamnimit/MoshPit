import UIKit
import AVFoundation

// MARK: - Session clip gallery model

/// One recording made this session. Session-only: the file lives in the temp
/// directory, nothing persists, and no Photos-library browsing (no new
/// permissions) is involved.
struct SessionClip: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let thumbnail: UIImage
    let duration: TimeInterval
    let fileSize: Int64
    let timestamp: Date

    static func == (lhs: SessionClip, rhs: SessionClip) -> Bool { lhs.id == rhs.id }
}

/// Temp-file lifecycle for session artifacts.
///
/// SECURITY_AUDIT.md ("Lingering temporary videos") originally mandated
/// deleting the recording temp file on every stop() exit path. That lifecycle
/// is deliberately superseded by the session gallery: files are RETAINED for
/// the session (share / remosh / re-export) and reclaimed by (a) gallery
/// Delete, (b) the launch sweep below, and (c) app-termination cleanup — so
/// no artifact outlives the session unmanaged.
enum SessionClipStore {
    /// Filename prefixes owned by MoshPit in the temp directory.
    static let recordingPrefix = "mosh-"
    static let snapshotPrefix = "moshsnap-"
    static let socialExportPrefix = "moshsocial-"

    static func recordingURL(in dir: URL = FileManager.default.temporaryDirectory) -> URL {
        dir.appendingPathComponent(
            "\(recordingPrefix)\(Int(Date().timeIntervalSince1970)).mov")
    }

    static func snapshotURL(in dir: URL = FileManager.default.temporaryDirectory) -> URL {
        dir.appendingPathComponent(
            "\(snapshotPrefix)\(Int(Date().timeIntervalSince1970 * 1000)).png")
    }

    static func socialExportURL(in dir: URL = FileManager.default.temporaryDirectory) -> URL {
        dir.appendingPathComponent(
            "\(socialExportPrefix)\(Int(Date().timeIntervalSince1970 * 1000)).mp4")
    }

    /// Sweep stale MoshPit artifacts (recordings, snapshot PNGs, social
    /// exports) left over from previous sessions. Returns the removed count.
    @discardableResult
    static func sweepStaleRecordings(
        in dir: URL = FileManager.default.temporaryDirectory) -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return 0 }
        var removed = 0
        for url in items {
            let name = url.lastPathComponent
            guard name.hasPrefix(recordingPrefix)
                    || name.hasPrefix(snapshotPrefix)
                    || name.hasPrefix(socialExportPrefix) else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// Builds a SessionClip from a finished recording: first-frame thumbnail
    /// (AVAssetImageGenerator), duration, and file size. Blocking work — call
    /// off the main thread.
    static func makeClip(url: URL, timestamp: Date = Date()) -> SessionClip? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil)
        else { return nil }
        let seconds = CMTimeGetSeconds(asset.duration)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int64) ?? 0
        return SessionClip(id: UUID(), url: url,
                           thumbnail: UIImage(cgImage: cg),
                           duration: seconds.isFinite ? seconds : 0,
                           fileSize: size,
                           timestamp: timestamp)
    }

    /// "m:ss" duration text for gallery rows.
    static func durationText(_ duration: TimeInterval) -> String {
        let s = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Human-readable size via ByteCountFormatter.
    static func fileSizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
