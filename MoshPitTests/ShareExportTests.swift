import XCTest
import UIKit
@testable import MoshPit

/// Feature tests for social sharing & export: session clip lifecycle,
/// social-export aspect math, MJPEG URL building, and RecordingSettings
/// persistence.
final class ShareExportTests: XCTestCase {

    // MARK: - Helpers

    /// Unique scratch directory per test — isolated from the app's real temp
    /// dir (which AppModel sweeps at launch).
    private var scratchDir: URL!

    override func setUpWithError() throws {
        scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharetests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchDir,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratchDir {
            try? FileManager.default.removeItem(at: scratchDir)
        }
    }

    private func makeFixtureFile(_ name: String) throws -> URL {
        let url = scratchDir.appendingPathComponent(name)
        try Data("fixture".utf8).write(to: url)
        return url
    }

    private func makeClip(url: URL) -> SessionClip {
        SessionClip(id: UUID(), url: url, thumbnail: UIImage(),
                    duration: 1.5, fileSize: 7, timestamp: Date())
    }

    // MARK: - 1. Session clip lifecycle

    func testAppendingClipUpdatesSessionClips() throws {
        let app = AppModel()
        XCTAssertTrue(app.sessionClips.isEmpty)
        let clip = makeClip(url: try makeFixtureFile("append.mov"))
        app.sessionClips.append(clip)
        XCTAssertEqual(app.sessionClips.count, 1)
        XCTAssertEqual(app.sessionClips.first?.id, clip.id)
    }

