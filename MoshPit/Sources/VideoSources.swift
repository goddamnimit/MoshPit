import AVFoundation
import CoreVideo
import Metal
import Combine
import UIKit

// MARK: - FrameSource protocol

/// Anything that can hand the engine a stream of Metal textures.
/// Sources are hot-swappable mid-mosh: the engine just samples whatever the
/// active source last delivered, so swapping never resets the canvas.
protocol FrameSource: AnyObject {
    var displayName: String { get }
    /// Latest frame as a BGRA Metal texture, nil until the first frame lands.
    var latestTexture: MTLTexture? { get }
    func start()
    func stop()
}

/// Shared CVPixelBuffer -> MTLTexture conversion (zero-copy via IOSurface).
///
/// LIFETIME: the MTLTexture is only valid while its owning CVMetalTexture
/// is alive. Dropping the wrapper immediately "works" on the simulator but
/// yields BLACK frames on device once the cache recycles the IOSurface —
/// so the last few wrappers are retained here (render loop is triple
/// buffered; 4 covers every in-flight frame).
final class TextureIngestor {
    private var cache: CVMetalTextureCache?
    private var retained: [CVMetalTexture] = []
    private let retainCount = 4
    private let lock = NSLock()

    init(device: MTLDevice) {
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    private var loggedBadFormat = false

    func texture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        guard let cache else { return nil }
        // One BGRA path for every source (camera converts in hardware).
        // A non-BGRA buffer here is a pipeline misconfiguration: make it
        // loud in DEBUG instead of silently producing a black canvas.
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_32BGRA else {
            #if DEBUG
            if !loggedBadFormat {
                loggedBadFormat = true
                print("TextureIngestor: unsupported pixel format \(fourcc(format)) — expected BGRA")
            }
            #endif
            return nil
        }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, .bgra8Unorm, w, h, 0, &cvTex)
        guard status == kCVReturnSuccess, let cvTex else {
            #if DEBUG
            if !loggedBadFormat {
                loggedBadFormat = true
                print("TextureIngestor: CVMetalTexture creation failed status=\(status)")
            }
            #endif
            return nil
        }
        retained.append(cvTex)
        if retained.count > retainCount { retained.removeFirst() }
        return CVMetalTextureGetTexture(cvTex)
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        if let cache { CVMetalTextureCacheFlush(cache, 0) }
    }
}

func fourcc(_ code: OSType) -> String {
    let bytes = [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255),
                 UInt8((code >> 8) & 255), UInt8(code & 255)]
    return String(bytes: bytes, encoding: .ascii) ?? String(code)
}

// MARK: - Camera source

