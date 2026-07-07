import SwiftUI
import UIKit
import PhotosUI
import ReplayKit
import AVFoundation

struct PanelSheet: View {
    @EnvironmentObject var app: AppModel
    let panel: AppModel.Panel

    var body: some View {
        NavigationStack {
            Group {
                switch panel {
                case .sources: SourcesPanel()
                case .effects: EffectsPanel()
                case .threeD: TracePanel()
                case .control: ControlPanel()
                case .automation: AutomationPanel()
                case .output: OutputPanel()
                case .gallery: GalleryPanel(exporter: app.socialExporter)
                }
            }
            .navigationTitle(panel.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Sources

struct SourcesPanel: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var ticker = RefreshTicker.shared
    @State private var pickingFor: SourceSlot?
    @State private var urlText = ""
    @State private var urlFor: SourceSlot = .a
    @State private var validationError: String? = nil

    var body: some View {
        List {
            ForEach(SourceSlot.allCases, id: \.rawValue) { slot in
                Section {
                    LabeledContent("Active", value: app.sources?.names[slot] ?? "empty")
                    if let status = app.sources?.statuses[slot] {
                        LabeledContent("Status") {
                            HStack(spacing: Theme.gHalf) {
                                if app.sources?.reversed[slot] == true {
                                    Image(systemName: "backward.fill")
                                        .font(Theme.labelSmall)
                                        .foregroundStyle(Theme.accent)
                                        .accessibilityLabel("Reverse playback active")
                                }
                                Text(status.label)
                            }
                            .foregroundStyle({
                                if case .error = status { return Theme.accent }
                                return Theme.textSecondary
                            }())
                        }
                    }
                    if app.sources?.isReversible(slot: slot) == true {
                        Toggle("Reverse playback", isOn: Binding(
                            get: { app.sources?.reversed[slot] ?? false },
                            set: { on in
                                if on {
                                    app.requirePro(.reversePlayback) {
                                        app.sources?.setReversed(true, slot: slot)
                                    }
                                } else {
                                    app.sources?.setReversed(false, slot: slot)
                                }
                            }))
                    }
                    sourceButtonGrid(slot: slot)
                } header: {
                    if slot == .mod {
                        VStack(alignment: .leading, spacing: Theme.gHalf) {
                            Text("MOD")
                            Text("Controls parameters via brightness & motion")
                                .font(Theme.labelSmall)
                                .foregroundStyle(Theme.textSecondary)
                                .textCase(nil)
                        }
                    } else {
                        Text("Source \(slot.rawValue)")
                    }
                }
            }
            Section("Network stream (HLS)") {
                TextField("https://…/stream.m3u8", text: $urlText)
                    .keyboardType(.URL).autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: urlText) { _, _ in validationError = nil }
                if let err = validationError {
                    Text(err)
                        .font(Theme.labelSmall)
                        .foregroundStyle(Theme.accent)
                }
                Picker("Into slot", selection: $urlFor) {
                    ForEach(SourceSlot.allCases, id: \.rawValue) { Text($0.rawValue).tag($0) }
                }
                Button("Load stream") {
                    let cleaned = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let url = URL(string: cleaned), let scheme = url.scheme?.lowercased() else {
                        validationError = "Invalid URL format"
                        return
                    }
                    guard scheme == "https" else {
                        validationError = "URL must use HTTPS for security (ATS)"
                        return
                    }
                    guard url.pathExtension.lowercased() == "m3u8" || url.absoluteString.contains(".m3u8") else {
                        validationError = "URL must be an HLS stream (.m3u8)"
                        return
                    }
                    validationError = nil
                    gated(urlFor) { app.sources?.setURL(url, slot: urlFor, name: url.host()) }
                }
                Text("DRM/FairPlay streams won't yield pixel buffers and can't be moshed.")
                    .font(Theme.labelSmall).foregroundStyle(Theme.textSecondary)
            }
            Section("Mix — A/B wipes (feeds the mosh engine)") {
                ParamRow(id: .mixCrossfade, label: "A <-> B")
                ParamRow(id: .wipeMode, label: "Wipe", steps: ["XFADE", "LUMA", "MASK"])
                ParamRow(id: .wipeSoftness, label: "Soft")
                Toggle("Luma wipe reads MOD (else B)", isOn: boolBinding(.wipeLumaFromMod))
                Text("Route an LFO to the crossfader in Control for rhythmic source switching.")
                    .font(Theme.labelSmall).foregroundStyle(Theme.textSecondary)
            }
            Section("Processing") {
                PanelSlider(id: .processingRes, label: "Canvas res",
                            steps: kResolutions.map { "\($0)p" })
                PanelSlider(id: .blockSize, label: "Block size",
                            steps: kBlockSizes.map { "\($0)px" })
                Toggle("Smooth vectors (bilinear)", isOn: boolBinding(.smoothVectors))
                Toggle("Vision optical flow (vs block match)", isOn: boolBinding(.estimatorBackend))
                Toggle("Cross-mosh (A motion → B pixels)", isOn: boolBinding(.crossMosh))
                PanelSlider(id: .heal, label: "Heal leak")
            }
        }
        .sheet(item: $pickingFor) { slot in
            VideoPicker { url in
                if let url { app.sources?.setURL(url, slot: slot) }
                pickingFor = nil
            }
        }
    }

    /// The ONE choke point for attaching sources: slots B and MOD are
    /// Pro-gated; slot A (and Clear) never ask.
    private func gated(_ slot: SourceSlot, _ action: @escaping () -> Void) {
        if let capability = slot.requiredCapability {
            app.requirePro(capability, then: action)
        } else {
            action()
        }
    }

    /// Uniform 4-up source picker: identical widths, icon over caption,
    /// accent fill on the currently active choice. Same grid for A/B/MOD.
    private func sourceButtonGrid(slot: SourceSlot) -> some View {
        let name = app.sources?.names[slot]
        return HStack(spacing: Theme.g1) {
            // ("camera.front" isn't a real SF Symbol — viewfinder reads as selfie.)
            SlotSourceButton(icon: "person.fill.viewfinder", label: "Front",
                             selected: name == "Front Camera") {
                gated(slot) { app.sources?.setCamera(.front, slot: slot) }
            }
            SlotSourceButton(icon: "camera", label: "Rear",
                             selected: name == "Back Camera") {
                gated(slot) { app.sources?.setCamera(.back, slot: slot) }
            }
            SlotSourceButton(icon: "photo.on.rectangle.fill", label: "Video",
                             selected: app.sources?.isReversible(slot: slot) == true) {
                gated(slot) { pickingFor = slot }
            }
            SlotSourceButton(icon: "xmark.circle.fill", label: "Clear",
                             selected: false) {
                app.sources?.clear(slot: slot)
            }
        }
        .listRowInsets(EdgeInsets(top: Theme.g1, leading: Theme.g1,
                                  bottom: Theme.g1, trailing: Theme.g1))
    }

    private func boolBinding(_ id: ParameterID) -> Binding<Bool> {
        Binding(get: { app.params.bool(id) },
                set: { app.params.set(id, $0 ? 1 : 0, origin: .ui) })
    }
}

/// One cell of the source picker grid: fixed shape, no truncation.
private struct SlotSourceButton: View {
    let icon: String
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.gHalf) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                Text(label)
                    .font(.caption)
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: Theme.buttonStandard + Theme.g1)
            .background(selected ? Theme.accent : Theme.scrim)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .stroke(Theme.stroke, lineWidth: selected ? 0 : 1))
        }
        .buttonStyle(PressScaleStyle())
    }
}