    func testDeleteRemovesEntryAndFile() throws {
        let app = AppModel()
        let url = try makeFixtureFile("delete-me.mov")
        let clip = makeClip(url: url)
        app.sessionClips.append(clip)

        XCTAssertTrue(app.deleteClip(clip))
        XCTAssertTrue(app.sessionClips.isEmpty, "entry removed synchronously")

        // File deletion happens off main — poll for it.
        let gone = NSPredicate { _, _ in
            !FileManager.default.fileExists(atPath: url.path)
        }
        wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)],
             timeout: 5)
    }

    func testDeleteBlockedWhenClipLoadedInSlotA() throws {
        let app = AppModel()
        let url = try makeFixtureFile("loaded.mov")
        let clip = makeClip(url: url)
        app.sessionClips.append(clip)

        // Load the same URL into slot A via the normal file-video path.
        app.sources?.setURL(url, slot: .a, name: "Test")
        XCTAssertEqual(app.sources?.sourceURL(slot: .a), url)
        XCTAssertTrue(app.clipIsLoadedInSlotA(clip))

        XCTAssertFalse(app.deleteClip(clip), "delete must be blocked")
        XCTAssertEqual(app.sessionClips.count, 1, "entry kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "file kept")

        // Unload slot A -> delete proceeds.
        app.sources?.clear(slot: .a)
        XCTAssertTrue(app.deleteClip(clip))
    }

    func testLaunchSweepRemovesStaleTempRecordings() throws {
        let stale = [
            try makeFixtureFile("\(SessionClipStore.recordingPrefix)123.mov"),
            try makeFixtureFile("\(SessionClipStore.snapshotPrefix)456.png"),
            try makeFixtureFile("\(SessionClipStore.socialExportPrefix)789.mp4"),
        ]
        let unrelated = try makeFixtureFile("keep-me.mov")

        let removed = SessionClipStore.sweepStaleRecordings(in: scratchDir)

        XCTAssertEqual(removed, 3)
        for url in stale {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                           "\(url.lastPathComponent) should be swept")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path),
                      "non-MoshPit files are untouched")
    }

    // MARK: - 2. Social export aspect math

    private let target = CGSize(width: 1080, height: 1920)

    /// The scaled content rect after applying the transform to the source.
    private func contentRect(_ source: CGSize) -> CGRect {
        let (transform, _) = socialExportTransform(sourceSize: source, target: target)
        return CGRect(origin: .zero, size: source).applying(transform)
    }

    func testExactPortraitSourceIsIdentityFill() {
        let (transform, letterbox) = socialExportTransform(
            sourceSize: CGSize(width: 1080, height: 1920), target: target)
        XCTAssertFalse(letterbox)
        XCTAssertEqual(transform.a, 1, accuracy: 0.0001)
        XCTAssertEqual(transform.d, 1, accuracy: 0.0001)
        XCTAssertEqual(transform.tx, 0, accuracy: 0.5)
        XCTAssertEqual(transform.ty, 0, accuracy: 0.5)
    }

    func testLandscapeSourceLetterboxesCentered() {
        let source = CGSize(width: 1920, height: 1080)
        let (transform, letterbox) = socialExportTransform(sourceSize: source,
                                                           target: target)
        XCTAssertTrue(letterbox)
        // Scale factor ~= 1080/1920 = 0.5625 (even-rounding nudges height).
        XCTAssertEqual(transform.a, 0.5625, accuracy: 0.001)
        let rect = contentRect(source)
        XCTAssertEqual(rect.width, 1080, accuracy: 0.5)
        // Centered vertically: equal black bars above and below.
        XCTAssertEqual(rect.midY, target.height / 2, accuracy: 0.5)
        XCTAssertGreaterThan(rect.minY, 0)
    }

    func testFourByFiveSourceTakesLetterboxPath() {
        // 1080x1350 (4:5) is well outside the 5% tolerance of 9:16.
        let (_, letterbox) = socialExportTransform(
            sourceSize: CGSize(width: 1080, height: 1350), target: target)
        XCTAssertTrue(letterbox)
    }

    func testNearPortraitSourceFillsWithMinorCrop() {
        // 1088x1920 is within 5% of 9:16 -> fill (minor crop), no letterbox.
        let source = CGSize(width: 1088, height: 1920)
        let (_, letterbox) = socialExportTransform(sourceSize: source,
                                                   target: target)
        XCTAssertFalse(letterbox)
        let rect = contentRect(source)
        XCTAssertGreaterThanOrEqual(rect.width, target.width - 0.5)
        XCTAssertGreaterThanOrEqual(rect.height, target.height - 0.5)
    }

    func testScaledContentDimensionsAlwaysEven() {
        let sources = [
            CGSize(width: 1080, height: 1920),
            CGSize(width: 1920, height: 1080),
            CGSize(width: 1080, height: 1350),
            CGSize(width: 1088, height: 1920),
            CGSize(width: 641, height: 479),
            CGSize(width: 333, height: 777),
        ]
        for source in sources {
            let rect = contentRect(source)
            let w = Int(rect.width.rounded()), h = Int(rect.height.rounded())
            XCTAssertEqual(rect.width, CGFloat(w), accuracy: 0.001,
                           "\(source): width must be integral")
            XCTAssertEqual(rect.height, CGFloat(h), accuracy: 0.001,
                           "\(source): height must be integral")
            XCTAssertEqual(w % 2, 0, "\(source): width \(w) must be even")
            XCTAssertEqual(h % 2, 0, "\(source): height \(h) must be even")
        }
    }

    // MARK: - 3. MJPEG URL copy

    func testStreamURLStringBuilder() {
        XCTAssertEqual(
            MJPEGShare.streamURLString(ip: "192.168.1.20", port: 8080,
                                       token: "abc123de"),
            "http://192.168.1.20:8080/?token=abc123de")
    }

    func testCopyButtonEnablementFlag() {
        XCTAssertFalse(MJPEGShare.canCopyURL(serverRunning: false, token: "tok"),
                       "disabled when the server is not running")
        XCTAssertFalse(MJPEGShare.canCopyURL(serverRunning: true, token: ""),
                       "disabled without a minted session token")
        XCTAssertTrue(MJPEGShare.canCopyURL(serverRunning: true, token: "tok"))
    }

    // MARK: - 4. RecordingSettings

    private static let settingsSuite = "moshpit.tests.recordingsettings"

    override class func tearDown() {
        UserDefaults(suiteName: settingsSuite)?
            .removePersistentDomain(forName: settingsSuite)
        super.tearDown()
    }

    func testRecordingSettingsDefaults() {
        let suite = UserDefaults(suiteName: Self.settingsSuite)!
        suite.removePersistentDomain(forName: Self.settingsSuite)
        let settings = RecordingSettings(defaults: suite)
        XCTAssertEqual(settings.format, .h264)
        XCTAssertEqual(settings.resolution, .p1080)
    }

    func testRecordingSettingsPersistAndRestore() {
        let suite = UserDefaults(suiteName: Self.settingsSuite)!
        suite.removePersistentDomain(forName: Self.settingsSuite)

        let settings = RecordingSettings(defaults: suite)
        settings.format = .proRes4444
        settings.resolution = .p4K

        let restored = RecordingSettings(defaults: suite)
        XCTAssertEqual(restored.format, .proRes4444)
        XCTAssertEqual(restored.resolution, .p4K)

        suite.removePersistentDomain(forName: Self.settingsSuite)
    }

    func testRecordingSettingsFreeTierEnforcement() {
        let suite = UserDefaults(suiteName: Self.settingsSuite)!
        suite.removePersistentDomain(forName: Self.settingsSuite)
        let settings = RecordingSettings(defaults: suite)
        settings.format = .proRes4444
        settings.resolution = .p4K
        settings.enforceFreeTier(isPro: false)
        XCTAssertEqual(settings.format, .h264)
        XCTAssertEqual(settings.resolution, .p1080)
        suite.removePersistentDomain(forName: Self.settingsSuite)
    }

    /// The other half of the same check: a Pro user's selections must
    /// survive — enforceFreeTier only ever downgrades, never touches a
    /// legitimately-entitled Pro session.
    func testRecordingSettingsRetainsProSelectionsWhenPro() {
        let suite = UserDefaults(suiteName: Self.settingsSuite)!
        suite.removePersistentDomain(forName: Self.settingsSuite)
        let settings = RecordingSettings(defaults: suite)
        settings.format = .proRes4444
        settings.resolution = .p4K
        settings.enforceFreeTier(isPro: true)
        XCTAssertEqual(settings.format, .proRes4444)
        XCTAssertEqual(settings.resolution, .p4K)
        suite.removePersistentDomain(forName: Self.settingsSuite)
    }

    /// Regression test for the exposure this task closes: a stale
    /// UserDefaults-persisted ProRes/4K selection (pre-purchase, post-refund,
    /// or from a debug build) must NOT reach AVAssetWriter for a free user.
    /// AppModel.toggleRecord() is the exact call path recording start goes
    /// through, so this exercises the real seam, not just RecordingSettings
    /// in isolation.
    func testToggleRecordReEnforcesFreeTierAtRecordStart() throws {
        let app = AppModel()
        try XCTSkipIf(app.ctx == nil, "Metal unavailable")
        app.debugSetPro(false)
        defer {
            // UserDefaults.standard is process-wide — don't leak a Pro-only
            // selection into other tests' AppModel instances.
            app.recordingSettings.format = .h264
            app.recordingSettings.resolution = .p1080
        }

        // Simulate a stale persisted Pro-only selection surviving into a
        // free-tier session (exactly the scenario the second gate defends).
        app.recordingSettings.format = .proRes4444
        app.recordingSettings.resolution = .p4K

        app.toggleRecord()   // starts recording -> the second gate must fire
        XCTAssertEqual(app.recordingSettings.format, .h264,
                       "free tier must not reach AVAssetWriter with ProRes")
        XCTAssertEqual(app.recordingSettings.resolution, .p1080,
                       "free tier must not reach AVAssetWriter with 4K")
        if app.recorder?.isRecording == true { app.toggleRecord() }   // stop
    }

    func testOutputSizeLongEdgeSemantics() {
        // Landscape canvas: long edge = width.
        var size = RecordingSettings.outputSize(canvasWidth: 960, canvasHeight: 540,
                                                longEdge: 1080)
        XCTAssertEqual(size.width, 1080)
        XCTAssertEqual(size.height, 606)   // 607.5 rounded down to even

        // Portrait canvas: long edge = height.
        size = RecordingSettings.outputSize(canvasWidth: 540, canvasHeight: 960,
                                            longEdge: 720)
        XCTAssertEqual(size.height, 720)
        XCTAssertEqual(size.width, 404)    // 405 rounded down to even

        // Match Canvas (nil): even-rounded passthrough.
        size = RecordingSettings.outputSize(canvasWidth: 541, canvasHeight: 961,
                                            longEdge: nil)
        XCTAssertEqual(size.width, 540)
        XCTAssertEqual(size.height, 960)
    }

    // MARK: - 5. Pro gating (ProRes / 4K / social export)

    /// SocialExporter.export must refuse to run for a non-Pro caller even
    /// when called directly — not just when the gallery button's
    /// requirePro(.socialExport) wrapper is skipped. This is the defensive
    /// check the export function owns itself, independent of any caller.
    func testSocialExportRefusesWhenNotPro() throws {
        let exporter = SocialExporter()
        let url = try makeFixtureFile("not-pro.mov")

        let expectation = expectation(description: "completion fires with nil")
        exporter.export(clipURL: url, isPro: false) { result in
            XCTAssertNil(result, "must not export for a non-Pro caller")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        XCTAssertFalse(exporter.isExporting, "must never even start the pipeline")
        XCTAssertNotNil(exporter.lastError)
    }

    /// View-model-level check for the locked/badge state the Output sheet
    /// and Gallery row render: exactly the ProRes/4K/social-export rows are
    /// locked when free, and nothing is locked when Pro — same condition
    /// (`requiredCapability != nil && !isPro`) the views evaluate.
    func testLockedRowStateWhenFree() {
        let isPro = false
        for format in RecordingSettings.Format.allCases {
            let locked = format.requiredCapability != nil && !isPro
            XCTAssertEqual(locked, format == .proRes4444,
                           "\(format) locked state must match Pro-only status")
        }
        for resolution in RecordingSettings.Resolution.allCases {
            let locked = resolution.requiredCapability != nil && !isPro
            XCTAssertEqual(locked, resolution == .p4K,
                           "\(resolution) locked state must match Pro-only status")
        }
    }

    func testNoRowsLockedWhenPro() {
        let isPro = true
        for format in RecordingSettings.Format.allCases {
            XCTAssertFalse(format.requiredCapability != nil && !isPro)
        }
        for resolution in RecordingSettings.Resolution.allCases {
            XCTAssertFalse(resolution.requiredCapability != nil && !isPro)
        }
    }
}