/// Front or back camera. The front camera is the "FaceTime camera" use case.
final class CameraSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    private(set) var position: AVCaptureDevice.Position
    var displayName: String { position == .front ? "Front Camera" : "Back Camera" }

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "moshpit.camera", qos: .userInteractive)
    private let ingestor: TextureIngestor
    private(set) var latestTexture: MTLTexture?
    var onStatus: ((SourceStatus) -> Void)?
    private var reportedPlaying = false

    static func deviceAvailable(_ position: AVCaptureDevice.Position) -> Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) != nil
    }

    init(device: MTLDevice, position: AVCaptureDevice.Position) {
        self.position = position
        self.ingestor = TextureIngestor(device: device)
        super.init()
        configure()
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: cam),
              session.canAddInput(input) else {
            session.commitConfiguration(); return
        }
        session.addInput(input)
        // Request BGRA so the capture pipeline does the YCbCr->BGRA
        // conversion in hardware — CameraSource then feeds the SAME format
        // as PlayerSource and one ingestor path serves both.
        let bgra = [kCVPixelBufferPixelFormatTypeKey as String:
                        kCVPixelFormatType_32BGRA]
        output.videoSettings = bgra                    // set BEFORE attach
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        // Some iOS versions revert videoSettings to the sensor-native
        // YCbCr biplanar format when the output attaches — re-assert inside
        // the same configuration transaction so BGRA actually sticks.
        output.videoSettings = bgra
        applyConnectionSettings()
        session.commitConfiguration()
    }

    /// Rotation + mirroring for the CURRENT position. Front frames are
    /// mirrored on the capture connection itself (like the Camera app), so
    /// the estimator sees exactly the displayed pixels — motion vectors stay
    /// consistent with what's on screen across flips.
    private func applyConnectionSettings() {
        guard let conn = output.connection(with: .video) else { return }
        conn.videoRotationAngle = 90 // portrait-up frames
        if conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = (position == .front)
        }
    }

    /// Seamless front/rear flip: swap inputs inside one beginConfiguration/
    /// commitConfiguration on the session queue — the session (and the mosh
    /// canvas downstream) never stops, so the old camera's frames smear into
    /// the new feed. On any failure the current camera stays, silently.
    func flip(completion: ((Bool) -> Void)? = nil) {
        queue.async { [self] in
            let newPosition: AVCaptureDevice.Position = position == .front ? .back : .front
            guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                    for: .video, position: newPosition),
                  let newInput = try? AVCaptureDeviceInput(device: cam) else {
                completion?(false); return
            }
            session.beginConfiguration()
            let oldInputs = session.inputs
            oldInputs.forEach(session.removeInput)
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                position = newPosition
            } else {
                oldInputs.forEach { if session.canAddInput($0) { session.addInput($0) } }
            }
            applyConnectionSettings()
            session.commitConfiguration()
            completion?(position == newPosition)
        }
    }

    func start() {
        reportedPlaying = false
        onStatus?(.loading)
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            if granted {
                self.queue.async {
                    if !self.session.isRunning {
                        self.warmupRemaining = Self.warmupFrameCap
                        self.session.startRunning()
                    }
                }
            } else {
                self.onStatus?(.error("Camera access denied"))
            }
        }
    }

    func stop() { queue.sync { [session] in if session.isRunning { session.stopRunning() } } }

    private var loggedFirstFrame = false

    /// Sensor warm-up: the first frames after startRunning() are black while
    /// the exposure pipeline spins up. Publishing them is destructive — the
    /// mosh engine seeds its persistent canvas from the FIRST frame it sees,
    /// and Classic Smear (the default mode) never admits fresh pixels after
    /// that seed, so a black frame 1 means a black screen forever. Drop
    /// content-free frames until real imagery arrives (capped, so a genuinely
    /// dark scene still gets through).
    private static let warmupFrameCap = 30
    private var warmupRemaining = 0

    private func isBlackFrame(_ pb: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return false }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        var total = 0
        for gy in 0..<8 {
            let y = h * (2 * gy + 1) / 16
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for gx in 0..<8 {
                let x = w * (2 * gx + 1) / 16
                // BGRA: brightest channel of the sample.
                total += Int(max(row[x * 4], max(row[x * 4 + 1], row[x * 4 + 2])))
            }
        }
        return total / 64 < 8   // mean peak channel < 8/255: no content yet
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if warmupRemaining > 0 {
            if isBlackFrame(pb) {
                warmupRemaining -= 1
                return   // don't publish sensor warm-up black frames
            }
            warmupRemaining = 0
        }
        ingestor.flush()   // per-frame: drop stale IOSurface mappings (device)
        latestTexture = ingestor.texture(from: pb)
        if let tex = latestTexture {
            if !reportedPlaying {
                reportedPlaying = true
                onStatus?(.playing(tex.width, tex.height))
            }
        }
        #if DEBUG
        if !loggedFirstFrame, latestTexture != nil {
            loggedFirstFrame = true
            print("CameraSource: first frame \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) format=\(fourcc(CVPixelBufferGetPixelFormatType(pb)))")
        }
        #endif
    }
}

// MARK: - Player source (local files and HLS network streams)

enum SourceStatus: Equatable {
    case idle, loading
    case playing(Int, Int)          // width, height
    case error(String)

