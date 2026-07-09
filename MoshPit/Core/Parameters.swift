import Foundation
import Combine
import os.lock

// MARK: - Parameter IDs

/// Every controllable value in the app is addressed by one of these IDs.
/// Control layers (touch, keyboard, MIDI, video-mod, automation replay) all
/// write through `ParameterStore`, so any control can drive any parameter.
enum ParameterID: String, CaseIterable, Codable, Hashable {
    // Engine
    case mode                   // 0..6 -> MoshMode
    case blockSize              // index into [4, 8, 16, 32]
    case processingRes          // index into [180, 240, 360, 540, 720, 1080]
    case estimatorBackend       // 0 = block match, 1 = Vision optical flow
    case smoothVectors          // 0 = nearest (blocky), 1 = bilinear
    case heal                   // 0...0.02 fresh-frame leak, anti-collapse
    case motionGain             // scales estimated vectors

    // Bloom
    case bloomRate              // Hz
    case bloomThreshold         // motion magnitude threshold (0..1)
    case bloomDecay             // seconds a bloom region stays alive
    case bloomAngle             // radians, direction bias for timed bloom
    case bloomBias              // magnitude of direction bias (px/frame)

    // Drift
    case driftX, driftY         // -1..1, joystick
    case driftReplaces          // 0 = add to estimate, 1 = replace estimate

    // Mix / cross
    case mixAmount              // 0 = frozen smear, 1 = clean passthrough
    case crossMosh              // 0 = off, 1 = A vectors displace B pixels

    // Feedback mosh
    case feedbackZoom           // -0.05..0.05 per frame
    case feedbackRotate         // radians per frame
    case feedbackX, feedbackY   // normalized offset per frame
    case feedbackHue            // hue rotation per pass, radians

    // Effect chain
    case echoEnabled, echoLayers, echoKeyLow, echoKeyHigh
    case slitscanEnabled, slitscanSpeed, slitscanAngle, slitscanUseB, slitscanScrub
    case weaverEnabled, weaverAmount
    case pixelSortEnabled, pixelSortThreshold, pixelSortVertical
    case procAmpEnabled, brightness, contrast, saturation, hueShift, gamma

    // Strukt LFO bank (Stage 1)
    case bpm
    case lfo1Wave, lfo1Rate, lfo1Sync, lfo1Div, lfo1Phase, lfo1Depth
    case lfo2Wave, lfo2Rate, lfo2Sync, lfo2Div, lfo2Phase, lfo2Depth
    case struktFlip, struktInvert, struktFlash   // 0 off, 1 LFO1, 2 LFO2
    case struktFlashWhite                        // flash color: 0 black, 1 white
    case flickerLimit                            // ON by default: strobe <= 3 Hz

    // Trace / Mass 3D (Stages 2-3)
    case trace3D                                 // alternate render path toggle
    case traceMode                               // 0 points, 1 wireframe, 2 solid
    case traceGrid                               // index into kTraceGrids
    case tracePointSize
    case traceDepth                              // luma Z-displacement, +/-
    case traceAutoRotate
    case traceAdditive                           // additive point blending
    case traceTrails                             // feedback trails background
    case tracePrimitive                          // 0 plane, 1 cube, 2 sphere, 3 torus
    case traceSpinX, traceSpinY, traceSpinZ
    case orbitAzimuth, orbitElevation, orbitDistance

    // Mixer wipes (Stage 4)
    case mixCrossfade                            // 0 = full A, 1 = full B
    case wipeMode                                // 0 crossfade, 1 luma, 2 mask
    case wipeSoftness
    case wipeLumaFromMod                         // luma wipe reads MOD instead of B

    // Finisher (post-chain mirror + color, feeds preview AND consumers)
    case mirrorMode             // 0 none, 1 horizontal, 2 vertical, 3 quad
    case mirrorRightToLeft      // horizontal sub-option: mirror right half left
    case colorMode              // 0 none, 1 invert, 2 duotone, 3 hue shift
    case duotoneShadowHue       // degrees, duotone shadow color
    case duotoneHighlightHue    // degrees, duotone highlight color
    case colorHueShift          // degrees, hue-shift color mode (LFO-friendly)

