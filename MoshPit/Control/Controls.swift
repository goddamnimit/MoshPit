import Foundation
import CoreMIDI
import Combine

// MARK: - MIDI (CoreMIDI, CC learn)

struct MIDIMapping: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var channel: UInt8      // 0-15
    var cc: UInt8
    var parameter: ParameterID
}

/// Listens to all MIDI sources. In learn mode, the next CC that moves gets
/// bound to the pending parameter. Mappings persist to UserDefaults.
final class MIDIController: ObservableObject {
    @Published private(set) var mappings: [MIDIMapping] = []
    @Published var learnTarget: ParameterID?       // set by UI: "tap a control"
    @Published private(set) var lastEvent: String = "—"

    private let params: ParameterStore
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private let defaultsKey = "moshpit.midi.mappings"

    init(params: ParameterStore) {
        self.params = params
        load()
        setup()
    }

    private func setup() {
        MIDIClientCreateWithBlock("MoshPit" as CFString, &client) { [weak self] notice in
            // Rescan on device hot-plug.
            if notice.pointee.messageID == .msgSetupChanged { self?.connectAll() }
        }
        MIDIInputPortCreateWithProtocol(client, "MoshPit In" as CFString, ._1_0, &port) {
            [weak self] eventList, _ in
            self?.handle(eventList: eventList)
        }
        connectAll()
    }

    private func connectAll() {
        for i in 0..<MIDIGetNumberOfSources() {
            MIDIPortConnectSource(port, MIDIGetSource(i), nil)
        }
    }

    private func handle(eventList: UnsafePointer<MIDIEventList>) {
        var packet = eventList.pointee.packet
        for _ in 0..<eventList.pointee.numPackets {
            let words = withUnsafeBytes(of: packet.words) { raw in
                Array(raw.bindMemory(to: UInt32.self).prefix(Int(packet.wordCount)))
            }
            for word in words {
                // MIDI 1.0-in-UMP: status in bits 16-23.
                let status = UInt8((word >> 16) & 0xFF)
                guard status & 0xF0 == 0xB0 else { continue }  // control change
                let channel = status & 0x0F
                let cc = UInt8((word >> 8) & 0x7F)
                let value = UInt8(word & 0x7F)
                received(channel: channel, cc: cc, value: value)
            }
            packet = MIDIEventPacketNext(&packet).pointee
        }
    }

    private func received(channel: UInt8, cc: UInt8, value: UInt8) {
        let normalized = Float(value) / 127.0
        DispatchQueue.main.async {
            self.lastEvent = "ch\(channel + 1) cc\(cc) = \(value)"
            if let target = self.learnTarget {
                self.mappings.removeAll { $0.parameter == target }
                self.mappings.append(MIDIMapping(channel: channel, cc: cc, parameter: target))
                self.learnTarget = nil
                self.save()
            }
        }
        for m in mappings where m.channel == channel && m.cc == cc {
            params.setNormalized(m.parameter, normalized, origin: .midi)
        }
    }

    func removeMapping(_ mapping: MIDIMapping) {
        mappings.removeAll { $0.id == mapping.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(mappings) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let m = try? JSONDecoder().decode([MIDIMapping].self, from: data) else { return }
        mappings = m
    }
}

// MARK: - Video-as-controller mod matrix

enum ModSource: String, CaseIterable, Codable, Identifiable {
    case meanLuma = "Mean Luma"
    case motionMagnitude = "Motion Amount"
    case motionAngle = "Motion Direction"
    case lfo1 = "LFO 1"
    case lfo2 = "LFO 2"
    var id: String { rawValue }
}

struct ModRoute: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var source: ModSource
    var destination: ParameterID
    var amount: Float           // -1..1 of the destination's full range
}

/// Routes analysis of the MOD input (mean luma / motion magnitude / dominant
/// motion direction) to any parameter. Fed every frame from the render loop.
final class ModMatrix: ObservableObject {
    @Published var routes: [ModRoute] = [] { didSet { save() } }
    private let params: ParameterStore
    private let defaultsKey = "moshpit.modmatrix"
    /// Base values captured when a route starts driving, so modulation is
    /// relative to where the user left the knob.
    private var bases: [UUID: Float] = [:]

    init(params: ParameterStore) {
        self.params = params
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let r = try? JSONDecoder().decode([ModRoute].self, from: data) {
            routes = r
        }
    }

    func apply(stats: FrameStats) {
        for route in routes {
            let signal: Float
            switch route.source {
            case .meanLuma: signal = stats.meanLuma
            case .motionMagnitude: signal = min(1, stats.meanMotionMag / 8.0)
            case .motionAngle:
                signal = (atan2(stats.meanMotion.y, stats.meanMotion.x) / (2 * .pi)) + 0.5
            case .lfo1: signal = stats.lfo1
            case .lfo2: signal = stats.lfo2
            }
            if bases[route.id] == nil {
                bases[route.id] = params.getNormalized(route.destination)
            }
            let n = max(0, min(1, bases[route.id]! + signal * route.amount))
            params.setNormalized(route.destination, n, origin: .videoMod)
        }
        // Forget bases for removed routes.
        let ids = Set(routes.map(\.id))
        bases = bases.filter { ids.contains($0.key) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(routes) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
