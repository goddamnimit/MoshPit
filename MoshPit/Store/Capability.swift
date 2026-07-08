import Foundation

// MARK: - Capability (Pro gating)

/// The complete Pro gating surface. Everything else in the app — all modes,
/// slots, outputs, effects, LFO/mod matrix/automation, 3D, mirror/color,
/// reverse, ProRes/4K, social export, the session gallery, share sheet,
/// remosh, and snapshot saving — is permanently free and must never grow a
/// case here without a deliberate product decision.
enum Capability: CaseIterable {
    /// Writing a completed video recording to the user's Photos library.
    case saveVideoToPhotos
}

extension ProManager {
    /// The one gating function.
    func allows(_ capability: Capability) -> Bool { isPro }
}
