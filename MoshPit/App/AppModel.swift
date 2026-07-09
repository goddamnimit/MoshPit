import SwiftUI
import UIKit
import Combine
import AVFoundation
import CoreMedia

enum DrawerSide { case left, right }

/// Composition root. Owns every subsystem and wires the render loop's fan-out.
final class AppModel: ObservableObject {
    let ctx: MetalContext?
    let params = ParameterStore()
    let sources: SourceManager?
    let automation: AutomationEngine
    let renderer: MoshRenderer?
    let midi: MIDIController
    let modMatrix: ModMatrix
    let recorder: MoshRecorder?
    let mjpeg: MJPEGServer?
    let ndi: NDIBroadcaster?

    @Published var stats = FrameStats()
    @Published var showHUD = true
    /// Preview aspect: true = fill (center-crop, default), false = fit.
    @Published var previewFill = true {
        didSet { renderer?.previewFill = previewFill }
    }
    @Published var performanceMode = false
    @Published var openDrawer: DrawerSide? = nil
    /// Hold-to-preview (Reset held): momentary clean passthrough.
    @Published var holdClean = false {
        didSet { renderer?.holdBypass = holdClean }
    }
    @Published var showCheatSheet = false
    /// Coach-mark tutorial: index into CoachScript.stops, nil = off.
    @Published var coachIndex: Int? = nil
    /// True when the tutorial is waiting for a drawer to animate open/close before positioning the spotlight.
    @Published var isTutorialTransitioning = false
    /// Floating dismissible tip card (guided demos).
    @Published var activeTip: String? = nil
    /// ParamRow to highlight (guided demos); cleared on interaction.
    @Published var highlightParam: ParameterID? = nil
    @Published var showDemoSheet = false
    @Published var activePanel: Panel? = nil
    /// Camera-app style shutter flash (snapshot feedback), auto-cleared.
    @Published var snapshotFlash = false
    /// Brief non-blocking toast (snapshot saved / Photos denied), auto-cleared.
    @Published var toast: String? = nil
    /// Post-recording/snapshot toast with Saved/Share actions. An overlay,
    /// never a sheet — canvas and drawers stay interactive underneath.
    @Published var shareToast: ShareToast? = nil
    /// Recordings made this session (temp files only; see SessionClipStore).
    @Published var sessionClips: [SessionClip] = []
    /// Fullscreen clip playback modal. Present ONLY via presentPlayback(_:),
    /// which respects the overlay mutual-exclusivity system.
    @Published var playbackClip: SessionClip? = nil
    /// Format/resolution for the NEXT recording (persisted; deliberately NOT
    /// in ParameterStore — see RecordingSettings).
    let recordingSettings = RecordingSettings()
    /// 9:16 social re-encode engine, driven from the gallery.
    let socialExporter = SocialExporter()
    /// Upgrade sheet (save-to-Photos paywall). Presented ONLY via
    /// presentUpgrade(for:), which respects the overlay mutual-exclusivity
    /// system.
    @Published var showUpgradeSheet = false
    /// The capability whose gate the user hit (there is exactly one today).
    private(set) var upgradeCapability: Capability?
    /// Completes the originally-blocked action when isPro flips true while
    /// the upgrade sheet is up (i.e. saves the pending recording to Photos).
    private var pendingProAction: (() -> Void)?
    #if DEBUG
    /// Test hook: overrides the entitlement check (the shared ProManager
    /// defaults to Pro under XCTest). nil = read ProManager.shared.
    private var debugProOverride: Bool?
    func debugSetPro(_ isPro: Bool?) { debugProOverride = isPro }
    #endif

