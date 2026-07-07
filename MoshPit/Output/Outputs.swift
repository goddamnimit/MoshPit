import AVFoundation
import Metal
import Photos
import Network
import CoreImage
import UIKit

// MARK: - Recorder (AVAssetWriter -> Photos)

/// Records the final composited texture to H.264/HEVC, optional mic audio,
/// saves to the photo library on stop.
final class MoshRecorder: NSObject, ObservableObject,
                          AVCaptureAudioDataOutputSampleBufferDelegate {
    enum Codec: String, CaseIterable { case h264 = "H.264", hevc = "HEVC" }

    @Published private(set) var isRecording = false
    @Published var codec: Codec = .hevc
    @Published var recordMic = false {
        didSet {
            if recordMic {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    if !granted {
                        DispatchQueue.main.async {
                            self.recordMic = false
                            self.lastError = "Microphone access denied"
                        }
                    }
                }
            }
        }
    }
    @Published private(set) var lastError: String?

    /// Fires on main after the file is finalized and the Photos save attempt
    /// completes: (fileURL, savedToPhotos). The temp file is RETAINED for the
    /// session gallery — its lifecycle is the launch sweep + gallery Delete +
    /// termination cleanup (see SessionClipStore), superseding the audit's
    /// original delete-on-stop rule.
    var onFinished: ((URL, Bool) -> Void)?
    /// Fires (any thread) when an unsupported codec config fell back to HEVC.
    var onFallbackNotice: ((String) -> Void)?

    private let ctx: MetalContext
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: CMTime?
    private var size = CGSize.zero
    private var audioSession: AVCaptureSession?
    private let audioQueue = DispatchQueue(label: "moshpit.rec.audio")
    private var texCache: CVMetalTextureCache?
    private let watermarkCompositor: WatermarkCompositor
    /// Latched at start() for the whole artifact — a purchase mid-recording
    /// does NOT drop the watermark; the recording keeps its starting state.
    private(set) var watermarkLatched = false

    init(ctx: MetalContext) {
        self.ctx = ctx
        watermarkCompositor = WatermarkCompositor(ctx: ctx)
        super.init()
        CVMetalTextureCacheCreate(nil, nil, ctx.device, nil, &texCache)
    }

    func start(width: Int, height: Int, watermark: Bool = false,
               codec codecType: AVVideoCodecType? = nil) {
        guard !isRecording else { return }
        watermarkLatched = watermark
        lastError = nil
        let url = SessionClipStore.recordingURL()
        do {
            let writer = try AVAssetWriter(url: url, fileType: .mov)
            var chosen = codecType ?? (codec == .hevc ? AVVideoCodecType.hevc : .h264)
            var settings: [String: Any] = [
                AVVideoCodecKey: chosen,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
            // ProRes encode needs hardware support (Apple-silicon media
            // engines; not every device/size). Validate the writer settings
            // and fall back to HEVC with a notice instead of crashing —
            // AVAssetWriterInput raises an exception on invalid settings.
            if !writer.canApply(outputSettings: settings, forMediaType: .video) {
                let requested = chosen == .proRes4444
                    ? RecordingSettings.Format.proRes4444.rawValue : "\(chosen.rawValue)"
                chosen = .hevc
                settings[AVVideoCodecKey] = chosen
                onFallbackNotice?("\(requested) not supported here — recording in HEVC")
            }
            let vin = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            vin.expectsMediaDataInRealTime = true
            writer.add(vin)
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: vin,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                ])
            if recordMic {
                do {
                    let audioSession = AVAudioSession.sharedInstance()
                    try audioSession.setCategory(.playAndRecord, options: [.mixWithOthers, .defaultToSpeaker])
                    try audioSession.setActive(true)
                } catch {
                    print("Failed to activate AVAudioSession: \(error)")
                }
                setupAudio(writer: writer)
            }
            self.writer = writer
            self.videoInput = vin
            self.adaptor = adaptor
            self.size = CGSize(width: width, height: height)
            self.startTime = nil
            writer.startWriting()
            isRecording = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func setupAudio(writer: AVAssetWriter) {
        let ain = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
        ])
        ain.expectsMediaDataInRealTime = true
        if writer.canAdd(ain) { writer.add(ain); audioInput = ain }
        let session = AVCaptureSession()
        if let dev = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: dev),
           session.canAddInput(input) {
            session.addInput(input)
            let out = AVCaptureAudioDataOutput()
            out.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(out) { session.addOutput(out) }
            audioSession = session
            audioQueue.async { session.startRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isRecording, startTime != nil,
              let audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    /// Frame consumer — called from the render thread with the final texture.
    func consume(texture: MTLTexture, time: CMTime) {
        guard isRecording, let writer, let videoInput, let adaptor,
              writer.status == .writing else { return }
        if startTime == nil {
            startTime = time
            writer.startSession(atSourceTime: time)
        }
        guard videoInput.isReadyForMoreMediaData,
              let pool = adaptor.pixelBufferPool else { return }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pixelBuffer = pb,
              let cb = ctx.queue.makeCommandBuffer() else { return }
        // GPU-convert RGBA16F canvas -> BGRA pixel buffer via a wrapped texture.
        var cvTex: CVMetalTexture?
        guard let cache = texCache else { return }
        CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cvTex)
        guard let dst = cvTex.flatMap(CVMetalTextureGetTexture) else { return }
        // Single watermark choke point (shared with snapshots): composited
        // post-Finisher, on the BGRA output texture, immediately before
        // pixel-buffer append. Canvas and texture-cache discipline untouched.
        watermarkCompositor.encodeBlit(from: texture, to: dst,
                                       watermark: watermarkLatched,
                                       commandBuffer: cb)
        cb.addCompletedHandler { [weak self] _ in
            guard let self, self.isRecording else { return }
            _ = adaptor.append(pixelBuffer, withPresentationTime: time)
        }
        cb.commit()
    }

    func stop() {
        guard isRecording, let writer else { return }
        isRecording = false
        audioSession?.stopRunning()
        audioSession = nil
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        let url = writer.outputURL
        writer.finishWriting { [weak self] in
            do {
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                try audioSession.setCategory(.ambient)
            } catch {
                print("Failed to deactivate AVAudioSession: \(error)")
            }
            // The temp file is NOT deleted on any path anymore — it feeds the
            // session gallery (share / remosh / social export). Reclaimed by
            // gallery Delete, the launch sweep, or termination cleanup.
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    DispatchQueue.main.async {
                        self?.lastError = "Photos access denied"
                        self?.onFinished?(url, false)
                    }
                    return
                }
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } completionHandler: { _, error in
                    DispatchQueue.main.async {
                        if let error { self?.lastError = error.localizedDescription }
                        self?.onFinished?(url, error == nil)
                    }
                }
            }
        }
        self.writer = nil; videoInput = nil; audioInput = nil; adaptor = nil
    }
}