    var label: String {
        switch self {
        case .idle: return "empty"
        case .loading: return "Loading…"
        case .playing(0, 0): return "Live"
        case .playing(let w, let h): return "Playing \(w)x\(h)"
        case .error(let message): return message
        }
    }
}

/// Frame-taps an AVPlayer via AVPlayerItemVideoOutput.
///
/// Lifecycle notes (each of these was a real failure mode):
/// - The output is attached to the player's CURRENT item and follows it via
///   KVO — AVPlayerLooper swaps in copies of the template item, and an
///   AVPlayerItemVideoOutput may only belong to one item at a time.
/// - HDR sources (10-bit HEVC Dolby Vision/HLG, BT.2020 — i.e. every iPhone
///   recording) get an AVVideoComposition with BT.709 output color, which
///   makes AVFoundation tone-map to SDR so BGRA frames actually arrive.
/// - PHPicker/Files URLs use security-scoped access for the player's life.
/// - DRM/FairPlay assets are detected and surfaced; they never yield pixels.
///
/// `@unchecked Sendable`: the KVO and player-end callbacks the class hands to
/// `@Sendable`-annotated APIs all run on the main queue, where every mutable
/// property is also read/written (display link, UI-driven calls).
final class PlayerSource: FrameSource, @unchecked Sendable {
    let displayName: String
    /// Exposed so the session gallery can block deleting the file that is
    /// currently loaded in a slot (SourceManager.sourceURL(slot:)).
    let url: URL
    private let loop: Bool
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let output: AVPlayerItemVideoOutput
    private let ingestor: TextureIngestor
    private(set) var latestTexture: MTLTexture?
    private var displayLink: CADisplayLink?
    private var currentItemObs: NSKeyValueObservation?
    private var attachedItem: AVPlayerItem?
    private var scopedAccess = false
    private var sawFirstFrame = false
    private var started = false

    /// Status callback (SourceManager forwards to the Sources sheet).
    var onStatus: ((SourceStatus) -> Void)?

    /// Reverse playback (consumer-datamosh convention: smears run backwards).
    /// Frame delivery is unchanged — AVPlayerItemVideoOutput hands us whatever
    /// the item displays, regardless of rate sign, so the HDR tone-map
    /// composition and the BGRA pull path work identically in reverse.
    private(set) var isReversed = false

    /// Threshold + target for the seek-to-end that reverse playback needs.
    /// AVPlayer only honors rate = -1 from a position it can step back from:
    /// at (or near) time zero — including "never played forward yet" — it
    /// must first seek to the end. Returns nil when no seek is needed.
    /// Pure and unit-tested; `pull` also uses it for reverse looping.
    static func reverseSeekTarget(currentSeconds: Double,
                                  durationSeconds: Double) -> Double? {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        // Land one frame shy of the end so the item has a frame to display.
        let target = max(0, durationSeconds - 0.05)
        return currentSeconds < 0.1 ? target : nil
    }

    func setReversed(_ reversed: Bool) {
        guard reversed != isReversed else { return }
        isReversed = reversed
        DispatchQueue.main.async { [weak self] in self?.applyDirection() }
    }

