import os
import SwiftUI

/// Lightweight signpost instrumentation for UI-responsiveness measurement.
///
/// View in Instruments: add the **os_signpost** instrument and filter by
/// subsystem `com.moshpit.perf`. Each category below shows up as its own
/// lane, so a trace is readable without cross-referencing this file:
///
/// | Category         | What it covers                                        |
/// |------------------|-------------------------------------------------------|
/// | `UI.Drawer`      | openDrawer() end-to-end, drawer view-tree builds       |
/// | `UI.Sheet`       | openSheet() end-to-end, panel sheet view-tree builds   |
/// | `Params.Publish` | ParameterStore setter vs. subscriber notification      |
/// | `Slider.Drag`    | whole drag gesture + per-tick handling                 |
/// | `Haptics`        | generator cold start/prepare vs. impact trigger        |
/// | `Coach`          | tutorial transition delays + CoachOverlay body builds  |
///
/// Signposts are cheap (a few hundred ns, and effectively free when no
/// recorder is attached), so these ship in Release. Deliberately absent from
/// the per-frame Metal encode path — that belongs to GPU-side tooling.
///
/// This is an OBSERVATION layer only: nothing here changes behaviour,
/// publish granularity, gesture handling, or haptic timing.
enum Perf {
    static let subsystem = "com.moshpit.perf"

    static let drawer = OSSignposter(subsystem: subsystem, category: "UI.Drawer")
    static let sheet = OSSignposter(subsystem: subsystem, category: "UI.Sheet")
    static let params = OSSignposter(subsystem: subsystem, category: "Params.Publish")
    static let slider = OSSignposter(subsystem: subsystem, category: "Slider.Drag")
    static let haptics = OSSignposter(subsystem: subsystem, category: "Haptics")
    static let coach = OSSignposter(subsystem: subsystem, category: "Coach")
    /// Retained for the render-loop stats publish — the one non-UI signal
    /// worth seeing next to the UI lanes, since it invalidates the tree.
    static let signposter = OSSignposter(subsystem: subsystem, category: "UIResponsiveness")

    /// Point event on the general lane (stats publishes).
    @inline(__always)
    static func event(_ name: StaticString, _ message: String = "") {
        signposter.emitEvent(name, "\(message)")
    }
}

extension OSSignposter {
    /// Interval around a synchronous block, returning its value.
    /// `withIntervalSignpost` already does this; this overload just keeps the
    /// message argument optional at call sites.
    @inline(__always)
    func measure<T>(_ name: StaticString, _ message: String = "",
                    _ work: () throws -> T) rethrows -> T {
        let state = beginInterval(name, id: makeSignpostID(), "\(message)")
        defer { endInterval(name, state) }
        return try work()
    }
}

/// Wraps a SwiftUI `body` in a signpost interval so view-tree *construction*
/// is visible in a trace.
///
/// Caveat worth remembering when reading the trace: this measures how long
/// SwiftUI spends building the view value, NOT layout or render. A cheap
/// build with an expensive layout still shows a short interval here — but the
/// *count* of intervals is the useful signal, because it tells you how often
/// an unrelated `@Published` write invalidated this view.
@inline(__always)
func perfBody<V: View>(_ signposter: OSSignposter, _ name: StaticString,
                       _ message: String = "",
                       @ViewBuilder _ make: () -> V) -> V {
    signposter.measure(name, message, make)
}
