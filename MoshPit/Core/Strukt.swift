import Foundation
import QuartzCore

// MARK: - Strukt: temporal rhythm engine (after Signal Culture's Re:Struktr)
//
// Two LFOs tick on the render loop. Their values feed the mod matrix (as
// sources) and three dedicated strobe destinations rendered by Strukt.metal:
// source flip, color invert, and blackout/whiteout flash.

enum LFOWave: Int, CaseIterable {
    case sine = 0, square, triangle, saw, sampleHold
    static let names = ["SIN", "SQR", "TRI", "SAW", "S&H"]
}

/// Pure waveform evaluation, unit phase in [0,1) -> value in [0,1].
/// (Sample-&-hold is handled statefully in StruktEngine; here it returns the
/// phase itself so the engine can detect cycle boundaries determinicistally.)
func lfoWaveValue(_ wave: LFOWave, phase: Float) -> Float {
    let p = phase - floor(phase)
    switch wave {
    case .sine: return 0.5 + 0.5 * sin(2 * .pi * p)
    case .square: return p < 0.5 ? 1 : 0
    case .triangle: return p < 0.5 ? p * 2 : 2 - p * 2
    case .saw: return p
    case .sampleHold: return p
    }
}

/// Effective rate in Hz: free-running Hz, or a division of the tap tempo.
/// 1/1 = one cycle per beat, 1/16 = sixteen cycles per beat.
func lfoEffectiveRate(hz: Float, synced: Bool, divisionIndex: Int, bpm: Float) -> Float {
    guard synced else { return hz }
    let div = kLFODivisions[max(0, min(kLFODivisions.count - 1, divisionIndex))].1
    return (bpm / 60) * div
}

/// The per-frame gate decisions Strukt.metal consumes.
struct StruktGates {
    var flip = false        // hard A/B cut state
    var invert = false
    var flash: Float = 0    // 0..1 flash intensity
    var flashWhite = false
    var active: Bool { flip || invert || flash > 0 }
}

final class StruktEngine {
    private let params: ParameterStore
    private var phase: [Float] = [0, 0]
    private var shValue: [Float] = [0.5, 0.5]
    private var shCycle: [Int] = [-1, -1]
    private var rng = SystemRandomNumberGenerator()
    private var lastTime: TimeInterval = 0

    /// Latest oscillator outputs (0...1, post-depth), for the mod matrix.
    private(set) var value1: Float = 0
    private(set) var value2: Float = 0

    // Strobe state + flicker limiter bookkeeping.
    private var flipState = false
    private var prevFlipGate = false
    private var lastFlipChange: TimeInterval = 0
    private var invertState = false
    private var lastInvertChange: TimeInterval = 0
    private var flashState: Float = 0
    private var lastFlashChange: TimeInterval = 0

    /// Flicker limiter: minimum seconds between visible strobe transitions
    /// (3 Hz cap = one rising edge per 1/3 s).
    static let limiterMinInterval: TimeInterval = 1.0 / 3.0

    init(params: ParameterStore) { self.params = params }

    private func rawValue(_ index: Int, dt: Float) -> Float {
        let base: ParameterID = index == 0 ? .lfo1Wave : .lfo2Wave
        let wave = LFOWave(rawValue: Int(params.get(base))) ?? .sine
        let rate = lfoEffectiveRate(
            hz: params.get(index == 0 ? .lfo1Rate : .lfo2Rate),
            synced: params.bool(index == 0 ? .lfo1Sync : .lfo2Sync),
            divisionIndex: Int(params.get(index == 0 ? .lfo1Div : .lfo2Div)),
            bpm: params.get(.bpm))
        phase[index] = (phase[index] + rate * dt).truncatingRemainder(dividingBy: 1_000_000)
        let p = phase[index] + params.get(index == 0 ? .lfo1Phase : .lfo2Phase)
        if wave == .sampleHold {
            let cycle = Int(p)
            if cycle != shCycle[index] {
                shCycle[index] = cycle
                shValue[index] = Float.random(in: 0...1, using: &rng)
            }
            return shValue[index]
        }
        return lfoWaveValue(wave, phase: p)
    }

    private func lfoFor(_ selector: Float) -> Float? {
        switch Int(selector) {
        case 1: return value1
        case 2: return value2
        default: return nil
        }
    }

    /// Advance oscillators and derive gates. Call once per rendered frame.
    func tick(now: TimeInterval) -> StruktGates {
        let dt = lastTime > 0 ? Float(min(0.1, now - lastTime)) : 1.0 / 60.0
        lastTime = now
        value1 = rawValue(0, dt: dt) * params.get(.lfo1Depth)
        value2 = rawValue(1, dt: dt) * params.get(.lfo2Depth)

        let limited = params.bool(.flickerLimit)
        func allowed(_ last: TimeInterval) -> Bool {
            !limited || now - last >= Self.limiterMinInterval
        }

        var gates = StruktGates()

        // (a) Source flip: toggle on the oscillator's rising edge.
        if let v = lfoFor(params.get(.struktFlip)) {
            let gate = v > 0.5
            if gate && !prevFlipGate && allowed(lastFlipChange) {
                flipState.toggle()
                lastFlipChange = now
            }
            prevFlipGate = gate
        } else {
            flipState = false; prevFlipGate = false
        }
        gates.flip = flipState

        // (b) Invert: level-gated, limiter holds the current state when hot.
        if let v = lfoFor(params.get(.struktInvert)) {
            let want = v > 0.5
            if want != invertState, allowed(lastInvertChange) {
                invertState = want
                lastInvertChange = now
            }
        } else { invertState = false }
        gates.invert = invertState

        // (c) Flash: level-gated blackout/whiteout.
        if let v = lfoFor(params.get(.struktFlash)) {
            let want: Float = v > 0.5 ? 1 : 0
            if want != flashState, allowed(lastFlashChange) {
                flashState = want
                lastFlashChange = now
            }
        } else { flashState = 0 }
        gates.flash = flashState
        gates.flashWhite = params.bool(.struktFlashWhite)
        return gates
    }
}

// MARK: - Tap tempo

final class TapTempo {
    private var taps: [TimeInterval] = []

    /// Register a tap; returns the new BPM once two taps exist.
    func tap(now: TimeInterval = CACurrentMediaTime()) -> Float? {
        // A long gap starts a new measurement.
        if let last = taps.last, now - last > 2.5 { taps = [] }
        taps.append(now)
        if taps.count > 5 { taps.removeFirst() }
        guard taps.count >= 2 else { return nil }
        let intervals = zip(taps.dropFirst(), taps).map(-)
        let avg = intervals.reduce(0, +) / Double(intervals.count)
        return Float(min(300, max(30, 60.0 / avg)))
    }
}

// MARK: - Wipe math (Swift mirror of mixWipe in Strukt.metal, unit-tested)

func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = min(max((x - e0) / (e1 - e0), 0), 1)
    return t * t * (3 - 2 * t)
}

/// B-weight for the luma wipe: threshold sweeps down through luminance as
/// crossfade rises, so bright areas transition to B first.
func lumaWipeBlend(luma: Float, crossfade: Float, softness: Float) -> Float {
    let soft = max(0.001, softness)
    let edge = 1 + soft - crossfade * (1 + 2 * soft)
    return smoothstep(edge - soft, edge + soft, luma)
}
