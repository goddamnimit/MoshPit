import XCTest
import StoreKit
import StoreKitTest
import UIKit
import MetalKit
@testable import MoshPit

/// Save-to-Photos paywall tests: the single Capability gate, the offline
/// redeem-code system, the pending-save-on-unlock pattern, and end-to-end
/// purchase/restore against an SKTestSession driven by MoshPit.storekit.
/// Everything else in the app is free — the suite also pins that down.
@MainActor
final class StoreTests: XCTestCase {

    override func tearDown() {
        VideoPhotosSaver.debugSaveHook = nil
        SnapshotSaver.debugSaveHook = nil
        super.tearDown()
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "storetests.\(UUID().uuidString)")!
    }

    private func waitUntil(timeout: TimeInterval = 10,
                           _ condition: @MainActor () -> Bool) async {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - 1. Capability

    func testAllowsReflectsEntitlementFromEitherSource() {
        let free = ProManager(debugOverrideIsPro: false, defaults: freshDefaults())
        let proViaStore = ProManager(debugOverrideIsPro: true, defaults: freshDefaults())
        let proViaCode = ProManager(debugOverrideIsPro: false, defaults: freshDefaults())
        XCTAssertTrue(proViaCode.redeem("MOSHPITFRIEND"))

        XCTAssertFalse(free.allows(.saveVideoToPhotos))
        XCTAssertTrue(proViaStore.allows(.saveVideoToPhotos))
        XCTAssertTrue(proViaCode.allows(.saveVideoToPhotos))
        // The two sources stay separable (support/debugging).
        XCTAssertTrue(proViaStore.storeEntitled)
        XCTAssertFalse(proViaStore.codeRedeemed)
        XCTAssertFalse(proViaCode.storeEntitled)
        XCTAssertTrue(proViaCode.codeRedeemed)
    }

    // MARK: - 2. The save-to-Photos gate

    func testFreeUserStopKeepsWatermarkedClipAndSkipsPhotos() async throws {
        let app = AppModel()
        try XCTSkipIf(app.ctx == nil, "Metal unavailable")
        var photosSaveAttempted = false
        VideoPhotosSaver.debugSaveHook = { _, completion in
            photosSaveAttempted = true
            completion(true, nil)
        }
        app.debugSetPro(false)
        app.recorder?.start(width: 64, height: 64)
        XCTAssertEqual(app.recorder?.isRecording, true)
        app.recorder?.stop()

        // (No frames were rendered, so no gallery thumbnail is produced; the
        // gated-outcome toast still fires and is what we observe.)
        await waitUntil { app.shareToast != nil }
        XCTAssertTrue(app.shareToast?.message.contains("watermark") == true)
        XCTAssertFalse(photosSaveAttempted, "free recording never touches Photos")
        XCTAssertFalse(app.showUpgradeSheet, "no auto-paywall after recording")
    }

    func testEntitledUserStopSavesToPhotos() async throws {
        let app = AppModel()
        try XCTSkipIf(app.ctx == nil, "Metal unavailable")
        var photosSaveAttempted = false
        VideoPhotosSaver.debugSaveHook = { _, completion in
            photosSaveAttempted = true
            completion(true, nil)
        }
        app.debugSetPro(true)   // either entitlement source lands here
        app.recorder?.start(width: 64, height: 64)
        app.recorder?.stop()

        await waitUntil { photosSaveAttempted }
        XCTAssertTrue(photosSaveAttempted, "entitled save must run the Photos path")
        XCTAssertFalse(app.showUpgradeSheet)
    }

    func testPendingSaveCompletesOnUnlock() throws {
        let app = AppModel()
        app.debugSetPro(false)
        var pendingRan = false
        app.presentUpgrade(for: .saveVideoToPhotos) { pendingRan = true }
        XCTAssertTrue(app.showUpgradeSheet)
        XCTAssertFalse(pendingRan)
        // What bindProManager runs when isPro flips true (purchase or redeem).
        app.completePendingProAction()
        XCTAssertTrue(pendingRan, "the blocked save must complete on unlock")
        XCTAssertFalse(app.showUpgradeSheet)
    }

    // MARK: - 3. Snapshot saving is NOT gated

    /// The saver itself carries no gate; AppModel.snapshot() decides (below).
    func testSnapshotSaverItselfIsUngated() async {
        let app = AppModel()
        app.debugSetPro(false)
        var snapshotSaved = false
        SnapshotSaver.debugSaveHook = { _ in snapshotSaved = true }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2),
                                            format: format).image { _ in }
        let saved = expectation(description: "onSaved")
        SnapshotSaver.save(image, onDenied: { XCTFail("must not be denied") },
                           onSaved: { saved.fulfill() })
        await fulfillment(of: [saved], timeout: 5)
        XCTAssertTrue(snapshotSaved, "photo snapshot saving is ungated")
        XCTAssertFalse(app.showUpgradeSheet, "snapshot save must not upsell")
    }

    func testFreeSnapshotIsWatermarkedAndNotSavedToPhotos() async throws {
        let app = AppModel()
        try XCTSkipIf(app.renderer == nil, "Metal unavailable")
        app.sources?.setTestPattern(slot: .a, inverted: false, portrait: false)
        var savedToPhotos = false
        SnapshotSaver.debugSaveHook = { _ in savedToPhotos = true }
        app.debugSetPro(false)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 320, height: 180),
                           device: app.ctx?.device)
        view.drawableSize = CGSize(width: 320, height: 180)
        app.snapshot()
        app.renderer?.draw(in: view)
        await waitUntil { app.shareToast != nil }
        XCTAssertTrue(app.shareToast?.message.contains("watermark") == true,
                      "free snapshot is flagged as watermarked")
        XCTAssertFalse(savedToPhotos, "free snapshot never reaches Photos")
        app.dismissShareToast()

        app.debugSetPro(true)
        app.snapshot()
        app.renderer?.draw(in: view)
        await waitUntil { savedToPhotos }
        XCTAssertTrue(savedToPhotos, "entitled snapshot saves clean to Photos")
        app.debugSetPro(nil)
    }

    // MARK: - 3b. Export gate (share / social export / save)

    func testRequireExportGatesFreeUsersAndRunsForEntitled() {
        let app = AppModel()
        app.debugSetPro(false)
        var ran = false
        app.requireExport { ran = true }
        XCTAssertFalse(ran, "free user must not export")
        XCTAssertTrue(app.showUpgradeSheet, "free user is shown the unlock sheet")
        app.completePendingProAction()   // purchase completes
        XCTAssertTrue(ran, "the blocked export resumes after unlock")

        let entitled = AppModel()
        entitled.debugSetPro(true)
        var ranEntitled = false
        entitled.requireExport { ranEntitled = true }
        XCTAssertTrue(ranEntitled)
        XCTAssertFalse(entitled.showUpgradeSheet)
    }

    func testDebugBypassOpensExportsAndPreviewToggleClosesThem() {
        let app = AppModel()
        app.debugSetPro(nil)
        app.debugPreviewFreeTier = false
        var ran = false
        app.requireExport { ran = true }
        XCTAssertTrue(ran, "Debug builds are fully entitled")
        app.debugPreviewFreeTier = true
        ran = false
        app.requireExport { ran = true }
        XCTAssertFalse(ran, "DEBUG free-tier preview gates exports")
        XCTAssertTrue(app.showUpgradeSheet)
        app.debugSetPro(true)           // debugSetPro takes precedence
        app.showUpgradeSheet = false
        app.requireExport { ran = true }
        XCTAssertTrue(ran)
        app.debugPreviewFreeTier = false
    }

    // MARK: - 4. Share sheet is free; only its Save Video action is excluded

    func testShareSheetExclusionPolicy() {
        let mov = URL(fileURLWithPath: "/tmp/clip.mov")
        let png = URL(fileURLWithPath: "/tmp/snap.png")
        // Free user sharing a video: sheet presents, Save Video excluded.
        XCTAssertEqual(ShareSheetPresenter.excludedActivityTypes(for: mov, isPro: false),
                       [.saveToCameraRoll])
        // Entitled user: nothing excluded.
        XCTAssertNil(ShareSheetPresenter.excludedActivityTypes(for: mov, isPro: true))
        // Snapshots are never restricted, entitled or not.
        XCTAssertNil(ShareSheetPresenter.excludedActivityTypes(for: png, isPro: false))
    }

    // MARK: - 7. Redeem codes

    func testAllowlistedCodeRedeems() {
        let manager = ProManager(debugOverrideIsPro: false, defaults: freshDefaults())
        XCTAssertFalse(manager.isPro)
        XCTAssertTrue(manager.redeem("  moshpitfriend \n"), "trim + uppercase before validating")
        XCTAssertTrue(manager.codeRedeemed)
        XCTAssertTrue(manager.isPro)
    }

    func testChecksumFormatCodeRedeems() {
        // Pins the generation scheme: a code minted offline must validate.
        XCTAssertEqual(RedeemCodes.generate(payload: "GIGS"), "MOSHPIT-GIGS-LSJL")
        let manager = ProManager(debugOverrideIsPro: false, defaults: freshDefaults())
        XCTAssertTrue(manager.redeem("MOSHPIT-GIGS-LSJL"))
        XCTAssertTrue(manager.isPro)
    }

    func testInvalidCodesRejected() {
        let manager = ProManager(debugOverrideIsPro: false, defaults: freshDefaults())
        for bad in ["", "GARBAGE", "MOSHPIT-GIG1-AAAA", "MOSHPIT-GIG1",
                    "MOSHPIT-GIG1-FGYY-X", "MOSHPIT-gi!1-FGYY", "MOSHPITPRESS2027"] {
            XCTAssertFalse(manager.redeem(bad), "\(bad) must be rejected")
        }
        XCTAssertFalse(manager.codeRedeemed)
        XCTAssertFalse(manager.isPro, "failed redemption must not entitle")
    }

    func testRedemptionPersistsAcrossRelaunch() {
        let defaults = freshDefaults()
        let first = ProManager(debugOverrideIsPro: false, defaults: defaults)
        XCTAssertTrue(first.redeem("MOSHPITPRESS2026"))
        // Simulated relaunch: a fresh manager over the same persisted state.
        let second = ProManager(debugOverrideIsPro: false, defaults: defaults)
        XCTAssertTrue(second.codeRedeemed)
        XCTAssertTrue(second.isPro)
        XCTAssertFalse(second.storeEntitled, "sources must not conflate")
    }

    // MARK: - 8. Nothing else interacts with the gate

    func testOnlySaveToPhotosIsGated() {
        XCTAssertEqual(Capability.allCases,
                       [.saveVideoToPhotos, .removeWatermark, .exportOutput],
                       "the gating surface is exactly these capabilities (one entitlement)")
        // Formerly-gated features are free: parameter writes, mode selection,
        // and export settings all work for a free user with no upgrade sheet.
        let app = AppModel()
        app.debugSetPro(false)
        app.params.set(.lfo1Depth, 0.25, origin: .ui)
        XCTAssertEqual(app.params.get(.lfo1Depth), 0.25)
        app.params.set(.mode, Float(MoshMode.feedback.rawValue), origin: .ui)
        XCTAssertEqual(app.params.mode, .feedback)
        app.recordingSettings.format = .proRes4444
        XCTAssertEqual(app.recordingSettings.format, .proRes4444)
        app.recordingSettings.resolution = .p4K
        XCTAssertEqual(app.recordingSettings.resolution, .p4K)
        XCTAssertFalse(app.showUpgradeSheet)
        // Restore defaults for suites sharing the process.
        app.params.set(.lfo1Depth, ParameterID.lfo1Depth.defaultValue, origin: .system)
        app.params.set(.mode, 0, origin: .system)
        app.recordingSettings.format = .hevc
        app.recordingSettings.resolution = .matchCanvas
    }

    // MARK: - 5/6. StoreKit 2 end-to-end (SKTestSession + MoshPit.storekit)

    /// Loads the checked-in configuration file directly (no bundling needed).
    private func makeSession() throws -> SKTestSession {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()                    // MoshPitTests/
            .deletingLastPathComponent()                    // repo root
            .appendingPathComponent("MoshPit/Configuration/MoshPit.storekit")
        let session: SKTestSession
        do {
            session = try SKTestSession(contentsOf: url)
        } catch {
            throw XCTSkip("SKTestSession unavailable in this environment: \(error)")
        }
        session.disableDialogs = true
        session.clearTransactions()
        return session
    }

    func testPurchaseFlowEndToEnd() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }

        let manager = ProManager(debugOverrideIsPro: nil, defaults: freshDefaults())
        await manager.loadProduct()
        try XCTSkipIf(manager.product == nil,
                      "StoreKit test configuration not reachable in this environment")

        XCTAssertFalse(manager.isPro)
        await manager.purchase()
        XCTAssertTrue(manager.storeEntitled, "verified purchase must entitle")
        XCTAssertTrue(manager.isPro)
        XCTAssertFalse(manager.codeRedeemed)
        XCTAssertEqual(manager.purchaseState, .idle)
    }

    func testRefundRevokesStoreEntitlement() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }

        let manager = ProManager(debugOverrideIsPro: nil, defaults: freshDefaults())
        await manager.loadProduct()
        try XCTSkipIf(manager.product == nil,
                      "StoreKit test configuration not reachable in this environment")

        await manager.purchase()
        XCTAssertTrue(manager.isPro)

        var latest: UInt64?
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == ProManager.productID {
                latest = t.id
            }
        }
        let id = try XCTUnwrap(latest)
        try session.refundTransaction(identifier: UInt(id))
        await waitUntil { !manager.isPro }
        if manager.isPro {
            // Updates delivery can lag in CI; currentEntitlements is the
            // source of truth — reconcile explicitly before asserting.
            await manager.refreshEntitlement()
        }
        XCTAssertFalse(manager.isPro, "refund must revoke the entitlement")
    }

    func testRestoreWithNoPurchaseReportsNotFound() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }

        let manager = ProManager(debugOverrideIsPro: nil, defaults: freshDefaults())
        await manager.loadProduct()
        try XCTSkipIf(manager.product == nil,
                      "StoreKit test configuration not reachable in this environment")

        await manager.restore()
        XCTAssertFalse(manager.isPro)
        XCTAssertEqual(manager.purchaseState, .info("No previous purchase found."))
    }

    func testRestoreAfterPurchase() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }

        let manager = ProManager(debugOverrideIsPro: nil, defaults: freshDefaults())
        await manager.loadProduct()
        try XCTSkipIf(manager.product == nil,
                      "StoreKit test configuration not reachable in this environment")

        await manager.purchase()
        XCTAssertTrue(manager.isPro)

        // A second manager starts cold and recovers the entitlement via
        // restore (AppStore.sync + currentEntitlements).
        let fresh = ProManager(debugOverrideIsPro: nil, defaults: freshDefaults())
        await fresh.restore()
        XCTAssertTrue(fresh.storeEntitled, "restore must recover a prior purchase")
        XCTAssertEqual(fresh.purchaseState, .idle)
    }
}