extension SourceSlot: Identifiable { var id: String { rawValue } }

/// PHPicker for videos; copies the picked asset to a temp URL for AVPlayer.
struct VideoPicker: UIViewControllerRepresentable {
    let completion: (URL?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let completion: (URL?) -> Void
        init(completion: @escaping (URL?) -> Void) { self.completion = completion }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider,
                  provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) else {
                completion(nil); return
            }
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                guard let url else { DispatchQueue.main.async { self.completion(nil) }; return }
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
                try? FileManager.default.copyItem(at: url, to: dest)
                DispatchQueue.main.async { self.completion(dest) }
            }
        }
    }
}

// MARK: - Effects

struct EffectsPanel: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var ticker = RefreshTicker.shared

    var body: some View {
        List {
            Section("Chain (drag to reorder)") {
                ForEach(app.effectOrder) { fx in
                    VStack(alignment: .leading, spacing: Theme.g1) {
                        Toggle(fx.title, isOn: Binding(
                            get: { app.params.bool(fx.enableParam) },
                            set: { app.params.set(fx.enableParam, $0 ? 1 : 0, origin: .ui) }))
                        if app.params.bool(fx.enableParam) { effectParams(fx) }
                    }
                }
                .onMove { from, to in
                    var order = app.effectOrder
                    order.move(fromOffsets: from, toOffset: to)
                    app.effectOrder = order
                }
            }
            mirrorSection
            colorSection
        }
        .environment(\.editMode, .constant(.active))
    }

    /// Post-chain mirror (finisher pass): preview and recordings both get it.
    @ViewBuilder private var mirrorSection: some View {
        Section("Mirror (after chain — recorded too)") {
            Picker("Mirror", selection: Binding(
                get: { Int(app.params.get(.mirrorMode)) },
                set: { app.params.set(.mirrorMode, Float($0), origin: .ui) })) {
                ForEach(MirrorMode.allCases, id: \.rawValue) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            if Int(app.params.get(.mirrorMode)) == MirrorMode.horizontal.rawValue {
                Toggle("Mirror right half (instead of left)", isOn: Binding(
                    get: { app.params.bool(.mirrorRightToLeft) },
                    set: { app.params.set(.mirrorRightToLeft, $0 ? 1 : 0, origin: .ui) }))
            }
        }
    }

    @ViewBuilder private var colorSection: some View {
        Section("Color mode") {
            Picker("Color", selection: Binding(
                get: { Int(app.params.get(.colorMode)) },
                set: { app.params.set(.colorMode, Float($0), origin: .ui) })) {
                ForEach(ColorMode.allCases, id: \.rawValue) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            switch ColorMode(rawValue: Int(app.params.get(.colorMode))) {
            case .duotone:
                ParamRow(id: .duotoneShadowHue, label: "Shadow°")
                ParamRow(id: .duotoneHighlightHue, label: "Light°")
            case .hueShift:
                ParamRow(id: .colorHueShift, label: "Hue°")
                Text("Route an LFO to colorHueShift in Control for a color cycle.")
                    .font(Theme.labelSmall).foregroundStyle(Theme.textSecondary)
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func effectParams(_ fx: EffectID) -> some View {
        switch fx {
        case .echo:
            PanelSlider(id: .echoLayers, label: "Layers")
            PanelSlider(id: .echoKeyLow, label: "Key low")
            PanelSlider(id: .echoKeyHigh, label: "Key high")
        case .slitscan:
            PanelSlider(id: .slitscanSpeed, label: "Speed")
            PanelSlider(id: .slitscanAngle, label: "Angle")
            PanelSlider(id: .slitscanScrub, label: "Scrub")
            Toggle("Gradient from source B", isOn: Binding(
                get: { app.params.bool(.slitscanUseB) },
                set: { app.params.set(.slitscanUseB, $0 ? 1 : 0, origin: .ui) }))
        case .weaver:
            PanelSlider(id: .weaverAmount, label: "Amount")
        case .pixelSort:
            PanelSlider(id: .pixelSortThreshold, label: "Threshold")
            Toggle("Vertical", isOn: Binding(
                get: { app.params.bool(.pixelSortVertical) },
                set: { app.params.set(.pixelSortVertical, $0 ? 1 : 0, origin: .ui) }))
        case .procAmp:
            PanelSlider(id: .brightness, label: "Bright")
            PanelSlider(id: .contrast, label: "Contrast")
            PanelSlider(id: .saturation, label: "Sat")
            PanelSlider(id: .hueShift, label: "Hue")
            PanelSlider(id: .gamma, label: "Gamma")
        }
    }
}

// MARK: - Control (MIDI + mod matrix)

struct ControlPanel: View {
    @EnvironmentObject var app: AppModel
    @State private var newSource: ModSource = .meanLuma
    @State private var newDest: ParameterID = .mixAmount
    @State private var newAmount: Float = 0.5
    @State private var showFlickerWarning = false

    var body: some View {
        List {
            struktSection
            Section("MIDI (long-press any slider label, then move a knob)") {
                LabeledContent("Last event", value: app.midi.lastEvent)
                if let target = app.midi.learnTarget {
                    Label("Learning → \(target.rawValue)… move a CC",
                          systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(Theme.accent)
                    Button("Cancel learn") { app.midi.learnTarget = nil }
                }
                ForEach(app.midi.mappings) { m in
                    HStack {
                        Text("ch\(m.channel + 1) cc\(m.cc)").font(Theme.monoSmall).monospacedDigit()
                        Text("→ \(m.parameter.rawValue)").font(Theme.label)
                        Spacer()
                        Button { app.midi.removeMapping(m) } label: {
                            Image(systemName: "trash")
                        }.tint(Theme.accent)
                    }
                }
            }
            modMatrixSection
        }
        .alert("Photosensitivity warning", isPresented: $showFlickerWarning) {
            Button("Keep limiter on", role: .cancel) {
                app.params.set(.flickerLimit, 1, origin: .ui)
            }
            Button("I understand, raise the cap", role: .destructive) {}
        } message: {
            Text("Disabling the flicker limiter allows strobe effects faster than 3 Hz, which can trigger seizures in people with photosensitive epilepsy. Use with care in performance spaces.")
        }
    }

    @ViewBuilder private var struktSection: some View {
        Section("Strukt — LFO bank") {
            HStack(spacing: Theme.g1) {
                Button {
                    Theme.haptic()
                    app.tapTempo()
                } label: { Text("TAP") }
                .buttonStyle(MoshButtonStyle(size: .standard, selected: true))
                ParamRow(id: .bpm, label: "BPM")
            }
            lfoRows(1)
            lfoRows(2)
            ParamRow(id: .struktFlip, label: "Flip A/B", steps: ["OFF", "LFO1", "LFO2"])
            ParamRow(id: .struktInvert, label: "Invert", steps: ["OFF", "LFO1", "LFO2"])
            ParamRow(id: .struktFlash, label: "Flash", steps: ["OFF", "LFO1", "LFO2"])
            Toggle("Whiteout flash (vs blackout)", isOn: panelBool(.struktFlashWhite))
            Toggle("Flicker limiter (max 3 Hz strobe)", isOn: Binding(
                get: { app.params.bool(.flickerLimit) },
                set: { on in
                    app.params.set(.flickerLimit, on ? 1 : 0, origin: .ui)
                    // Photosensitivity warning, once, when the cap is raised.
                    let warnedKey = "moshpit.flickerWarned"
                    if !on, !UserDefaults.standard.bool(forKey: warnedKey) {
                        UserDefaults.standard.set(true, forKey: warnedKey)
                        showFlickerWarning = true
                    }
                }))
        }
    }

    @ViewBuilder private func lfoRows(_ n: Int) -> some View {
        let wave: ParameterID = n == 1 ? .lfo1Wave : .lfo2Wave
        let rate: ParameterID = n == 1 ? .lfo1Rate : .lfo2Rate
        let sync: ParameterID = n == 1 ? .lfo1Sync : .lfo2Sync
        let div: ParameterID = n == 1 ? .lfo1Div : .lfo2Div
        let phaseP: ParameterID = n == 1 ? .lfo1Phase : .lfo2Phase
        let depth: ParameterID = n == 1 ? .lfo1Depth : .lfo2Depth
        DisclosureGroup("LFO \(n)") {
            ParamRow(id: wave, label: "Wave", steps: LFOWave.names)
            if app.params.bool(sync) {
                ParamRow(id: div, label: "Division", steps: kLFODivisions.map(\.0))
            } else {
                ParamRow(id: rate, label: "Rate Hz")
            }
            Toggle("Tempo sync", isOn: panelBool(sync))
            ParamRow(id: phaseP, label: "Phase")
            ParamRow(id: depth, label: "Depth")
        }
    }

    private func panelBool(_ id: ParameterID) -> Binding<Bool> {
        Binding(get: { app.params.bool(id) },
                set: { app.params.set(id, $0 ? 1 : 0, origin: .ui) })
    }

    @ViewBuilder private var modMatrixSection: some View {
            Section("Mod matrix (MOD input & LFOs drive parameters)") {
                ForEach(app.modMatrix.routes) { route in
                    HStack {
                        Text("\(route.source.rawValue) → \(route.destination.rawValue)")
                            .font(Theme.label)
                        Spacer()
                        Text(String(format: "%+.2f", route.amount)).font(Theme.monoSmall).monospacedDigit()
                        Button {
                            app.modMatrix.routes.removeAll { $0.id == route.id }
                        } label: { Image(systemName: "trash") }.tint(Theme.accent)
                    }
                }
                Picker("Source", selection: $newSource) {
                    ForEach(ModSource.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Destination", selection: $newDest) {
                    ForEach(ParameterID.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                HStack {
                    Text("Amount").font(Theme.label)
                    Slider(value: $newAmount, in: -1...1)
                    Text(String(format: "%+.2f", newAmount)).font(Theme.monoSmall).monospacedDigit()
                }
                Button("Add route") {
                    app.requirePro(.modMatrix) {
                        app.modMatrix.routes.append(
                            ModRoute(source: newSource, destination: newDest, amount: newAmount))
                    }
                }
            }
    }
}

// MARK: - Automation

struct AutomationPanel: View {
    @EnvironmentObject var app: AppModel
    @State private var renaming: AutomationSession?
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                Button(app.automation.isRecording ? "■ Stop recording take" : "● Record automation take") {
                    if app.automation.isRecording { _ = app.automation.stopRecording() }
                    else { app.requirePro(.automation) { app.automation.startRecording() } }
                }
                .tint(app.automation.isRecording ? Theme.accent : Theme.textPrimary)
                Toggle("Loop playback", isOn: Binding(
                    get: { app.automation.loopPlayback },
                    set: { app.automation.loopPlayback = $0 }))
                if app.automation.isPlaying {
                    Button("■ Stop playback") { app.automation.stopPlayback() }
                }
            }
            Section("Takes") {
                ForEach(app.automation.sessions) { s in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(s.name)
                            Text("\(s.events.count) events · \(String(format: "%.1f", s.duration))s")
                                .font(Theme.labelSmall).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Button("▶") { app.requirePro(.automation) { app.automation.play(s) } }
                        Button { renaming = s; newName = s.name } label: {
                            Image(systemName: "pencil")
                        }
                        Button { app.automation.delete(s) } label: {
                            Image(systemName: "trash")
                        }.tint(Theme.accent)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .alert("Rename take", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let s = renaming { app.automation.rename(s, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

// MARK: - 3D (Trace / Mass)

struct TracePanel: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var ticker = RefreshTicker.shared

    var body: some View {
        List {
            Section("Trace — geometry renderer") {
                Toggle("3D mode", isOn: Binding(
                    get: { app.params.bool(.trace3D) },
                    set: { app.params.set(.trace3D, $0 ? 1 : 0, origin: .ui) }))
                ParamRow(id: .traceMode, label: "Render",
                         steps: ["POINTS", "WIRE", "SOLID"])
                ParamRow(id: .traceGrid, label: "Grid",
                         steps: kTraceGrids.map { "\($0)²" })
                ParamRow(id: .tracePointSize, label: "Pt size")
                ParamRow(id: .traceDepth, label: "Depth")
                Toggle("Additive points (glow)", isOn: Binding(
                    get: { app.params.bool(.traceAdditive) },
                    set: { app.params.set(.traceAdditive, $0 ? 1 : 0, origin: .ui) }))
                Toggle("Feedback trails", isOn: Binding(
                    get: { app.params.bool(.traceTrails) },
                    set: { app.params.set(.traceTrails, $0 ? 1 : 0, origin: .ui) }))
            }
            Section("Camera") {
                ParamRow(id: .traceAutoRotate, label: "Auto-rot")
                ParamRow(id: .orbitDistance, label: "Distance")
                ParamRow(id: .orbitElevation, label: "Elevation")
                Text("One finger orbits, two fingers zoom — on the canvas while 3D is on.")
                    .font(Theme.labelSmall).foregroundStyle(Theme.textSecondary)
            }
            Section("Mass — video on objects") {
                ParamRow(id: .tracePrimitive, label: "Object",
                         steps: TracePrimitive.names)
                ParamRow(id: .traceSpinX, label: "Spin X")
                ParamRow(id: .traceSpinY, label: "Spin Y")
                ParamRow(id: .traceSpinZ, label: "Spin Z")
            }
        }
    }
}

// MARK: - Output

struct OutputPanel: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var ticker = RefreshTicker.shared

    var body: some View {
        List {
            Section("Recording") {
                Button(app.recorder?.isRecording == true ? "■ Stop & save to Photos" : "● Record") {
                    app.toggleRecord()
                }
                .tint(app.recorder?.isRecording == true ? Theme.accent : Theme.textPrimary)
                if let rec = app.recorder {
                    Toggle("Record mic audio", isOn: Binding(
                        get: { rec.recordMic }, set: { rec.recordMic = $0 }))
                    if let err = rec.lastError {
                        Text(err).font(Theme.labelSmall).foregroundStyle(Theme.accent)
                    }
                }
            }
            ExportSettingsSection(settings: app.recordingSettings)
            Section("MJPEG network stream") {
                if let mjpeg = app.mjpeg {
                    Toggle("Serve MJPEG Stream", isOn: Binding(
                        get: { mjpeg.isRunning },
                        set: { app.setMJPEGRunning($0) }))
                    if mjpeg.isRunning {
                        VStack(alignment: .leading, spacing: Theme.gHalf) {
                            Text("URL (Local network only):")
                                .font(Theme.labelSmall).foregroundStyle(Theme.textSecondary)
                            Text("http://<device-ip>:\(mjpeg.port)/stream?token=\(mjpeg.sessionToken)")
                                .font(Theme.monoSmall)
                                .textSelection(.enabled)
                        }
                    }
                    LabeledContent("Clients", value: "\(mjpeg.clientCount)")
                    CopyMJPEGURLButton(mjpeg: mjpeg)
                    Text("Local network only. Requires active Wi-Fi. Access token is generated dynamically on startup. Pull from OBS browser source / Resolume Wire.")
                        .font(Theme.labelSmall).foregroundStyle(Theme.textSecondary)
                }
            }
            Section("NDI") {
                if app.ndi?.isAvailable == true {
                    Button(app.ndi?.isSending == true ? "Stop NDI" : "Start NDI \"MoshPit\"") {
                        app.toggleNDI()
                    }
                } else {
                    Text("NDI SDK not linked — see docs/NDI_SETUP.md. Use MJPEG or the screen broadcast below meanwhile.")
                        .font(Theme.labelSmall).foregroundStyle(Theme.textSecondary)
                }
            }
            Section("Screen broadcast (ReplayKit)") {
                BroadcastPickerView().frame(height: Theme.buttonStandard)
                Toggle("Clean feed (hide controls while broadcasting)", isOn: Binding(
                    get: { app.params.bool(.cleanFeed) },
                    set: {
                        app.params.set(.cleanFeed, $0 ? 1 : 0, origin: .ui)
                        app.performanceMode = $0
                        if $0 { app.showHUD = false }
                    }))
            }
            Section("Processing resolution") {
                PanelSlider(id: .processingRes, label: "Long edge",
                            steps: kResolutions.map { "\($0)p" })
                Text("Canvas long-edge resolution (default 540p). The canvas adopts the source's aspect ratio — sources are never stretched.")
                    .font(Theme.labelSmall).foregroundStyle(Theme.textSecondary)
            }
            Section("Output resolution") {
                PanelSlider(id: .outputRes, label: "Max res", steps: kResolutions.map { "\($0)p" })
                Text("NDI runs at canvas resolution, capped by this. Recording uses it only when Export resolution is Match Canvas.")
                    .font(Theme.labelSmall).foregroundStyle(Theme.textSecondary)
            }
            ProStatusSection()
        }
    }
}

// MARK: - Export settings (Output sheet)

/// Format + resolution for the NEXT recording. These live in
/// RecordingSettings (persisted via UserDefaults) — NOT ParameterStore; see
/// the RecordingSettings doc comment for why. ProRes 4444 and 4K are
/// Pro-only: locked rows show a Pro badge and route through requirePro.
private struct ExportSettingsSection: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var settings: RecordingSettings

    var body: some View {
        Section("Export — applies to next recording") {
            ForEach(RecordingSettings.Format.allCases) { format in
                optionRow(title: format.rawValue,
                          selected: settings.format == format,
                          locked: format.isProOnly && !app.isPro) {
                    if format.isProOnly {
                        app.requirePro(.proResExport) { settings.format = format }
                    } else {
                        settings.format = format
                    }
                }
            }
            Divider()
            ForEach(RecordingSettings.Resolution.allCases) { res in
                optionRow(title: res.rawValue,
                          selected: settings.resolution == res,
                          locked: res.isProOnly && !app.isPro) {
                    if res.isProOnly {
                        app.requirePro(.export4K) { settings.resolution = res }
                    } else {
                        settings.resolution = res
                    }
                }
            }
            Text("Resolution sets the recording's long edge; the short edge follows the canvas aspect.")
                .font(Theme.labelSmall).foregroundStyle(Theme.textSecondary)
        }
    }

    private func optionRow(title: String, selected: Bool, locked: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(Theme.label)
                    .foregroundStyle(Theme.textPrimary)
                    .opacity(locked ? Theme.disabledOpacity : 1)
                Spacer()
                if locked {
                    ProBadge()
                } else if selected {
                    Image(systemName: "checkmark")
                        .font(Theme.labelSmall)
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }
}

/// Small "PRO" lock badge for gated rows.
struct ProBadge: View {
    var body: some View {
        HStack(spacing: Theme.gHalf) {
            Image(systemName: "lock.fill")
            Text("PRO")
        }
        .font(Theme.labelSmall)
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, Theme.g1)
        .padding(.vertical, Theme.gHalf)
        .overlay(Capsule().stroke(Theme.accent, lineWidth: 1))
    }
}

// MARK: - Copy MJPEG URL

/// Copies http://<device-ip>:<port>/?token=<session-token> to the local
/// clipboard at explicit user request. Consistent with SECURITY_AUDIT.md:
/// the token is never logged or printed, and only exists while the server
/// runs. Disabled with a hint when the server is off.
private struct CopyMJPEGURLButton: View {
    @ObservedObject var mjpeg: MJPEGServer
    @State private var copied = false

    var body: some View {
        let canCopy = MJPEGShare.canCopyURL(serverRunning: mjpeg.isRunning,
                                            token: mjpeg.sessionToken)
        Button {
            guard let ip = MJPEGShare.deviceIPAddress() else { return }
            UIPasteboard.general.string = MJPEGShare.streamURLString(
                ip: ip, port: mjpeg.port, token: mjpeg.sessionToken)
            withAnimation(Theme.fade) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(Theme.fade) { copied = false }
            }
        } label: {
            HStack {
                Text(copied ? "Copied" : "Copy MJPEG URL").font(Theme.label)
                Spacer()
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(Theme.labelSmall)
                    .foregroundStyle(copied ? Theme.accent : Theme.textSecondary)
            }
        }
        .disabled(!canCopy)
        if !canCopy {
            Text("Start MJPEG server first.")
                .font(Theme.labelSmall).foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Bottom of the Output sheet: quiet Pro status when unlocked, otherwise a
/// Restore Purchases row that reflects purchaseState inline.
private struct ProStatusSection: View {
    @ObservedObject var pro = ProManager.shared

    var body: some View {
        Section("MoshPit Pro") {
            if pro.isPro {
                Text("MoshPit Pro ✓")
                    .font(Theme.label)
                    .foregroundStyle(Theme.accent)
            } else {
                Button {
                    Task { await pro.restore() }
                } label: {
                    HStack {
                        Text("Restore Purchases").font(Theme.label)
                        Spacer()
                        if pro.purchaseState == .restoring {
                            ProgressView().tint(Theme.textSecondary)
                        }
                    }
                }
                .disabled(pro.purchaseState == .restoring)
                switch pro.purchaseState {
                case .failed(let message):
                    Text(message).font(Theme.labelSmall).foregroundStyle(Theme.accent)
                case .info(let message):
                    Text(message).font(Theme.labelSmall).foregroundStyle(Theme.textSecondary)
                default:
                    EmptyView()
                }
            }
        }
    }
}

/// RPSystemBroadcastPickerView wrapper — mirrors the whole screen to any
/// broadcast extension (fallback path when NDI isn't linked).
struct BroadcastPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.showsMicrophoneButton = false
        return picker
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

// MARK: - Shared panel slider

struct PanelSlider: View {
    @EnvironmentObject var app: AppModel
    let id: ParameterID
    let label: String
    var steps: [String]? = nil

    var body: some View {
        HStack(spacing: Theme.g1) {
            Text(label).font(Theme.labelSmall).foregroundStyle(Theme.textSecondary)
                .frame(width: Theme.g6 + Theme.g3, alignment: .leading)
                .onLongPressGesture { app.midi.learnTarget = id }
            Slider(value: Binding(
                get: { app.params.get(id) },
                set: { app.params.set(id, steps != nil ? $0.rounded() : $0, origin: .ui) }),
                in: id.range)
                .tint(Theme.accent)
            if let steps {
                Text(steps[min(steps.count - 1, max(0, Int(app.params.get(id))))])
                    .font(Theme.monoSmall).monospacedDigit().foregroundStyle(Theme.textPrimary)
                    .frame(width: Theme.g6, alignment: .trailing)
            } else {
                Text(String(format: "%5.2f", app.params.get(id)))
                    .font(Theme.monoSmall).monospacedDigit().foregroundStyle(Theme.textPrimary)
                    .frame(width: Theme.g6, alignment: .trailing)
            }
        }
    }
}

import UniformTypeIdentifiers
