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
}