// MARK: - MJPEG-over-HTTP server

/// Zero-dependency network output: Resolume Wire, OBS browser sources, or any
/// browser can pull http://<phone-ip>:8080/stream as multipart MJPEG.
final class MJPEGServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var clientCount = 0
    @Published var quality: CGFloat = 0.6
    @Published var fpsLimit: Double = 20
    @Published private(set) var sessionToken = ""
    var port: UInt16 = 8080

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let lock = NSLock()
    private let ciContext: CIContext
    private var lastSent: TimeInterval = 0
    private let encodeQueue = DispatchQueue(label: "moshpit.mjpeg", qos: .utility)
    private var encoding = false

    init(ctx: MetalContext) {
        ciContext = CIContext(mtlDevice: ctx.device, options: [.cacheIntermediates: false])
    }

    func start() {
        guard listener == nil else { return }
        sessionToken = UUID().uuidString.prefix(8).lowercased()
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.start(queue: .global(qos: .utility))
            self.listener = listener
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        lock.lock(); connections.forEach { $0.cancel() }; connections = []; lock.unlock()
        isRunning = false
        DispatchQueue.main.async { self.clientCount = 0 }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))
        // Consume the request, then reply with a never-ending multipart stream.
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            guard let data = data, let reqStr = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            let lines = reqStr.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else {
                conn.cancel()
                return
            }
            let parts = requestLine.components(separatedBy: " ")
            guard parts.count >= 2 else {
                conn.cancel()
                return
            }
            let urlStr = parts[1]
            guard !self.sessionToken.isEmpty, urlStr.contains("token=\(self.sessionToken)") else {
                let response = "HTTP/1.1 401 Unauthorized\r\nConnection: close\r\nContent-Type: text/plain\r\nContent-Length: 12\r\n\r\nUnauthorized"
                conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    conn.cancel()
                })
                return
            }
            let header = "HTTP/1.1 200 OK\r\nConnection: close\r\nCache-Control: no-cache\r\n"
                + "Content-Type: multipart/x-mixed-replace; boundary=moshframe\r\n\r\n"
            conn.send(content: header.data(using: .utf8), completion: .contentProcessed { _ in })
            self.lock.lock()
            self.connections.append(conn)
            let n = self.connections.count
            self.lock.unlock()
            DispatchQueue.main.async { self.clientCount = n }
        }
    }

    /// Frame consumer. Throttled + encoded off the render thread.
    func consume(texture: MTLTexture, time: CMTime) {
        let now = CACurrentMediaTime()
        lock.lock(); let hasClients = !connections.isEmpty; lock.unlock()
        guard isRunning, hasClients, !encoding,
              now - lastSent >= 1.0 / fpsLimit else { return }
        lastSent = now
        encoding = true
        // CIImage retains the texture; encode on a utility queue.
        guard var image = CIImage(mtlTexture: texture, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!]) else { encoding = false; return }
        image = image.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -image.extent.height))
        encodeQueue.async { [weak self] in
            guard let self else { return }
            defer { self.encoding = false }
            guard let data = self.ciContext.jpegRepresentation(
                of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: self.quality]) else { return }
            var packet = Data("--moshframe\r\nContent-Type: image/jpeg\r\nContent-Length: \(data.count)\r\n\r\n".utf8)
            packet.append(data)
            packet.append(Data("\r\n".utf8))
            self.lock.lock(); let conns = self.connections; self.lock.unlock()
            for conn in conns {
                conn.send(content: packet, completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.drop(conn) }
                })
            }
        }
    }

    private func drop(_ conn: NWConnection) {
        conn.cancel()
        lock.lock(); connections.removeAll { $0 === conn }; let n = connections.count; lock.unlock()
        DispatchQueue.main.async { self.clientCount = n }
    }
}