    private func applyDirection() {
        guard let item = player.currentItem else { return }
        if isReversed {
            let duration = item.duration.seconds
            if let target = Self.reverseSeekTarget(
                currentSeconds: player.currentTime().seconds,
                durationSeconds: duration) {
                // At/near zero (or not yet played forward): seek to the end
                // first, then start stepping backwards.
                item.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    self?.player.rate = -1
                }
            } else {
                // Mid-clip after forward playback: reverse from right here.
                player.rate = -1
            }
        } else {
            player.rate = 1
        }
    }

    /// Reverse looping: rate = -1 stalls at time zero (no DidPlayToEndTime in
    /// reverse) — detect the stall on the display-link pull and wrap to the end.
    private func loopReverseIfStalled() {
        guard isReversed, let item = player.currentItem, player.rate == 0 else { return }
        guard let target = Self.reverseSeekTarget(
            currentSeconds: player.currentTime().seconds,
            durationSeconds: item.duration.seconds) else { return }
        item.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                  toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self, self.isReversed else { return }
            self.player.rate = -1
        }
    }

    init(device: MTLDevice, url: URL, loop: Bool, name: String? = nil) {
        displayName = name ?? url.lastPathComponent
        self.url = url
        self.loop = loop
        ingestor = TextureIngestor(device: device)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
        ])
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
    }

    /// BT.709-output composition: demands SDR, so AVFoundation tone-maps HDR
    /// content down instead of delivering nothing/garbage. File assets only
    /// (HLS variants manage their own composition).
    static func sdrToneMapComposition(for asset: AVAsset) async -> AVVideoComposition? {
        guard let comp = try? await AVMutableVideoComposition
            .videoComposition(withPropertiesOf: asset) else { return nil }
        comp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        comp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        comp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return comp
    }

    func start() {
        guard !started else {                 // resume after pause
            if isReversed { applyDirection() } else { player.play() }
            displayLink?.isPaused = false
            return
        }
        started = true
        onStatus?(.loading)
        scopedAccess = url.startAccessingSecurityScopedResource()
        Task { await setup() }
    }

    private func setup() async {
        if url.isFileURL, !FileManager.default.isReadableFile(atPath: url.path) {
            await report(.error("Couldn't read video file"))
            return
        }
        let asset = AVURLAsset(url: url)
        if (try? await asset.load(.hasProtectedContent)) == true {
            await report(.error("DRM-protected content can't be used"))
            return
        }
        if url.isFileURL {
            guard let tracks = try? await asset.loadTracks(withMediaType: .video),
                  !tracks.isEmpty else {
                await report(.error("No video track in file"))
                return
            }
        }
        // Tone-map HDR -> SDR for file assets (see sdrToneMapComposition).
        let composition = url.isFileURL
            ? await Self.sdrToneMapComposition(for: asset) : nil

        await MainActor.run {
            let template = AVPlayerItem(asset: asset)
            template.videoComposition = composition

            // Follow the current item: the looper replaces items with copies,
            // and the output can only be attached to one item at a time.
            currentItemObs = player.observe(\.currentItem, options: [.initial, .new]) {
                [weak self] player, _ in
                guard let self else { return }
                if let old = self.attachedItem { old.remove(self.output) }
                self.attachedItem = player.currentItem
                self.attachedItem?.add(self.output)
            }

            if loop, url.isFileURL {
                looper = AVPlayerLooper(player: player, templateItem: template)
            } else {
                player.insert(template, after: nil)
                if loop {   // stream fallback: seek-to-zero on end
                    NotificationCenter.default.addObserver(
                        forName: .AVPlayerItemDidPlayToEndTime, object: template,
                        queue: .main) { [weak self] _ in
                        self?.player.seek(to: .zero)
                        self?.player.play()
                    }
                }
            }
            player.play()

            let link = CADisplayLink(target: self, selector: #selector(pull))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    @MainActor private func report(_ status: SourceStatus) {
        onStatus?(status)
    }

    func stop() {
        player.pause()
        displayLink?.isPaused = true
    }

    deinit {
        displayLink?.invalidate()
        currentItemObs?.invalidate()
        if scopedAccess { url.stopAccessingSecurityScopedResource() }
    }

    @objc private func pull(_ link: CADisplayLink) {
        // Surface item-level failures (bad file, decode error).
        if let item = player.currentItem, item.status == .failed, !sawFirstFrame {
            sawFirstFrame = true   // report once
            let message = item.error?.localizedDescription ?? "Couldn't play video"
            onStatus?(.error(message))
            return
        }
        loopReverseIfStalled()
        let host = output.itemTime(forHostTime: link.targetTimestamp)
        guard output.hasNewPixelBuffer(forItemTime: host),
              let pb = output.copyPixelBuffer(forItemTime: host, itemTimeForDisplay: nil)
        else { return }
        ingestor.flush()   // per-frame: drop stale IOSurface mappings (device)
        latestTexture = ingestor.texture(from: pb)
        if !sawFirstFrame, latestTexture != nil {
            sawFirstFrame = true
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            #if DEBUG
            let f = CVPixelBufferGetPixelFormatType(pb)
            let fourcc = String(bytes: [UInt8((f >> 24) & 255), UInt8((f >> 16) & 255),
                                        UInt8((f >> 8) & 255), UInt8(f & 255)],
                                encoding: .ascii) ?? "????"
            print("MoshPit source '\(displayName)': first frame \(w)x\(h) format=\(fourcc)")
            #endif
            onStatus?(.playing(w, h))
        }
    }
}

// MARK: - Test pattern (UI-test/screenshot helper)

/// Static 16:9 gradient with corner markers + center circle so aspect
/// fill-vs-fit is visually obvious on camera-less simulators. Not part of the
/// performance feature set.
final class TestPatternSource: FrameSource {
    let displayName = "Test Pattern"
    private(set) var latestTexture: MTLTexture?

    init(device: MTLDevice, inverted: Bool = false, portrait: Bool = false) {
        let w = portrait ? 540 : 960, h = portrait ? 960 : 540
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]
        #if targetEnvironment(simulator)
        desc.storageMode = .shared
        #endif
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let border = x < 24 || y < 24 || x >= w - 24 || y >= h - 24
                let dx = Float(x - w / 2), dy = Float(y - h / 2)
                let ring = abs((dx * dx + dy * dy).squareRoot() - 200) < 6
                if border || ring {
                    px[i] = 255; px[i + 1] = 255; px[i + 2] = 255
                } else {
                    px[i] = UInt8(255 * x / w)                    // B ramp
                    px[i + 1] = UInt8((x / 48 + y / 48) % 2 == 0 ? 90 : 40)
                    px[i + 2] = UInt8(255 * y / h)                // R ramp
                    if inverted {                                 // variant for slot B
                        px[i] = 255 - px[i]; px[i + 1] = 200 - px[i + 1]
                        px[i + 2] = 255 - px[i + 2]
                    }
                }
                px[i + 3] = 255
            }
        }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: px, bytesPerRow: w * 4)
        latestTexture = tex
    }

    func start() {}
    func stop() {}
}