    enum Panel: String, Identifiable, CaseIterable {
        case sources = "Sources", effects = "Effects", threeD = "3D",
             control = "Control", automation = "Automation", output = "Output",
             gallery = "Gallery"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .sources: return "video"
            case .effects: return "wand.and.stars"
            case .threeD: return "cube.transparent"
            case .control: return "slider.horizontal.3"
            case .automation: return "waveform.path"
            case .output: return "square.and.arrow.up"
            case .gallery: return "photo.stack"
            }
        }
    }

    private var cancellables = Set<AnyCancellable>()
    /// Last time `stats` was published (main thread only) — see onStats.
    private var lastStatsPublish: CFTimeInterval = 0
    private let effectOrderKey = "moshpit.effectOrder"
    /// One temp sweep per process — a second AppModel (tests) must not
    /// reclaim files the first instance's session still references.
    private static var didSweepTemp = false

    init() {
        let ctx = MetalContext()
        self.ctx = ctx
        automation = AutomationEngine(store: params)
        midi = MIDIController(params: params)
        modMatrix = ModMatrix(params: params)

        // Session-clip lifecycle: sweep stale MoshPit temp artifacts from
        // previous sessions once per process, and best-effort cleanup on
        // termination (see SessionClipStore for the audit rationale).
        if !Self.didSweepTemp {
            Self.didSweepTemp = true
            DispatchQueue.global(qos: .utility).async {
                SessionClipStore.sweepStaleRecordings()
            }
            NotificationCenter.default.addObserver(
                forName: UIApplication.willTerminateNotification,
                object: nil, queue: nil) { _ in
                SessionClipStore.sweepStaleRecordings()
            }
        }

        guard let ctx else {
            sources = nil; renderer = nil; recorder = nil; mjpeg = nil; ndi = nil
            // AppModel is always created on main (@StateObject / tests on main).
            MainActor.assumeIsolated { bindProManager() }
            return
        }
        let sources = SourceManager(device: ctx.device)
        self.sources = sources
        let renderer = MoshRenderer(ctx: ctx, params: params,
                                    sources: sources, automation: automation)
        self.renderer = renderer
        let recorder = MoshRecorder(ctx: ctx)
        self.recorder = recorder
        let mjpeg = MJPEGServer(ctx: ctx)
        self.mjpeg = mjpeg
        let ndi = makeNDIBroadcaster(ctx: ctx)
        self.ndi = ndi

        if let saved = UserDefaults.standard.stringArray(forKey: effectOrderKey) {
            let order = saved.compactMap(EffectID.init(rawValue:))
            if order.count == EffectID.allCases.count { renderer.effects.order = order }
        }

        renderer.frameConsumers = [
            { [weak recorder] tex, t in recorder?.consume(texture: tex, time: t) },
            { [weak mjpeg] tex, t in mjpeg?.consume(texture: tex, time: t) },
            { [weak ndi] tex, t in ndi?.consume(texture: tex, time: t) },
        ]
        renderer.previewFill = previewFill   // sync default (fill) explicitly
        // Publishing `stats` invalidates EVERY view observing AppModel, so a
        // per-frame (60 Hz) publish keeps the whole SwiftUI tree diffing
        // constantly and starves touch handling. 10 Hz is plenty for the HUD.
        renderer.onStats = { [weak self] s in
            guard let self else { return }
            let now = CACurrentMediaTime()
            guard now - self.lastStatsPublish >= 0.1 else { return }
            self.lastStatsPublish = now
            Perf.event("statsPublish")
            self.stats = s
        }
        renderer.modTap = { [weak self] s in self?.modMatrix.apply(stats: s) }

        // THE ONE PRO GATE (Capability.saveVideoToPhotos): consulted at
        // stop() time on main. Everything else about recording — quality,
        // formats, the session gallery, sharing — is free.
        recorder.allowsSaveToPhotos = { [weak self] in
            self?.entitled(.saveVideoToPhotos) ?? true
        }
        // Recording finished: build the gallery entry (thumbnail/duration/
        // size — blocking, so off main) and surface the Saved/Share toast —
        // or, when the save was gated, the upgrade sheet with the save kept
        // pending. The clip is in the session gallery on every path.
        recorder.onFinished = { [weak self] url, outcome in
            DispatchQueue.global(qos: .userInitiated).async {
                let clip = SessionClipStore.makeClip(url: url)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let clip { self.sessionClips.append(clip) }
                    switch outcome {
                    case .saved:
                        self.showShareToast("Saved to Photos", shareURL: url)
                    case .failed:
                        self.showShareToast("Saved to session gallery — enable Photos access in Settings",
                                            shareURL: url)
                    case .gated:
                        self.showShareToast("Saved to session gallery", shareURL: url)
                        self.presentUpgrade(for: .saveVideoToPhotos) { [weak self] in
                            self?.saveVideoToPhotos(url: url)
                        }
                    }
                }
            }
        }
        // ProRes fell back to HEVC (unsupported writer config on this device).
        recorder.onFallbackNotice = { [weak self] message in
            DispatchQueue.main.async { self?.showToast(message) }
        }

        // Default source: front camera ("FaceTime camera") into slot A.
        // (-nocamera: UI-test/screenshot hook — skip the permission prompt.)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-testvideo") {
            // Real moving video through the full file-ingest path.
            DispatchQueue.global(qos: .userInitiated).async {
                if let url = try? TestClipGenerator.generate(hdr: false, duration: 3) {
                    DispatchQueue.main.async {
                        sources.setURL(url, slot: .a, name: "Test Clip")
                    }
                }
            }
        } else if ProcessInfo.processInfo.arguments.contains("-testpattern") {
            // Portrait, like the front camera — exercises the aspect path.
            sources.setTestPattern(slot: .a, portrait: true)
        } else if !ProcessInfo.processInfo.arguments.contains("-nocamera") {
            let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
            if authStatus == .authorized || authStatus == .notDetermined {
                sources.setCamera(.front, slot: .a)
            } else {
                sources.setTestPattern(slot: .a, portrait: true)
            }
        }
        #else
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if authStatus == .authorized || authStatus == .notDetermined {
            sources.setCamera(.front, slot: .a)
        } else {
            sources.setTestPattern(slot: .a, portrait: true)
        }
        #endif

        // Republish child ObservableObjects so views nested off AppModel update.
        for child in [midi.objectWillChange.eraseToAnyPublisher(),
                      modMatrix.objectWillChange.eraseToAnyPublisher(),
                      automation.objectWillChange.eraseToAnyPublisher()] {
            child.receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        // AppModel is always created on main (@StateObject / tests on main).
        MainActor.assumeIsolated { bindProManager() }
    }

    // MARK: Pro gate (save-to-Photos only)

    /// The one entitlement read. Callers are all on main (toggleRecord /
    /// recorder.stop / share presentation).
    private func entitled(_ capability: Capability) -> Bool {
        #if DEBUG
        if let debugProOverride { return debugProOverride }
        #endif
        return MainActor.assumeIsolated { ProManager.shared.allows(capability) }
    }

    /// React to entitlement flips: dismiss the sheet and complete the
    /// pending save. (Nothing to degrade on Pro -> free: a refund simply
    /// re-gates future saves; no app state depends on the entitlement.)
    @MainActor private func bindProManager() {
        ProManager.shared.$isPro
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPro in
                if isPro { self?.completePendingProAction() }
            }
            .store(in: &cancellables)
    }

    /// Runs (and clears) the pending gated action; dismisses the sheet.
    /// Internal so tests can drive the purchase-success path directly.
    func completePendingProAction() {
        if showUpgradeSheet { showUpgradeSheet = false }
        pendingProAction?()
        pendingProAction = nil
    }

    /// Present the upgrade sheet through the same overlay-exclusivity rules
    /// as openSheet(): drawers/sheets animate away first. Never re-presents
    /// over itself.
    func presentUpgrade(for capability: Capability, andThen action: (() -> Void)? = nil) {
        upgradeCapability = capability
        pendingProAction = action
        guard !showUpgradeSheet else { return }
        showCheatSheet = false
        showDemoSheet = false
        let wait = openDrawer != nil || activePanel != nil
        openDrawer = nil
        activePanel = nil
        if wait {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.overlaySwap) {
                [weak self] in self?.showUpgradeSheet = true
            }
        } else {
            showUpgradeSheet = true
        }
    }

    /// Pending-save completion (after purchase/redeem): writes the finished
    /// recording to Photos and toasts the result.
    func saveVideoToPhotos(url: URL) {
        VideoPhotosSaver.save(url) { [weak self] saved, _ in
            self?.showShareToast(saved ? "Saved to Photos"
                                       : "Couldn't save — enable Photos access in Settings",
                                 shareURL: url)
        }
    }

    /// Output toggle: enable/disable the MJPEG server.
    func setMJPEGRunning(_ on: Bool) {
        guard let mjpeg else { return }
        if on { mjpeg.start() } else { mjpeg.stop() }
    }

    func toggleNDI() {
        guard let ndi, let renderer else { return }
        if ndi.isSending {
            ndi.stop()
        } else {
            ndi.start(name: "MoshPit", width: renderer.engine.canvasWidth,
                      height: renderer.engine.canvasHeight)
        }
    }

    var effectOrder: [EffectID] {
        get { renderer?.effects.order ?? EffectID.allCases }
        set {
            renderer?.effects.order = newValue
            UserDefaults.standard.set(newValue.map(\.rawValue), forKey: effectOrderKey)
            objectWillChange.send()
        }
    }

    // MARK: Lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            sources?.pauseAll()                 // pause capture, keep canvas
            if recorder?.isRecording == true { recorder?.stop() }
            if ndi?.isSending == true { ndi?.stop() }   // clean NDI teardown
        case .active: sources?.resumeAll()
        default: break
        }
    }

    // MARK: Overlay exclusivity (drawers vs sheets)

    /// One overlay at a time: sheets close drawers, drawers dismiss sheets,
    /// and a new sheet replaces the current one. ALL overlay presentation
    /// goes through these two methods — never set `activePanel`/`openDrawer`
    /// directly from UI code.
    private static let overlaySwap: TimeInterval = 0.35   // drawer spring + beat

    func openSheet(_ panel: Panel) {
        Perf.event("openSheet", panel.rawValue)
        showCheatSheet = false
        showDemoSheet = false
        guard activePanel != panel else { return }
        // Animate the drawer closed / old sheet down BEFORE presenting, so
        // the two are never on screen together.
        let wait = openDrawer != nil || activePanel != nil
        openDrawer = nil
        activePanel = nil
        if wait {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.overlaySwap) {
                [weak self] in self?.activePanel = panel
            }
        } else {
            activePanel = panel
        }
    }

    func openDrawer(_ side: DrawerSide?) {
        Perf.event("openDrawer", side.map { "\($0)" } ?? "close")
        let hadSheet = activePanel != nil || showCheatSheet || showDemoSheet
        activePanel = nil
        showCheatSheet = false
        showDemoSheet = false
        if hadSheet, side != nil {
            // Let the sheet's dismiss animation finish before sliding in.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.overlaySwap) {
                [weak self] in self?.openDrawer = side
            }
        } else {
            openDrawer = side
        }
    }

    // MARK: Keyboard actions (also used by touch buttons)

    func selectMode(_ mode: MoshMode) { params.set(.mode, Float(mode.rawValue), origin: .keyboard) }
    func reset() { renderer?.engine.requestReset() }
    func triggerBloom() { renderer?.engine.manualBloom() }

    /// Flip the active camera (slot A preferred). The canvas is deliberately
    /// NOT reset — the old camera's last frames smear into the new feed.
    func flipCamera() { sources?.flipCamera() }

    /// Shift+R: reverse playback on the first file-video slot (A wins).
    func toggleReverse() {
        sources?.toggleReverseOnActiveSlot()
    }

    /// M: cycle None -> Horizontal -> Vertical -> Quad -> None.
    func cycleMirrorMode() {
        params.set(.mirrorMode,
                   Float((Int(params.get(.mirrorMode)) + 1) % MirrorMode.allCases.count),
                   origin: .keyboard)
    }

    /// C: cycle None -> Invert -> Duotone -> Hue Shift -> None.
    func cycleColorMode() {
        params.set(.colorMode,
                   Float((Int(params.get(.colorMode)) + 1) % ColorMode.allCases.count),
                   origin: .keyboard)
    }

    // MARK: Snapshot (save canvas as image)

    /// Shutter: flash + haptic immediately; the renderer blits the next
    /// frame's post-finisher texture to a CPU-readable copy and we save it
    /// to Photos off-main. WYSIWYG — mirror/color modes are baked in.
    func snapshot() {
        guard let renderer else { return }
        Theme.haptic()
        withAnimation(.easeIn(duration: 0.05)) { snapshotFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(Theme.fade) { self.snapshotFlash = false }
        }
        renderer.requestSnapshot { [weak self] texture in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let texture, let image = SnapshotSaver.image(from: texture) else {
                    DispatchQueue.main.async { self?.showToast("Snapshot failed") }
                    return
                }
                // PNG temp copy so Share attaches the actual file (cleaned by
                // the session sweep, same lifecycle as recordings).
                let pngURL = SessionClipStore.snapshotURL()
                let wrote = (try? image.pngData()?.write(to: pngURL)) != nil
                SnapshotSaver.save(image) {
                    self?.showToast("Enable Photos access in Settings")
                } onSaved: {
                    self?.showShareToast("Saved to Photos",
                                         shareURL: wrote ? pngURL : nil)
                }
            }
        }
    }

    private func showToast(_ message: String) {
        withAnimation(Theme.fade) { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if self.toast == message {
                withAnimation(Theme.fade) { self.toast = nil }
            }
        }
    }

    // MARK: Share toast (post-recording / snapshot)

    /// Non-blocking Saved/Share toast; auto-dismisses after 4s.
    func showShareToast(_ message: String, shareURL: URL?) {
        let item = ShareToast(message: message, shareURL: shareURL)
        withAnimation(Theme.fade) { shareToast = item }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.shareToast == item {
                withAnimation(Theme.fade) { self?.shareToast = nil }
            }
        }
    }

    func dismissShareToast() {
        withAnimation(Theme.fade) { shareToast = nil }
    }

    // MARK: Session clip gallery

    /// Delete is BLOCKED while the clip is loaded in slot A — never yank the
    /// file out from under the player (caller shows an explanatory alert).
    func clipIsLoadedInSlotA(_ clip: SessionClip) -> Bool {
        sources?.sourceURL(slot: .a) == clip.url
    }

    /// Removes the gallery entry and deletes the temp file (off main).
    /// Returns false (and does nothing) when the clip is loaded in slot A.
    @discardableResult
    func deleteClip(_ clip: SessionClip) -> Bool {
        guard !clipIsLoadedInSlotA(clip) else { return false }
        sessionClips.removeAll { $0.id == clip.id }
        if playbackClip == clip { playbackClip = nil }
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: clip.url)
        }
        return true
    }

    /// Record -> remosh: assigns the clip to slot A through the existing
    /// file-video path (PlayerSource, incl. the HDR tone-map composition —
    /// these are SDR files so it passes through cleanly). The gallery sheet
    /// dismisses first; the source swap follows after the overlay settles.
    func loadClipIntoSlotA(_ clip: SessionClip) {
        openDrawer(nil)   // dismisses the gallery sheet cleanly
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.overlaySwap) {
            [weak self] in
            self?.sources?.setURL(clip.url, slot: .a, name: "Session Clip")
        }
    }

    /// Fullscreen clip playback through the same overlay-exclusivity rules
    /// as openSheet(): the gallery sheet animates away first.
    func presentPlayback(_ clip: SessionClip) {
        showCheatSheet = false
        showDemoSheet = false
        let wait = openDrawer != nil || activePanel != nil
        openDrawer = nil
        activePanel = nil
        if wait {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.overlaySwap) {
                [weak self] in self?.playbackClip = clip
            }
        } else {
            playbackClip = clip
        }
    }

    // MARK: Tutorial

    func startTutorial() {
        isTutorialTransitioning = false
        openDrawer = CoachScript.stops[0].drawer
        withAnimation(Theme.fade) { coachIndex = 0 }
    }

    func advanceTutorial() {
        guard let index = coachIndex else { return }
        let next = index + 1
        guard next < CoachScript.stops.count else { finishTutorial(); return }
        // Open/close drawers so each stop's target is actually on screen.
        if openDrawer != CoachScript.stops[next].drawer {
            isTutorialTransitioning = true
            openDrawer = CoachScript.stops[next].drawer
            // Let the drawer's 0.3s spring settle (plus a beat for the final
            // layout pass) BEFORE spotlighting: a frame read mid-slide pins
            // the ring where the element was, not where it lands. Drawer
            // motion is a rendering .offset — the published .global frames
            // are the resting positions — but the fade must not race the
            // preference update of newly appearing drawer content.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.coachIndex == index else { return }   // skipped?
                self.isTutorialTransitioning = false
                withAnimation(Theme.fade) { self.coachIndex = next }
            }
        } else {
            withAnimation(Theme.fade) { coachIndex = next }
        }
    }

    func skipTutorial() { finishTutorial() }

    func finishTutorial() {
        UserDefaults.standard.set(true, forKey: CoachScript.hasSeenKey)
        openDrawer = nil
        isTutorialTransitioning = false
        withAnimation(Theme.fade) { coachIndex = nil }
    }

    private let tapTempoTracker = TapTempo()
    /// Tap-tempo (T key / Control panel button): averages recent taps to BPM.
    func tapTempo() {
        if let bpm = tapTempoTracker.tap() {
            params.set(.bpm, bpm, origin: .ui)
        }
    }

    func toggleRecord() {
        guard let recorder, let renderer else { return }
        if recorder.isRecording { recorder.stop() }
        else {
            var w = renderer.engine.canvasWidth, h = renderer.engine.canvasHeight
            if let longEdge = recordingSettings.resolution.longEdge {
                // Export resolution sets the LONG edge; short edge derives
                // from the canvas aspect (even-rounded in outputSize).
                (w, h) = RecordingSettings.outputSize(
                    canvasWidth: w, canvasHeight: h, longEdge: longEdge)
            } else {
                // Match Canvas: keep the legacy output-resolution cap (LONG
                // edge, aspect preserved — same semantics as processing res).
                let cap = kResolutions[min(Int(params.get(.outputRes)), kResolutions.count - 1)]
                let long = max(w, h)
                if long > cap, long > 0 { w = w * cap / long; h = h * cap / long }
                (w, h) = (max(2, w & ~1), max(2, h & ~1))
            }
            recorder.start(width: w, height: h,
                           codec: recordingSettings.format.codecType)
        }
    }
    func nudgeDrift(dx: Float, dy: Float) {
        params.set(.driftX, params.get(.driftX) + dx, origin: .keyboard)
        params.set(.driftY, params.get(.driftY) + dy, origin: .keyboard)
    }
}

/// Saved/Share toast payload (post-recording and snapshot).
struct ShareToast: Equatable, Identifiable {
    let id = UUID()
    let message: String
    let shareURL: URL?
}
