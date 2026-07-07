import XCTest
import Combine
import AVFoundation
@testable import MoshPit

final class ParameterStoreTests: XCTestCase {
    func testDefaultsAndClamping() {
        let store = ParameterStore()
        XCTAssertEqual(store.get(.mixAmount), ParameterID.mixAmount.defaultValue)
        store.set(.mixAmount, 99)
        XCTAssertEqual(store.get(.mixAmount), 1)     // clamped to range
        store.set(.driftX, -99)
        XCTAssertEqual(store.get(.driftX), -1)
    }

    func testNormalizedRoundTrip() {
        let store = ParameterStore()
        store.setNormalized(.bloomRate, 0.5, origin: .midi)
        XCTAssertEqual(store.getNormalized(.bloomRate), 0.5, accuracy: 1e-5)
        let r = ParameterID.bloomRate.range
        XCTAssertEqual(store.get(.bloomRate),
                       r.lowerBound + 0.5 * (r.upperBound - r.lowerBound),
                       accuracy: 1e-4)
    }

    func testChangePublisherCarriesOrigin() {
        let store = ParameterStore()
        let exp = expectation(description: "change")
        var received: ParameterChange?
        let c = store.changes.sink { received = $0; exp.fulfill() }
        store.set(.heal, 0.01, origin: .midi)
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(received?.id, .heal)
        XCTAssertEqual(received?.origin, .midi)
        XCTAssertEqual(received?.value ?? 0, 0.01, accuracy: 1e-6)
        c.cancel()
    }

    func testThreadedWritesDontCrashAndLandInRange() {
        let store = ParameterStore()
        DispatchQueue.concurrentPerform(iterations: 2000) { i in
            store.set(.motionGain, Float(i % 50) / 10.0, origin: .videoMod)
            _ = store.get(.motionGain)
        }
        XCTAssertTrue(ParameterID.motionGain.range.contains(store.get(.motionGain)))
    }

    func testCameraDefaultOnLaunch() {
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        let app = AppModel()
        guard let sources = app.sources else {
            XCTFail("SourceManager is nil")
            return
        }
        
        let exp = expectation(description: "names populated")
        DispatchQueue.main.async {
            if auth == .authorized || auth == .notDetermined {
                XCTAssertTrue(sources.names[.a]?.contains("Camera") ?? false, "Default source on launch should be camera when authorized/notDetermined, got: \(String(describing: sources.names[.a]))")
            } else {
                XCTAssertTrue(sources.names[.a]?.contains("Pattern") ?? false, "Default source on launch should be test pattern when denied/restricted, got: \(String(describing: sources.names[.a]))")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }
}
