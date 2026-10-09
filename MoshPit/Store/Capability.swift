import Foundation

// MARK: - Capability (Pro gating)

/// The complete Pro gating surface, all mapped to the ONE entitlement.
/// Free tier: every mode, effect, source, output (NDI/MJPEG stay clean),
/// recording and snapshots (watermarked), and the session gallery (view,
/// play, remosh, delete). Unlock: no watermark on new recordings/snapshots,
/// plus exporting (Photos, share sheet, Social Export). Must never grow a
/// case here without a deliberate product decision.
enum Capability: CaseIterable {
    /// Writing a completed video recording to the user's Photos library.
    case saveVideoToPhotos
    /// Recordings / snapshots made while entitled carry no watermark.
    case removeWatermark
    /// Share sheet (incl. Save to Files), Social Export, saving to Photos.
    case exportOutput
}

extension ProManager {
    /// The one gating function.
    func allows(_ capability: Capability) -> Bool { isPro }
}