    // Output
    case cleanFeed
    case outputRes              // index into res table, caps at 1080

    var defaultValue: Float {
        switch self {
        case .mode: return 0
        case .blockSize: return 2            // 16 px
        case .processingRes: return 3        // 540p
        case .estimatorBackend: return 0
        case .smoothVectors: return 0
        case .heal: return 0
        case .motionGain: return 1
        case .bloomRate: return 1
        case .bloomThreshold: return 0.08
        case .bloomDecay: return 1.5
        case .bloomAngle: return 0
        case .bloomBias: return 0
        case .driftX, .driftY: return 0
        case .driftReplaces: return 0
        case .mixAmount: return 0.15
        case .crossMosh: return 0
        case .feedbackZoom: return 0.004
        case .feedbackRotate: return 0
        case .feedbackX, .feedbackY: return 0
        case .feedbackHue: return 0
        case .echoLayers: return 4
        case .echoKeyLow: return 0.3
        case .echoKeyHigh: return 0.7
        case .slitscanSpeed: return 0.5
        case .slitscanAngle: return 0
        case .weaverAmount: return 0.5
        case .pixelSortThreshold: return 0.5
        case .contrast, .saturation, .gamma: return 1
        case .brightness, .hueShift: return 0
        case .procAmpEnabled: return 1
        case .outputRes: return 5            // 1080p
        case .bpm: return 120
        case .lfo1Rate, .lfo2Rate: return 1
        case .lfo1Depth, .lfo2Depth: return 1
        case .flickerLimit: return 1
        case .traceGrid: return 2            // 128x128
        case .tracePointSize: return 3
        case .traceDepth: return 0.35
        case .traceAutoRotate: return 0.2
        case .orbitDistance: return 2.2
        case .orbitElevation: return 0.35
        case .wipeSoftness: return 0.15
        case .duotoneShadowHue: return 230    // cool shadows
        case .duotoneHighlightHue: return 20  // warm highlights
        default: return 0
        }
    }

    /// (min, max) for UI + MIDI scaling.
    var range: ClosedRange<Float> {
        switch self {
        case .mode: return 0...7
        case .blockSize: return 0...3
        case .processingRes, .outputRes: return 0...5
        case .heal: return 0...0.02
        case .motionGain: return 0...4
        case .bloomRate: return 0.1...12
        case .bloomThreshold: return 0...0.5
        case .bloomDecay: return 0.1...8
        case .bloomAngle: return 0...(2 * .pi)
        case .bloomBias: return 0...16
        case .driftX, .driftY: return -1...1
        case .feedbackZoom: return -0.05...0.05
        case .feedbackRotate: return -0.1...0.1
        case .feedbackX, .feedbackY: return -0.02...0.02
        case .feedbackHue: return 0...0.3
        case .echoLayers: return 1...16
        case .slitscanSpeed: return -2...2
        case .slitscanAngle: return 0...(2 * .pi)
        case .slitscanScrub: return 0...1
        case .brightness: return -1...1
        case .contrast: return 0...3
        case .saturation: return 0...3
        case .hueShift: return -Float.pi...Float.pi
        case .gamma: return 0.2...3
        case .bpm: return 30...300
        case .lfo1Wave, .lfo2Wave: return 0...4
        case .lfo1Rate, .lfo2Rate: return 0.1...30
        case .lfo1Div, .lfo2Div: return 0...4
        case .struktFlip, .struktInvert, .struktFlash: return 0...2
        case .traceMode: return 0...2
        case .traceGrid: return 0...3
        case .tracePointSize: return 1...16
        case .traceDepth: return -1...1
        case .traceAutoRotate: return -2...2
        case .tracePrimitive: return 0...3
        case .traceSpinX, .traceSpinY, .traceSpinZ: return -2...2
        case .orbitAzimuth: return -Float.pi...Float.pi
        case .orbitElevation: return -1.4...1.4
        case .orbitDistance: return 1...6
        case .wipeMode: return 0...2
        case .mirrorMode, .colorMode: return 0...3
        case .duotoneShadowHue, .duotoneHighlightHue, .colorHueShift: return 0...360
        default: return 0...1
        }
    }
}

