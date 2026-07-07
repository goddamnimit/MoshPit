import XCTest
import Metal
import MetalKit
import AVFoundation
import Network
import Darwin
@testable import MoshPit

final class SmokeTests: XCTestCase {

    // MARK: - Helper Methods

    private func findRandomAvailablePort() -> UInt16 {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return 8181 }
        defer { close(sock) }

        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        var addrCopy = addr
        let bindResult = withUnsafePointer(to: &addrCopy) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, size)
            }
        }
        guard bindResult == 0 else { return 8182 }

        var boundAddr = sockaddr_in()
        var boundAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getSockNameResult = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &boundAddrLen)
            }
        }
        guard getSockNameResult == 0 else { return 8183 }

        let port = Int(OSHostByteOrder() == OSLittleEndian ? _OSSwapInt16(boundAddr.sin_port) : boundAddr.sin_port)
        return UInt16(port)
    }

    private func makeBGRAColorTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        let texture = device.makeTexture(descriptor: desc)!
        var data = [UInt32](repeating: 0xFF0000FF, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                if (x + y) % 2 == 0 {
                    data[y * width + x] = 0xFF00FF00
                }
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: width * 4)
        return texture
    }

    private func readPixels(from texture: MTLTexture, device: MTLDevice, queue: MTLCommandQueue, width: Int, height: Int) -> [UInt8] {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        let staging = device.makeTexture(descriptor: desc)!

        let cb = queue.makeCommandBuffer()!
        let blit = cb.makeBlitCommandEncoder()!
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOriginMake(0, 0, 0), sourceSize: MTLSizeMake(width, height, 1), to: staging, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOriginMake(0, 0, 0))
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        let bytesPerPixel: Int
        switch texture.pixelFormat {
        case .rgba16Float:
            bytesPerPixel = 8
        case .rg32Float:
            bytesPerPixel = 8
        default:
            bytesPerPixel = 4
        }

        var bytes = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        staging.getBytes(&bytes, bytesPerRow: width * bytesPerPixel, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return bytes
    }

    private func getMemoryUsage() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kerr == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }

    // MARK: - 1. Pipeline Integrity

    func test1PipelineIntegrity() {
        guard let ctx = MetalContext() else { XCTFail("No MetalContext"); return }
        let store = ParameterStore()
        let engine = MoshEngine(ctx: ctx, params: store)

        let src1 = makeBGRAColorTexture(device: ctx.device, width: 540, height: 960)
        let src2 = makeBGRAColorTexture(device: ctx.device, width: 540, height: 960)

        let modesToTest: [(String, MoshMode)] = [
            ("classicSmear", .classicSmear),
            ("bloom", .bloom),
            ("timedBloom", .timedBloom),
            ("drift", .drift),
            ("mixMosh", .mixMosh),
            ("crossMosh", .crossMosh),
            ("feedback", .feedback),
            ("clean", .clean)
        ]

        for (name, mode) in modesToTest {
            print("--- Starting Pipeline Integrity test for mode: \(name) ---")
            store.set(.mode, Float(mode.rawValue))
            store.set(.processingRes, 3) // longEdge = 540

            // Tick 1
            let cb1 = ctx.queue.makeCommandBuffer()!
            _ = engine.encodeFrame(commandBuffer: cb1, sourceA: src1, sourceB: src2, now: 0.0)
            cb1.commit()
            cb1.waitUntilCompleted()

            // Tick 2
            let cb2 = ctx.queue.makeCommandBuffer()!
            let out2 = engine.encodeFrame(commandBuffer: cb2, sourceA: src1, sourceB: src2, now: 0.1)
            cb2.commit()
            cb2.waitUntilCompleted()

            guard let canvas = out2 else {
                XCTFail("Mode \(name) output texture is nil")
                continue
            }
            XCTAssertGreaterThan(canvas.width, 0, "Mode \(name) has zero width")
            XCTAssertGreaterThan(canvas.height, 0, "Mode \(name) has zero height")

            let bytes = readPixels(from: canvas, device: ctx.device, queue: ctx.queue, width: canvas.width, height: canvas.height)
            let hasNonZero = bytes.contains { $0 != 0 }
            XCTAssertTrue(hasNonZero, "Mode \(name) produced all-black/all-zero output")
            print("--- Finished Pipeline Integrity test for mode: \(name) ---")
        }
    }

    // MARK: - 2. Parameter Store

    func test2ParameterStore() {
        let store = ParameterStore()
        for id in ParameterID.allCases {
            let range = id.range
            let mid = (range.lowerBound + range.upperBound) / 2.0
            store.set(id, mid)
            XCTAssertEqual(store.get(id), mid, accuracy: 1e-5, "Round-trip failed for \(id)")

            store.set(id, range.lowerBound - 1.0)
            XCTAssertEqual(store.get(id), range.lowerBound, accuracy: 1e-5, "Lower clamp failed for \(id)")

            store.set(id, range.upperBound + 1.0)
            XCTAssertEqual(store.get(id), range.upperBound, accuracy: 1e-5, "Upper clamp failed for \(id)")
        }

        let expectation = self.expectation(description: "thread safety")
        expectation.expectedFulfillmentCount = 10
        let idToTest = ParameterID.motionGain
        for _ in 0..<10 {
            DispatchQueue.global().async {
                for _ in 0..<1000 {
                    let randVal = Float.random(in: -5...10)
                    store.set(idToTest, randVal)
                    let _ = store.get(idToTest)
                }
                expectation.fulfill()
            }
        }
        waitForExpectations(timeout: 5.0)
        let finalVal = store.get(idToTest)
        XCTAssertTrue(idToTest.range.contains(finalVal))
    }

    // MARK: - 3. LFO Engine (Strukt)

    func test3LFOEngine() {
        let store = ParameterStore()
        let engine = StruktEngine(params: store)

        let waveforms: [LFOWave] = [.sine, .square, .triangle, .saw, .sampleHold]
        for wave in waveforms {
            store.set(.lfo1Wave, Float(wave.rawValue))
            store.set(.lfo1Depth, 1.0)
            store.set(.lfo1Rate, 1.0)
            store.set(.lfo1Sync, 0)

            var prevVal: Float? = nil
            for frame in 0..<1000 {
                let now = Double(frame) / 60.0
                _ = engine.tick(now: now)

                let val = engine.value1 * 2.0 - 1.0
                XCTAssertTrue(val >= -1.0 && val <= 1.0, "Wave \(wave) output \(val) is outside [-1, 1]")

                if wave == .sine, let prev = prevVal {
                    let diff = abs(val - prev)
                    XCTAssertLessThan(diff, 0.15, "Sine jump \(diff) exceeds 0.15 between frames")
                }

                if wave == .square {
                    XCTAssertTrue(abs(val - 1.0) < 1e-5 || abs(val - (-1.0)) < 1e-5, "Square output \(val) is not -1.0 or 1.0")
                }

                prevVal = val
            }
        }

        let tap = TapTempo()
        XCTAssertNil(tap.tap(now: 0))
        let bpm120 = tap.tap(now: 0.5)
        XCTAssertEqual(bpm120 ?? 0, 120, accuracy: 0.5)
        let bpm120_2 = tap.tap(now: 1.0)
        XCTAssertEqual(bpm120_2 ?? 0, 120, accuracy: 0.5)

        XCTAssertNil(tap.tap(now: 10.0))
        let bpm60 = tap.tap(now: 11.0)
        XCTAssertEqual(bpm60 ?? 0, 60, accuracy: 0.5)
    }

    // MARK: - 4. Automation Record/Replay

    func test4AutomationRecordReplay() throws {
        let store = ParameterStore()
        let engine = AutomationEngine(store: store)

        XCTAssertTrue(Thread.isMainThread)

        engine.startRecording()

        for i in 0..<50 {
            let val = Float(i) * 0.01
            store.set(.mixAmount, val, origin: .ui)
            Thread.sleep(forTimeInterval: 0.002)
        }

        guard let session = engine.stopRecording(name: "smoke-test-take") else {
            XCTFail("Failed to record session")
            return
        }
        defer { engine.delete(session) }

        XCTAssertEqual(session.events.count, 50)

        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        let tempFileURL = tempDir.appendingPathComponent("temp-automation-\(UUID().uuidString).json")
        defer { try? fileManager.removeItem(at: tempFileURL) }

        let encoder = JSONEncoder()
        let data = try encoder.encode(session)
        try data.write(to: tempFileURL)

        let decoder = JSONDecoder()
        let loadedData = try Data(contentsOf: tempFileURL)
        let loadedSession = try decoder.decode(AutomationSession.self, from: loadedData)

        XCTAssertEqual(loadedSession.events.count, 50)
        XCTAssertEqual(loadedSession.name, "smoke-test-take")

        let jsonStr = String(data: loadedData, encoding: .utf8) ?? ""
        XCTAssertFalse(jsonStr.contains("Users/"), "JSON contains local file paths: \(jsonStr)")
        XCTAssertFalse(jsonStr.contains("Device"), "JSON might contain device identifiers")

        engine.loopPlayback = false
        engine.play(loadedSession)

        let mirror = Mirror(reflecting: engine)
        guard let playStart = mirror.descendant("playStart") as? TimeInterval else {
            XCTFail("Failed to read playStart from engine")
            return
        }

        for frame in 0..<60 {
            let targetTime = playStart + Double(frame) * (1.0 / 60.0)
            while CACurrentMediaTime() < targetTime {
                Thread.sleep(forTimeInterval: 0.001)
            }
            engine.tick()

            if let playCursor = mirror.descendant("playCursor") as? Int {
                let elapsed = targetTime - playStart
                let expectedCursor = loadedSession.events.filter { $0.t <= elapsed }.count
                XCTAssertLessThanOrEqual(abs(playCursor - expectedCursor), 2, "Cursor mismatch at frame \(frame)")
            }
        }
    }

    // MARK: - 5. Video Ingest

    func test5VideoIngest() throws {
        guard let ctx = MetalContext() else { XCTFail("No MetalContext"); return }

        // 1. SDR H.264
        let sdrURL = try! TestClipGenerator.generate(hdr: false, duration: 1.0)
        defer { try? FileManager.default.removeItem(at: sdrURL) }

        let sdrSource = PlayerSource(device: ctx.device, url: sdrURL, loop: false)
        sdrSource.start()

        let start = Date()
        var sdrFrame: MTLTexture? = nil
        // 10s (was 3s): simulator software H.264 decode startup is slower and
        // less predictable than on-device hardware decode — 3s flaked ~2/3 of
        // runs even on an idle system, unrelated to product behavior.
        while Date().timeIntervalSince(start) < 10.0 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if let tex = sdrSource.latestTexture {
                sdrFrame = tex
                break
            }
        }
        sdrSource.stop()

        guard let sdrTex = sdrFrame else {
            XCTFail("SDR H.264 frame did not arrive within 10 seconds")
            return
        }
        XCTAssertEqual(sdrTex.width, 640)
        XCTAssertEqual(sdrTex.height, 360)
        XCTAssertEqual(sdrTex.pixelFormat, .bgra8Unorm)

        // 2. HDR HEVC (XCTSkip if environment can't encode/decode HEVC)
        var hdrURL: URL? = nil
        do {
            hdrURL = try TestClipGenerator.generate(hdr: true, duration: 1.0)
        } catch {
            throw XCTSkip("HEVC Main10 encoding not supported in this environment: \(error)")
        }

        if let hdrURL = hdrURL {
            defer { try? FileManager.default.removeItem(at: hdrURL) }
            let hdrSource = PlayerSource(device: ctx.device, url: hdrURL, loop: false)
            hdrSource.start()

            let hdrStart = Date()
            var hdrFrame: MTLTexture? = nil
            while Date().timeIntervalSince(hdrStart) < 3.0 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                if let tex = hdrSource.latestTexture {
                    hdrFrame = tex
                    break
                }
            }
            hdrSource.stop()

            if let hdrTex = hdrFrame {
                XCTAssertEqual(hdrTex.width, 640)
                XCTAssertEqual(hdrTex.height, 360)
                XCTAssertEqual(hdrTex.pixelFormat, .bgra8Unorm)
            } else {
                XCTFail("HDR HEVC frame did not arrive within 3 seconds")
            }
        }

        // 3. Corrupt/empty file
        let emptyURL = FileManager.default.temporaryDirectory.appendingPathComponent("empty.mov")
        try! Data().write(to: emptyURL)
        defer { try? FileManager.default.removeItem(at: emptyURL) }

        let emptySource = PlayerSource(device: ctx.device, url: emptyURL, loop: false)
        var errorStatusObserved = false
        var observedErrorMsg = ""
        emptySource.onStatus = { status in
            if case .error(let msg) = status {
                errorStatusObserved = true
                observedErrorMsg = msg
            }
        }
        emptySource.start()

        let emptyStart = Date()
        while Date().timeIntervalSince(emptyStart) < 3.0 && !errorStatusObserved {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        emptySource.stop()

        XCTAssertTrue(errorStatusObserved, "Corrupt file did not produce an error status")
        XCTAssertFalse(observedErrorMsg.isEmpty, "Error message was empty")

        // 4. DRM-protected simulation
        let drmSource = PlayerSource(device: ctx.device, url: sdrURL, loop: false)

        var drmErrorObserved = false
        drmSource.onStatus = { status in
            if case .error(let msg) = status, msg.contains("DRM-protected content") {
                drmErrorObserved = true
            }
        }

        let mirror = Mirror(reflecting: drmSource)
        guard let player = mirror.children.first(where: { $0.label == "player" })?.value as? AVQueuePlayer else {
            XCTFail("Failed to retrieve AVQueuePlayer")
            return
        }

        // Intercept insertion synchronously before any frame ticks to swap with MockFailedPlayerItem
        let interceptObs = player.observe(\.currentItem, options: [.new]) { _, change in
            if let newItem = change.newValue as? AVPlayerItem, !(newItem is MockFailedPlayerItem) {
                let mockError = NSError(domain: "AVFoundation", code: 1, userInfo: [NSLocalizedDescriptionKey: "DRM-protected content"])
                let mockItem = MockFailedPlayerItem(url: sdrURL, error: mockError)
                mockItem.mockStatus = .unknown
                player.removeAllItems()
                player.insert(mockItem, after: nil)
                
                // Move status to failed after item has been safely loaded in the queue
                DispatchQueue.main.async {
                    mockItem.mockStatus = .failed
                }
            }
        }

        drmSource.start()

        let drmStart = Date()
        while Date().timeIntervalSince(drmStart) < 3.0 && !drmErrorObserved {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        drmSource.stop()
        interceptObs.invalidate()

        XCTAssertTrue(drmErrorObserved, "DRM-protected simulation did not surface error")
    }

    // MARK: - 6. Snapshot

    func test6Snapshot() {
        guard let ctx = MetalContext() else { XCTFail("No MetalContext"); return }
        let store = ParameterStore()
        let sources = SourceManager(device: ctx.device)
        let automation = AutomationEngine(store: store)
        let renderer = MoshRenderer(ctx: ctx, params: store, sources: sources, automation: automation)

        let mtkView = MTKView(frame: CGRect(x: 0, y: 0, width: 640, height: 360), device: ctx.device)
        mtkView.drawableSize = CGSize(width: 640, height: 360)

        sources.setTestPattern(slot: .a, inverted: false, portrait: false)

        let expectation = self.expectation(description: "Snapshot callback")
        var snapshotImage: UIImage? = nil
        var actualW = 0
        var actualH = 0

        renderer.requestSnapshot { texture in
            DispatchQueue.global().async {
                guard let texture = texture else {
                    XCTFail("Snapshot returned nil texture")
                    expectation.fulfill()
                    return
                }

                actualW = texture.width
                actualH = texture.height
                XCTAssertGreaterThan(actualW, 0)
                XCTAssertGreaterThan(actualH, 0)

                let bytes = self.readPixels(from: texture, device: ctx.device, queue: ctx.queue, width: actualW, height: actualH)

                guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                      let cgImage = CGImage(
                        width: actualW, height: actualH,
                        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: actualW * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
                      ) else {
                    XCTFail("Failed to create CGImage")
                    expectation.fulfill()
                    return
                }

                snapshotImage = UIImage(cgImage: cgImage)
                expectation.fulfill()
            }
        }

        renderer.draw(in: mtkView)

        waitForExpectations(timeout: 10.0)

        guard let image = snapshotImage else {
            XCTFail("No snapshot image produced")
            return
        }
        XCTAssertEqual(image.size.width, CGFloat(actualW))
        XCTAssertEqual(image.size.height, CGFloat(actualH))

        guard let pngData = image.pngData() else {
            XCTFail("Failed to encode PNG")
            return
        }
        XCTAssertGreaterThan(pngData.count, 0)
    }

    // MARK: - 7. Mirror/Color Finisher

    func test7Finisher() {
        guard let ctx = MetalContext() else { XCTFail("No MetalContext"); return }
        let store = ParameterStore()
        let finisher = FinisherPass(ctx: ctx, params: store)

        let width = 64
        let height = 64
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        let inputTex = ctx.device.makeTexture(descriptor: desc)!

        var inputPixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                if x < width / 2 {
                    inputPixels[idx] = 25
                    inputPixels[idx + 1] = 51
                    inputPixels[idx + 2] = 76
                    inputPixels[idx + 3] = 255
                } else {
                    inputPixels[idx] = 178
                    inputPixels[idx + 1] = 204
                    inputPixels[idx + 2] = 229
                    inputPixels[idx + 3] = 255
                }
            }
        }
        inputTex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: inputPixels, bytesPerRow: width * 4)

        for mirrorMode in MirrorMode.allCases {
            for colorMode in ColorMode.allCases {
                store.set(.mirrorMode, Float(mirrorMode.rawValue))
                store.set(.colorMode, Float(colorMode.rawValue))
                store.set(.mirrorRightToLeft, 0)
                store.set(.duotoneShadowHue, 0.0)
                store.set(.duotoneHighlightHue, 120.0)

                let cb = ctx.queue.makeCommandBuffer()!
                let outputTex = finisher.encode(commandBuffer: cb, input: inputTex)
                cb.commit()
                cb.waitUntilCompleted()

                XCTAssertEqual(outputTex.width, width)
                XCTAssertEqual(outputTex.height, height)

                let outputPixels = readPixels(from: outputTex, device: ctx.device, queue: ctx.queue, width: width, height: height)

                if mirrorMode == .horizontal && colorMode == .none {
                    for y in 0..<height {
                        for x in (width / 2)..<width {
                            let idx = (y * width + x) * 4
                            let mirrorIdx = (y * width + (width - 1 - x)) * 4
                            XCTAssertEqual(outputPixels[idx], inputPixels[mirrorIdx], "Mirror mismatch at x=\(x)")
                            XCTAssertEqual(outputPixels[idx + 1], inputPixels[mirrorIdx + 1])
                            XCTAssertEqual(outputPixels[idx + 2], inputPixels[mirrorIdx + 2])
                        }
                    }
                }

                if mirrorMode == .none && colorMode == .invert {
                    for y in 0..<height {
                        for x in 0..<width {
                            let idx = (y * width + x) * 4
                            let expectedR = 255 - inputPixels[idx]
                            let expectedG = 255 - inputPixels[idx + 1]
                            let expectedB = 255 - inputPixels[idx + 2]
                            XCTAssertEqual(outputPixels[idx], expectedR, accuracy: 2)
                            XCTAssertEqual(outputPixels[idx + 1], expectedG, accuracy: 2)
                            XCTAssertEqual(outputPixels[idx + 2], expectedB, accuracy: 2)
                        }
                    }
                }

                if colorMode == .duotone {
                    for y in 0..<height {
                        for x in 0..<width {
                            let idx = (y * width + x) * 4
                            XCTAssertTrue(outputPixels[idx] <= 255)
                            XCTAssertTrue(outputPixels[idx + 1] <= 255)
                            XCTAssertTrue(outputPixels[idx + 2] <= 255)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 8. NDI Stub

    func test8NDIStub() {
        guard let ctx = MetalContext() else { XCTFail("No MetalContext"); return }

        let broadcaster = makeNDIBroadcaster(ctx: ctx)
        XCTAssertTrue(broadcaster is NDIStub, "Simulator should use NDIStub")

        broadcaster.start(name: "Test", width: 640, height: 360)

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 640, height: 360, mipmapped: false)
        let tex = ctx.device.makeTexture(descriptor: desc)!
        broadcaster.consume(texture: tex, time: .zero)

        broadcaster.stop()

        let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "NDIlib_initialize")
        XCTAssertNil(sym, "NDI symbols should not be linked")
    }

    // MARK: - 9. MJPEG Server

    func test9MJPEGServer() {
        guard let ctx = MetalContext() else { XCTFail("No MetalContext"); return }
        let server = MJPEGServer(ctx: ctx)

        let testPort = findRandomAvailablePort()
        server.port = testPort

        server.start()
        XCTAssertTrue(server.isRunning)

        let expectation = self.expectation(description: "MJPEG chunk boundary")
        var headerValid = false
        var boundaryArrived = false

        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: server.port)!, using: .tcp)
        
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                let request = "GET /?token=\(server.sessionToken) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
                connection.send(content: request.data(using: .utf8), completion: .contentProcessed { _ in })
            }
        }

        func receiveNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let data = data, !data.isEmpty {
                    let str = String(data: data, encoding: .utf8) ?? ""
                    if str.contains("multipart/x-mixed-replace") {
                        headerValid = true
                    }
                    if str.contains("moshframe") || str.contains("image/jpeg") {
                        boundaryArrived = true
                        expectation.fulfill()
                        return
                    }
                    receiveNext()
                }
            }
        }

        connection.start(queue: .global(qos: .userInitiated))
        receiveNext()

        // Feed frames to the server
        let width = 640
        let height = 360
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        let tex = ctx.device.makeTexture(descriptor: desc)!

        let start = Date()
        var frameIndex = 0
        while Date().timeIntervalSince(start) < 4.0 && !boundaryArrived {
            server.consume(texture: tex, time: CMTime(value: CMTimeValue(frameIndex), timescale: 60))
            frameIndex += 1
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }

        waitForExpectations(timeout: 5.0)
        connection.cancel()

        XCTAssertTrue(headerValid, "Content-Type mismatch")
        XCTAssertTrue(boundaryArrived, "No JPEG boundary arrived")

        server.stop()
        XCTAssertFalse(server.isRunning)

        do {
            let _ = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: server.port)!)
        } catch {
            XCTFail("Port not released: \(error)")
        }
    }

    // MARK: - 10. Memory/Leak Check

    func test10MemoryLeakCheck() throws {
        self.executionTimeAllowance = 30
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "Headless Metal device not available")
        guard let ctx = MetalContext() else { XCTFail("No MetalContext"); return }
        let store = ParameterStore()
        let engine = MoshEngine(ctx: ctx, params: store)
        let finisher = FinisherPass(ctx: ctx, params: store)

        store.set(.mode, Float(MoshMode.classicSmear.rawValue))
        store.set(.mirrorMode, Float(MirrorMode.horizontal.rawValue))
        store.set(.colorMode, Float(ColorMode.invert.rawValue))

        let initialMem = getMemoryUsage()

        for frame in 0..<300 {
            autoreleasepool {
                var pb: CVPixelBuffer?
                CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32BGRA, [
                    kCVPixelBufferMetalCompatibilityKey as String: true
                ] as CFDictionary, &pb)
                guard let pixelBuffer = pb else { return }

                let ingestor = TextureIngestor(device: ctx.device)
                let sourceTex = ingestor.texture(from: pixelBuffer)!

                let cb = ctx.queue.makeCommandBuffer()!
                let moshTex = engine.encodeFrame(commandBuffer: cb, sourceA: sourceTex, sourceB: nil, now: Double(frame) / 30.0)
                _ = finisher.encode(commandBuffer: cb, input: moshTex ?? sourceTex)

                let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 640, height: 360, mipmapped: false)
                desc.usage = [.shaderRead, .shaderWrite]
                let destTex = ctx.device.makeTexture(descriptor: desc)!

                let enc = cb.makeComputeCommandEncoder()!
                enc.label = "blit"
                ctx.dispatch(enc, "blitScale", width: destTex.width, height: destTex.height)
                enc.endEncoding()

                cb.commit()
                cb.waitUntilCompleted()
            }
        }

        let finalMem = getMemoryUsage()
        let diffMem = finalMem - initialMem
        XCTAssertLessThanOrEqual(diffMem, 10 * 1024 * 1024, "Memory leak: footprint grew by \(diffMem / 1024 / 1024)MB")
    }
}

// MARK: - Mock Failed Player Item for DRM Simulation

class MockFailedPlayerItem: AVPlayerItem {
    var mockStatus: AVPlayerItem.Status = .unknown
    let mockError: Error
    init(url: URL, error: Error) {
        self.mockError = error
        super.init(asset: AVAsset(url: url), automaticallyLoadedAssetKeys: nil)
    }
    override var status: AVPlayerItem.Status {
        return mockStatus
    }
    override var error: Error? {
        return mockError
    }
}
