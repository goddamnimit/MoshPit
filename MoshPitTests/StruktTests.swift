import XCTest
@testable import MoshPit

final class StruktTests: XCTestCase {
    func testWaveformValuesAtKnownPhases() {
        // Sine: 0.5 at phase 0, peaks at 0.25, trough at 0.75.
        XCTAssertEqual(lfoWaveValue(.sine, phase: 0), 0.5, accuracy: 1e-5)
        XCTAssertEqual(lfoWaveValue(.sine, phase: 0.25), 1.0, accuracy: 1e-5)
        XCTAssertEqual(lfoWaveValue(.sine, phase: 0.75), 0.0, accuracy: 1e-5)
        // Square: high first half, low second half.
        XCTAssertEqual(lfoWaveValue(.square, phase: 0.1), 1)
        XCTAssertEqual(lfoWaveValue(.square, phase: 0.6), 0)
        // Triangle: ramps to 1 at midpoint, back to 0.
        XCTAssertEqual(lfoWaveValue(.triangle, phase: 0.25), 0.5, accuracy: 1e-5)
        XCTAssertEqual(lfoWaveValue(.triangle, phase: 0.5), 1.0, accuracy: 1e-5)
        XCTAssertEqual(lfoWaveValue(.triangle, phase: 0.75), 0.5, accuracy: 1e-5)
        // Saw: identity ramp; wraps beyond 1.
        XCTAssertEqual(lfoWaveValue(.saw, phase: 0.3), 0.3, accuracy: 1e-5)
        XCTAssertEqual(lfoWaveValue(.saw, phase: 1.3), 0.3, accuracy: 1e-5)
    }

    func testTempoSyncedRates() {
        // Free-running ignores BPM.
        XCTAssertEqual(lfoEffectiveRate(hz: 5, synced: false, divisionIndex: 0, bpm: 120), 5)
        // 120 BPM = 2 beats/s: 1/1 = 2 Hz, 1/4 = 8 Hz, 1/16 = 32 Hz.
        XCTAssertEqual(lfoEffectiveRate(hz: 5, synced: true, divisionIndex: 0, bpm: 120), 2)
        XCTAssertEqual(lfoEffectiveRate(hz: 5, synced: true, divisionIndex: 2, bpm: 120), 8)
        XCTAssertEqual(lfoEffectiveRate(hz: 5, synced: true, divisionIndex: 4, bpm: 120), 32)
    }

    func testFlickerLimiterCapsStrobeTransitions() {
        let params = ParameterStore()
        params.set(.struktInvert, 1, origin: .ui)   // invert driven by LFO1
        params.set(.lfo1Wave, Float(LFOWave.square.rawValue), origin: .ui)
        params.set(.lfo1Rate, 15, origin: .ui)      // 15 Hz strobe attempt
        params.set(.flickerLimit, 1, origin: .ui)
        let engine = StruktEngine(params: params)

        // Simulate 2 seconds at 60 fps, counting invert transitions.
        var last = false, transitions = 0
        for frame in 0..<120 {
            let g = engine.tick(now: Double(frame) / 60.0)
            if g.invert != last { transitions += 1; last = g.invert }
        }
        // 3 Hz cap over 2 s allows at most ~6 transitions (+1 slack for the
        // initial edge).
        XCTAssertLessThanOrEqual(transitions, 7,
            "limiter must hold strobing to ~3 Hz, saw \(transitions) in 2s")

        // Without the limiter the same setup strobes much faster.
        params.set(.flickerLimit, 0, origin: .ui)
        let wild = StruktEngine(params: params)
        var wildLast = false, wildTransitions = 0
        for frame in 0..<120 {
            let g = wild.tick(now: Double(frame) / 60.0)
            if g.invert != wildLast { wildTransitions += 1; wildLast = g.invert }
        }
        XCTAssertGreaterThan(wildTransitions, 20)
    }

    func testFlipTogglesOnRisingEdgeOnly() {
        let params = ParameterStore()
        params.set(.struktFlip, 1, origin: .ui)
        params.set(.lfo1Wave, Float(LFOWave.square.rawValue), origin: .ui)
        params.set(.lfo1Rate, 1, origin: .ui)       // 1 Hz: one rising edge/s
        params.set(.flickerLimit, 0, origin: .ui)
        let engine = StruktEngine(params: params)
        var flips = 0, last = false
        for frame in 0..<180 {                       // 3 seconds
            let g = engine.tick(now: Double(frame) / 60.0)
            if g.flip != last { flips += 1; last = g.flip }
        }
        // One toggle per cycle (rising edge), 3 cycles -> ~3 flips.
        assertClose(flips, to: 3, within: 1)
    }

    func testTapTempoAverages() {
        let tap = TapTempo()
        XCTAssertNil(tap.tap(now: 0))
        XCTAssertEqual(tap.tap(now: 0.5) ?? 0, 120, accuracy: 0.5)   // 0.5s = 120 BPM
        XCTAssertEqual(tap.tap(now: 1.0) ?? 0, 120, accuracy: 0.5)
        // A long pause resets the measurement.
        XCTAssertNil(tap.tap(now: 10))
        XCTAssertEqual(tap.tap(now: 11) ?? 0, 60, accuracy: 0.5)     // 1s = 60 BPM
    }
}

extension XCTestCase {
    func assertClose(_ a: Int, to b: Int, within tolerance: Int,
                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(a - b), tolerance, file: file, line: line)
    }
}