enum MoshMode: Int, CaseIterable {
    case classicSmear = 0, bloom, timedBloom, drift, mixMosh, crossMosh, feedback
    case clean = 7   // appended so persisted automation raw values stay valid

    /// UI order: Clean first (baseline), then the mosh modes.
    static let displayOrder: [MoshMode] =
        [.clean, .classicSmear, .bloom, .timedBloom, .drift, .mixMosh, .crossMosh, .feedback]

    var title: String {
        switch self {
        case .clean: return "Clean"
        case .classicSmear: return "Classic Smear"
        case .bloom: return "Bloom"
        case .timedBloom: return "Timed Bloom"
        case .drift: return "Drift"
        case .mixMosh: return "Mix Mosh"
        case .crossMosh: return "Cross-Mosh"
        case .feedback: return "Feedback"
        }
    }
}

let kBlockSizes: [Int] = [4, 8, 16, 32]
let kTraceGrids: [Int] = [32, 64, 128, 256]
let kLFODivisions: [(String, Float)] = [("1/1", 1), ("1/2", 2), ("1/4", 4), ("1/8", 8), ("1/16", 16)]
let kResolutions: [Int] = [180, 240, 360, 540, 720, 1080]

// MARK: - ParameterStore

/// A change event, broadcast to observers (automation recorder, MIDI learn UI…).
struct ParameterChange {
    let id: ParameterID
    let value: Float
    let origin: ParameterOrigin
}

enum ParameterOrigin: String, Codable {
    case ui, keyboard, midi, videoMod, automation, system
}

/// Thread-safe central store. Reads are lock-protected and callable from the
/// render thread; SwiftUI observation happens via `objectWillChange` on main.
final class ParameterStore: ObservableObject {
    private var values: [ParameterID: Float]
    private var lock = os_unfair_lock_s()
    let changes = PassthroughSubject<ParameterChange, Never>()

    init() {
        var v = [ParameterID: Float]()
        for id in ParameterID.allCases { v[id] = id.defaultValue }
        values = v
    }

    func get(_ id: ParameterID) -> Float {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return values[id] ?? id.defaultValue
    }

    func set(_ id: ParameterID, _ raw: Float, origin: ParameterOrigin = .ui) {
        let value = min(max(raw, id.range.lowerBound), id.range.upperBound)
        os_unfair_lock_lock(&lock)
        let old = values[id]
        values[id] = value
        os_unfair_lock_unlock(&lock)
        guard old != value else { return }
        Perf.event("paramSet", "\(id.rawValue) \(origin.rawValue)")
        let change = ParameterChange(id: id, value: value, origin: origin)
        if Thread.isMainThread {
            objectWillChange.send(); changes.send(change)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.objectWillChange.send(); self?.changes.send(change)
            }
        }
    }

    /// Normalized (0...1) accessors used by MIDI and the mod matrix.
    func setNormalized(_ id: ParameterID, _ n: Float, origin: ParameterOrigin) {
        let r = id.range
        set(id, r.lowerBound + n * (r.upperBound - r.lowerBound), origin: origin)
    }

    func getNormalized(_ id: ParameterID) -> Float {
        let r = id.range
        return (get(id) - r.lowerBound) / (r.upperBound - r.lowerBound)
    }

    func bool(_ id: ParameterID) -> Bool { get(id) > 0.5 }
    func toggle(_ id: ParameterID, origin: ParameterOrigin = .ui) {
        set(id, bool(id) ? 0 : 1, origin: origin)
    }

    var mode: MoshMode { MoshMode(rawValue: Int(get(.mode))) ?? .classicSmear }

    /// SwiftUI binding helper.
    func binding(_ id: ParameterID) -> Binding<Float> {
        Binding(get: { self.get(id) }, set: { self.set(id, $0, origin: .ui) })
    }

    func snapshot() -> [ParameterID: Float] {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return values
    }
}

import SwiftUI

// MARK: - Automation record & replay

struct AutomationEvent: Codable, Equatable {
    let t: TimeInterval           // seconds from session start
    let id: ParameterID
    let value: Float
}

struct AutomationSession: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date
    var duration: TimeInterval
    var initialState: [String: Float]     // ParameterID rawValue -> value
    var events: [AutomationEvent]
}

