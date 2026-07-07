import Foundation
import AVFoundation
import Combine

// MARK: - Recording settings (Export section of the Output sheet)

/// Format + resolution for the NEXT recording.
///
/// Deliberately NOT registered in ParameterStore: these are not real-time
/// performance parameters — nothing should MIDI-map, LFO-modulate, or
/// automate them, and they only take effect once, at AVAssetWriter setup.
/// A small persisted settings object living adjacent to ParameterStore keeps
/// the store's invariant (every ID is a live, modulatable Float) intact.
final class RecordingSettings: ObservableObject {
    enum Format: String, CaseIterable, Identifiable {
        case h264 = "H.264"
        case hevc = "HEVC"
        case proRes4444 = "ProRes 4444"
        var id: String { rawValue }
        var codecType: AVVideoCodecType {
            switch self {
            case .h264: return .h264
            case .hevc: return .hevc
            case .proRes4444: return .proRes4444
            }
        }
    }

    enum Resolution: String, CaseIterable, Identifiable {
        case matchCanvas = "Match Canvas"
        case p720 = "720p"
        case p1080 = "1080p"
        case p4K = "4K"
        var id: String { rawValue }
        /// Long-edge pixels; nil = match the canvas resolution.
        var longEdge: Int? {
            switch self {
            case .matchCanvas: return nil
            case .p720: return 720
            case .p1080: return 1080
            case .p4K: return 3840
            }
        }
    }

    @Published var format: Format { didSet { persist() } }
    @Published var resolution: Resolution { didSet { persist() } }

    private let defaults: UserDefaults
    private static let formatKey = "moshpit.recording.format"
    private static let resolutionKey = "moshpit.recording.resolution"

    /// `defaults` is injectable for tests (a named suite, cleaned in tearDown).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        format = defaults.string(forKey: Self.formatKey)
            .flatMap(Format.init(rawValue:)) ?? .h264
        resolution = defaults.string(forKey: Self.resolutionKey)
            .flatMap(Resolution.init(rawValue:)) ?? .p1080
    }

    private func persist() {
        defaults.set(format.rawValue, forKey: Self.formatKey)
        defaults.set(resolution.rawValue, forKey: Self.resolutionKey)
    }

    /// Pro -> free degradation, gated through the same `Capability` mapping
    /// every other Pro feature uses (see Capability.swift's `RecordingSettings.
    /// Format`/`.Resolution` extensions) — never a standalone flag.
    ///
    /// This is also the SECOND gate, called again at every record start
    /// (AppModel.toggleRecord): a persisted UserDefaults value is not a
    /// trusted entitlement check on its own — a stale ProRes/4K selection
    /// left over from before a purchase, a refund, or a debug build must be
    /// re-validated against the live entitlement before it ever reaches
    /// AVAssetWriter, not just at the moment the user picked it in the UI.
    func enforceFreeTier(isPro: Bool) {
        if format.requiredCapability != nil, !isPro { format = .h264 }
        if resolution.requiredCapability != nil, !isPro { resolution = .p1080 }
    }

    /// Output dimensions per the app's long-edge resolution semantics: the
    /// resolution option sets the LONG edge, the short edge derives from the
    /// canvas aspect, and both round down to even numbers for encoder
    /// compatibility. `longEdge == nil` keeps the canvas size.
    static func outputSize(canvasWidth: Int, canvasHeight: Int,
                           longEdge: Int?) -> (width: Int, height: Int) {
        var w = canvasWidth, h = canvasHeight
        if let longEdge, max(w, h) > 0 {
            let long = max(w, h)
            w = w * longEdge / long
            h = h * longEdge / long
        }
        return (max(2, w & ~1), max(2, h & ~1))
    }
}

// MARK: - MJPEG URL sharing

/// Pure helpers behind the Output sheet's "Copy MJPEG URL" button.
///
/// Security note (docs/SECURITY_AUDIT.md, "MJPEG server access gap"): the
/// session token stays on-device — it is copied to the local clipboard only
/// at explicit user request, and must never be logged or printed.
enum MJPEGShare {
    /// Pure URL string builder — unit-testable, no pasteboard involved.
    static func streamURLString(ip: String, port: UInt16, token: String) -> String {
        "http://\(ip):\(port)/?token=\(token)"
    }

    /// Button enablement: needs a running server with a minted session token.
    static func canCopyURL(serverRunning: Bool, token: String) -> Bool {
        serverRunning && !token.isEmpty
    }

    /// Device IPv4 from local interface enumeration (getifaddrs), preferring
    /// en0 (Wi-Fi). No network calls, no new permissions.
    static func deviceIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var fallback: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  (Int32(ifa.ifa_flags) & IFF_LOOPBACK) == 0,
                  (Int32(ifa.ifa_flags) & IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            let name = String(cString: ifa.ifa_name)
            if name == "en0" { return address }
            if fallback == nil { fallback = address }
        }
        return fallback
    }
}
