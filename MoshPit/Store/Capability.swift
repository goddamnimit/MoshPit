import Foundation

// MARK: - Capability (freemium gating)

/// Everything the Pro unlock covers. Free tier = Clean/Smear/Bloom, slot A,
/// recording + snapshots (watermarked), ReplayKit broadcast.
enum Capability: CaseIterable {
    case modeTBloom, modeDrift, modeMix, modeCross, modeFeedback
    case sourceSlotB, sourceSlotMOD
    case ndiOutput, mjpegOutput
    case lfo, modMatrix, automation
    case geometry3D          // Trace + Mass
    case mirrorModes, colorModes
    case reversePlayback
    case watermarkFree       // isPro removes watermark
    case proResExport        // ProRes 4444 recording format
    case export4K            // 4K recording resolution
    case socialExport        // 9:16 social-optimized re-encode
}

extension ProManager {
    /// The one gating function. Every capability is Pro-gated; the free tier
    /// is defined by what never asks (nil requiredCapability), not by a list.
    func allows(_ capability: Capability) -> Bool {
        isPro
    }
}

// MARK: - Capability mapping

extension MoshMode {
    /// nil = free (Clean / Classic Smear / Bloom).
    var requiredCapability: Capability? {
        switch self {
        case .clean, .classicSmear, .bloom: return nil
        case .timedBloom: return .modeTBloom
        case .drift: return .modeDrift
        case .mixMosh: return .modeMix
        case .crossMosh: return .modeCross
        case .feedback: return .modeFeedback
        }
    }
}

extension SourceSlot {
    var requiredCapability: Capability? {
        switch self {
        case .a: return nil
        case .b: return .sourceSlotB
        case .mod: return .sourceSlotMOD
        }
    }
}

extension ParameterID {
    /// Params whose writes are Pro-gated at the ParameterStore choke point.
    /// This makes MIDI / keyboard / mod-matrix / automation gating automatic:
    /// a control targeting a Pro param silently no-ops in the free tier.
    /// (`.mode` is value-dependent and handled by the write gate directly;
    /// `.bpm` and `.flickerLimit` stay free — tap tempo and the strobe safety
    /// cap are not upsells.)
    var requiredCapability: Capability? {
        switch self {
        case .lfo1Wave, .lfo1Rate, .lfo1Sync, .lfo1Div, .lfo1Phase, .lfo1Depth,
             .lfo2Wave, .lfo2Rate, .lfo2Sync, .lfo2Div, .lfo2Phase, .lfo2Depth,
             .struktFlip, .struktInvert, .struktFlash, .struktFlashWhite:
            return .lfo
        case .trace3D, .traceMode, .traceGrid, .tracePointSize, .traceDepth,
             .traceAutoRotate, .traceAdditive, .traceTrails, .tracePrimitive,
             .traceSpinX, .traceSpinY, .traceSpinZ,
             .orbitAzimuth, .orbitElevation, .orbitDistance:
            return .geometry3D
        case .mirrorMode, .mirrorRightToLeft:
            return .mirrorModes
        case .colorMode, .duotoneShadowHue, .duotoneHighlightHue, .colorHueShift:
            return .colorModes
        case .crossMosh:
            return .modeCross
        default:
            return nil
        }
    }
}