/// Records every parameter change (except ones caused by replay itself) with a
/// timestamp; replays them, looped or one-shot, by scheduling against a clock
/// the render loop advances.
final class AutomationEngine: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPlaying = false
    @Published var loopPlayback = true
    @Published private(set) var sessions: [AutomationSession] = []

    private let store: ParameterStore
    private var cancellable: AnyCancellable?
    private var recordStart: TimeInterval = 0
    private var recorded: [AutomationEvent] = []
    private var recordedInitial: [String: Float] = [:]

    private var playSession: AutomationSession?
    private var playStart: TimeInterval = 0
    private var playCursor: Int = 0

    private let dir: URL

    init(store: ParameterStore) {
        self.store = store
        dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Automations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var excludeDir = dir
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? excludeDir.setResourceValues(resourceValues)
        loadSessions()
        cancellable = store.changes.sink { [weak self] change in
            guard let self, self.isRecording, change.origin != .automation else { return }
            self.recorded.append(AutomationEvent(
                t: CACurrentMediaTime() - self.recordStart, id: change.id, value: change.value))
        }
    }

    // Recording ---------------------------------------------------------

    func startRecording() {
        recorded = []
        recordedInitial = Dictionary(uniqueKeysWithValues:
            store.snapshot().map { ($0.key.rawValue, $0.value) })
        recordStart = CACurrentMediaTime()
        isRecording = true
    }

    @discardableResult
    func stopRecording(name: String? = nil) -> AutomationSession? {
        guard isRecording else { return nil }
        isRecording = false
        guard !recorded.isEmpty else { return nil }
        let session = AutomationSession(
            name: name ?? "Take \(sessions.count + 1)",
            createdAt: Date(),
            duration: recorded.last?.t ?? 0,
            initialState: recordedInitial,
            events: recorded)
        sessions.append(session)
        save(session)
        return session
    }

    // Playback ----------------------------------------------------------

    func play(_ session: AutomationSession) {
        playSession = session
        playStart = CACurrentMediaTime()
        playCursor = 0
        // Restore the state the take started from so replay is deterministic.
        for (key, value) in session.initialState {
            if let id = ParameterID(rawValue: key) { store.set(id, value, origin: .automation) }
        }
        isPlaying = true
    }

    func stopPlayback() { isPlaying = false; playSession = nil }

    /// Called once per rendered frame from the render loop.
    func tick() {
        guard isPlaying, let session = playSession else { return }
        let t = CACurrentMediaTime() - playStart
        while playCursor < session.events.count, session.events[playCursor].t <= t {
            let e = session.events[playCursor]
            store.set(e.id, e.value, origin: .automation)
            playCursor += 1
        }
        if playCursor >= session.events.count {
            if loopPlayback, session.duration > 0 {
                play(session)
            } else {
                stopPlayback()
            }
        }
    }

    // Persistence ---------------------------------------------------------

    private func url(for session: AutomationSession) -> URL {
        dir.appendingPathComponent("\(session.id.uuidString).moshauto")
    }

    private func save(_ session: AutomationSession) {
        if let data = try? JSONEncoder().encode(session) {
            try? data.write(to: url(for: session))
        }
    }

    private func loadSessions() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        sessions = files.filter { $0.pathExtension == "moshauto" }.compactMap {
            guard let data = try? Data(contentsOf: $0) else { return nil }
            do {
                let session = try JSONDecoder().decode(AutomationSession.self, from: data)
                for key in session.initialState.keys {
                    guard ParameterID(rawValue: key) != nil else {
                        #if DEBUG
                        print("Automation validation error: invalid parameter ID '\(key)'")
                        #endif
                        return nil
                    }
                }
                return session
            } catch {
                #if DEBUG
                print("Automation decode failed: \(error)")
                #endif
                return nil
            }
        }.sorted { $0.createdAt < $1.createdAt }
    }

    func rename(_ session: AutomationSession, to name: String) {
        guard let i = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[i].name = name
        save(sessions[i])
    }

    func delete(_ session: AutomationSession) {
        sessions.removeAll { $0.id == session.id }
        try? FileManager.default.removeItem(at: url(for: session))
        if playSession?.id == session.id { stopPlayback() }
    }
}

import QuartzCore