// MARK: - Source manager (slots A / B / mod)

enum SourceSlot: String, CaseIterable { case a = "A", b = "B", mod = "MOD" }

/// Owns the three source slots. Slot A feeds the canvas; slot B feeds
/// cross-mosh/weaver/slitscan gradients; MOD is the video-as-controller input.
final class SourceManager: ObservableObject {
    @Published private(set) var names: [SourceSlot: String] = [:]
    /// Per-slot ingest status for the Sources sheet — no silent blanks.
    @Published private(set) var statuses: [SourceSlot: SourceStatus] = [:]
    /// True when some slot holds a camera AND the opposite device exists.
    @Published private(set) var canFlipCamera = false
    /// Per-slot reverse playback state (PlayerSource slots only).
    @Published private(set) var reversed: [SourceSlot: Bool] = [:]
    private var sources: [SourceSlot: FrameSource] = [:]
    private let device: MTLDevice
    private let lock = NSLock()

    init(device: MTLDevice) { self.device = device }

    /// The camera to flip: slot A wins if several slots hold cameras.
    private func flippableCamera() -> CameraSource? {
        for slot in [SourceSlot.a, .b, .mod] {
            if let cam = sources[slot] as? CameraSource { return cam }
        }
        return nil
    }

    private func refreshFlipAvailability() {
        lock.lock()
        let cam = flippableCamera()
        lock.unlock()
        let can: Bool
        if let cam {
            can = CameraSource.deviceAvailable(cam.position == .front ? .back : .front)
        } else {
            can = false
        }
        DispatchQueue.main.async { self.canFlipCamera = can }
    }