// MARK: - NDI

/// NDI output abstraction. The NDI Advanced SDK for iOS must be dropped in
/// manually (licensing) — see docs/NDI_SETUP.md. Until then the stub reports
/// unavailable and the MJPEG server / ReplayKit remain the network outputs.
protocol NDIBroadcaster: AnyObject {
    var isAvailable: Bool { get }
    var isSending: Bool { get }
    func start(name: String, width: Int, height: Int)
    func consume(texture: MTLTexture, time: CMTime)
    func stop()
}

#if canImport(NDI)
import NDI

/// Real sender against the NDI SDK (static libndi_ios.a, device builds).
/// Frames are converted to BGRA on the GPU into a shared-storage staging
/// texture, then read back and pushed to NDI on a dedicated queue so the
/// render loop never stalls; if the queue is still busy the frame is dropped.
final class NDISender: NDIBroadcaster {
    private static var hasInitialized = false
    private static var isInitSuccessful = false

    private static func initializeIfNeeded() -> Bool {
        if !hasInitialized {
            hasInitialized = true
            isInitSuccessful = NDIlib_initialize()
        }
        return isInitSuccessful
    }

    var isAvailable: Bool { true }
    private(set) var isSending = false

    private let ctx: MetalContext
    private var send: NDIlib_send_instance_t?
    private var staging: MTLTexture?
    private var buffer: UnsafeMutableRawPointer?
    private var w = 0, h = 0
    private let sendQueue = DispatchQueue(label: "moshpit.ndi", qos: .userInitiated)
    private var busy = false

    init(ctx: MetalContext) { self.ctx = ctx }

    func start(name: String, width: Int, height: Int) {
        guard Self.initializeIfNeeded(), send == nil else { return }
        w = width; h = height
        let cName = strdup(name)
        var desc = NDIlib_send_create_t()
        desc.p_ndi_name = UnsafePointer(cName)
        desc.clock_video = false      // we pace frames; don't block in send
        desc.clock_audio = false
        send = NDIlib_send_create(&desc)
        free(cName)
        guard send != nil else { return }

        // Shared-storage BGRA staging texture: GPU writes, CPU reads.
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared
        staging = ctx.device.makeTexture(descriptor: d)
        staging?.label = "ndi.staging"
        buffer = UnsafeMutableRawPointer.allocate(byteCount: width * height * 4,
                                                  alignment: 64)
        isSending = staging != nil && buffer != nil
    }

    /// Render-thread frame tap: enqueue a GPU blit; readback + send happen
    /// on `sendQueue` after the blit completes. Never blocks the caller.
    func consume(texture: MTLTexture, time: CMTime) {
        guard isSending, !busy, let staging,
              let cb = ctx.queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { return }
        busy = true
        enc.label = "ndi.blit"
        enc.setTexture(texture, index: 0)
        enc.setTexture(staging, index: 1)
        ctx.dispatch(enc, "blitScale", width: w, height: h)
        enc.endEncoding()
        cb.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            self.sendQueue.async { self.pushFrame() }
        }
        cb.commit()
    }

    private func pushFrame() {
        defer { busy = false }
        guard let send, let staging, let buffer, isSending else { return }
        staging.getBytes(buffer, bytesPerRow: w * 4,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        var frame = NDIlib_video_frame_v2_t()
        frame.xres = Int32(w)
        frame.yres = Int32(h)
        frame.FourCC = NDIlib_FourCC_video_type_BGRA
        frame.frame_rate_N = 60000
        frame.frame_rate_D = 1000
        frame.picture_aspect_ratio = 0        // square pixels
        frame.frame_format_type = NDIlib_frame_format_type_progressive
        frame.timecode = NDIlib_send_timecode_synthesize
        frame.p_data = buffer.assumingMemoryBound(to: UInt8.self)
        frame.line_stride_in_bytes = Int32(w * 4)
        frame.p_metadata = nil
        NDIlib_send_send_video_v2(send, &frame)
    }

    func stop() {
        isSending = false
        // Drain any in-flight send before tearing the instance down.
        sendQueue.sync {}
        if let send { NDIlib_send_destroy(send) }
        send = nil
        buffer?.deallocate(); buffer = nil
        staging = nil
    }

    deinit { stop() }
}
#endif

/// Compiled when the NDI SDK is absent.
final class NDIStub: NDIBroadcaster {
    var isAvailable: Bool { false }
    var isSending: Bool { false }
    func start(name: String, width: Int, height: Int) {}
    func consume(texture: MTLTexture, time: CMTime) {}
    func stop() {}
}

func makeNDIBroadcaster(ctx: MetalContext) -> NDIBroadcaster {
    #if canImport(NDI)
    return NDISender(ctx: ctx)
    #else
    return NDIStub()
    #endif
}
