import os

/// Lightweight signpost instrumentation for UI-responsiveness measurement.
/// View in Instruments: os_signpost instrument, subsystem "com.moshpit.perf".
/// Events are cheap (no-ops unless a recorder is attached) and ship in Release.
enum Perf {
    static let signposter = OSSignposter(subsystem: "com.moshpit.perf",
                                         category: "UIResponsiveness")

    /// Point event (drawer/sheet opens, param writes, stats publishes).
    @inline(__always)
    static func event(_ name: StaticString, _ message: String = "") {
        signposter.emitEvent(name, "\(message)")
    }

    /// Interval begin/end (slider drags). Store the returned state and pass
    /// it to `end`.
    @inline(__always)
    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    @inline(__always)
    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}