    /// Flip the active camera in place (session is reconfigured, never torn
    /// down, so the persistent mosh canvas smears straight across the cut).
    func flipCamera() {
        lock.lock()
        let cam = flippableCamera()
        lock.unlock()
        guard let cam else { return }
        cam.flip { [weak self] flipped in
            guard let self, flipped else { return }   // failure: stay put, silently
            DispatchQueue.main.async {
                self.lock.lock()
                let slot = self.sources.first { $0.value === cam }?.key
                self.lock.unlock()
                if let slot { self.names[slot] = cam.displayName }
                self.refreshFlipAvailability()
            }
        }
    }

    /// The file/stream URL a slot is playing, nil for cameras/test patterns.
    /// (Session gallery: Delete is blocked while a clip is loaded in a slot.)
    func sourceURL(slot: SourceSlot) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return (sources[slot] as? PlayerSource)?.url
    }

    /// True when the slot holds a file/stream player (reverse applies).
    func isReversible(slot: SourceSlot) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sources[slot] is PlayerSource
    }

    func setReversed(_ on: Bool, slot: SourceSlot) {
        lock.lock()
        let player = sources[slot] as? PlayerSource
        lock.unlock()
        guard let player else { return }
        player.setReversed(on)
        DispatchQueue.main.async { self.reversed[slot] = on }
    }

    /// Keyboard convenience: toggle reverse on the first reversible slot
    /// (A wins over B over MOD). Returns the toggled slot, nil if none.
    @discardableResult
    func toggleReverseOnActiveSlot() -> SourceSlot? {
        for slot in [SourceSlot.a, .b, .mod] where isReversible(slot: slot) {
            setReversed(!(reversed[slot] ?? false), slot: slot)
            return slot
        }
        return nil
    }

    func texture(for slot: SourceSlot) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        return sources[slot]?.latestTexture
    }

    func setCamera(_ position: AVCaptureDevice.Position, slot: SourceSlot) {
        install(CameraSource(device: device, position: position), slot: slot)
    }

    func setURL(_ url: URL, slot: SourceSlot, name: String? = nil) {
        install(PlayerSource(device: device, url: url, loop: true, name: name), slot: slot)
    }

    func setTestPattern(slot: SourceSlot, inverted: Bool = false, portrait: Bool = false) {
        install(TestPatternSource(device: device, inverted: inverted,
                                  portrait: portrait), slot: slot)
    }

    func clear(slot: SourceSlot) {
        lock.lock()
        sources[slot]?.stop()
        sources[slot] = nil
        lock.unlock()
        DispatchQueue.main.async {
            self.names[slot] = nil
            self.statuses[slot] = nil
            self.reversed[slot] = nil
        }
        refreshFlipAvailability()
    }

    private func install(_ source: FrameSource, slot: SourceSlot) {
        lock.lock()
        sources[slot]?.stop()
        sources[slot] = source
        lock.unlock()
        if let player = source as? PlayerSource {
            player.onStatus = { [weak self] status in
                DispatchQueue.main.async { self?.statuses[slot] = status }
            }
        } else if let camera = source as? CameraSource {
            camera.onStatus = { [weak self] status in
                DispatchQueue.main.async { self?.statuses[slot] = status }
            }
        } else {
            DispatchQueue.main.async { self.statuses[slot] = .playing(0, 0) }
        }
        source.start()
        DispatchQueue.main.async {
            self.names[slot] = source.displayName
            self.reversed[slot] = nil          // fresh source plays forward
        }
        refreshFlipAvailability()
    }

    /// Backgrounding: pause capture but keep the canvas alive.
    func pauseAll() { lock.lock(); defer { lock.unlock() }; sources.values.forEach { $0.stop() } }
    func resumeAll() { lock.lock(); defer { lock.unlock() }; sources.values.forEach { $0.start() } }
}
