import UIKit

// MARK: - Share sheet (UIActivityViewController) presentation

/// The single presentation path for every share entry point: the
/// post-recording/snapshot toast, the gallery per-clip Share, and the social
/// export completion. A UIKit bridge from the key window's topmost view
/// controller (rather than UIViewControllerRepresentable) because callers are
/// buttons inside overlays and sheets that may themselves be mid-dismissal —
/// walking to the topmost presented VC always finds a valid presenter.
enum ShareSheetPresenter {
    /// Presents UIActivityViewController with the FILE URL (not a PHAsset
    /// reference), so the artifact attaches directly in TikTok / Reels /
    /// iMessage / AirDrop.
    static func present(fileURL: URL, from sourceView: UIView? = nil) {
        DispatchQueue.main.async {
            guard let window = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .flatMap(\.windows)
                    .first(where: \.isKeyWindow),
                  var top = window.rootViewController else { return }
            while let presented = top.presentedViewController,
                  !presented.isBeingDismissed {
                top = presented
            }
            let activity = UIActivityViewController(activityItems: [fileURL],
                                                    applicationActivities: nil)
            // Sharing itself is free for everyone (AirDrop, Messages, Reels,
            // Files, …). But UIActivityViewController's built-in "Save Video"
            // action IS a Photos write — leaving it in would bypass the one
            // Pro gate (Capability.saveVideoToPhotos), so it is excluded for
            // video files while un-entitled. Snapshots (images) are never
            // affected: photo saving is not gated.
            activity.excludedActivityTypes = MainActor.assumeIsolated {
                excludedActivityTypes(for: fileURL, isPro: ProManager.shared.isPro)
            }
            // iPad idiom: anchor the popover defensively even though iPhone
            // portrait is the primary target.
            if let pop = activity.popoverPresentationController {
                let anchor = sourceView ?? top.view!
                pop.sourceView = anchor
                pop.sourceRect = CGRect(x: anchor.bounds.midX, y: anchor.bounds.midY,
                                        width: 1, height: 1)
                pop.permittedArrowDirections = []
            }
            top.present(activity, animated: true)
        }
    }

    /// Pure policy helper (unit-tested): only video files, and only while
    /// un-entitled, lose the sheet's built-in Save Video action.
    static func excludedActivityTypes(for url: URL,
                                      isPro: Bool) -> [UIActivity.ActivityType]? {
        let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
        guard !isPro, videoExtensions.contains(url.pathExtension.lowercased())
        else { return nil }
        return [.saveToCameraRoll]
    }
}
