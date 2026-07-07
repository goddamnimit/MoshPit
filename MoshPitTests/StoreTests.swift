import XCTest
import StoreKit
import StoreKitTest
@testable import MoshPit

/// Freemium model tests: pure capability/gating logic (no StoreKit), plus
/// end-to-end purchase/refund/restore against an SKTestSession driven by the
/// MoshPit.storekit configuration file.
@MainActor
final class StoreTests: XCTestCase {

    // MARK: - Pure unit tests (no StoreKit)

    func testEveryProModeMapsToACapability() {
        for mode in MoshMode.allCases {
            switch mode {
            case .clean, .classicSmear, .bloom:
                XCTAssertNil(mode.requiredCapability, "\(mode) is free")
            default:
                XCTAssertNotNil(mode.requiredCapability, "\(mode) must be Pro-gated")
            }
        }
    }

    func testAllowsReflectsEntitlement() {
        let free = ProManager(debugOverrideIsPro: false)
        let pro = ProManager(debugOverrideIsPro: true)
        for capability in Capability.allCases {
            XCTAssertFalse(free.allows(capability), "free tier must not allow \(capability)")
            XCTAssertTrue(pro.allows(capability), "pro must allow \(capability)")
        }
    }

    func testSlotAndParamCapabilityMapping() {
        XCTAssertNil(SourceSlot.a.requiredCapability)
        XCTAssertEqual(SourceSlot.b.requiredCapability, .sourceSlotB)
        XCTAssertEqual(SourceSlot.mod.requiredCapability, .sourceSlotMOD)
        XCTAssertEqual(ParameterID.lfo1Rate.requiredCapability, .lfo)
        XCTAssertEqual(ParameterID.trace3D.requiredCapability, .geometry3D)
        XCTAssertEqual(ParameterID.mirrorMode.requiredCapability, .mirrorModes)
        XCTAssertEqual(ParameterID.colorMode.requiredCapability, .colorModes)
        XCTAssertNil(ParameterID.bpm.requiredCapability, "tap tempo stays free")
        XCTAssertNil(ParameterID.flickerLimit.requiredCapability, "safety cap stays free")
    }

    func testParameterStoreRejectsGatedWritesWhenFree() {
        let app = AppModel()
        app.debugSetPro(false)

        // Gated param: silent no-op from any non-system origin.
        app.params.set(.lfo1Depth, 0.25, origin: .ui)
        XCTAssertEqual(app.params.get(.lfo1Depth), ParameterID.lfo1Depth.defaultValue)
        app.params.set(.trace3D, 1, origin: .midi)
        XCTAssertEqual(app.params.get(.trace3D), 0)

        // Pro mode selection: mode must NOT change.
        app.params.set(.mode, Float(MoshMode.feedback.rawValue), origin: .ui)
        XCTAssertNotEqual(app.params.mode, .feedback)

        // Free mode selection still works.
        app.params.set(.mode, Float(MoshMode.bloom.rawValue), origin: .ui)
        XCTAssertEqual(app.params.mode, .bloom)

        // Free params unaffected by the gate.
        app.params.set(.bloomRate, 3, origin: .ui)
        XCTAssertEqual(app.params.get(.bloomRate), 3)

        // .system origin bypasses (enforceFreeTierState must be able to snap).
        app.params.set(.trace3D, 1, origin: .system)
        XCTAssertEqual(app.params.get(.trace3D), 1)
        app.params.set(.trace3D, 0, origin: .system)
    }

    func testParameterStoreAcceptsGatedWritesWhenPro() {
        let app = AppModel()
        app.debugSetPro(true)
        app.params.set(.lfo1Depth, 0.25, origin: .ui)
        XCTAssertEqual(app.params.get(.lfo1Depth), 0.25)
        app.params.set(.mode, Float(MoshMode.feedback.rawValue), origin: .ui)
        XCTAssertEqual(app.params.mode, .feedback)
        // Restore defaults for other tests sharing the process.
        app.params.set(.lfo1Depth, ParameterID.lfo1Depth.defaultValue, origin: .system)
        app.params.set(.mode, 0, origin: .system)
    }

    func testEnforceFreeTierStateSnapsProState() throws {
        let app = AppModel()
        try XCTSkipIf(app.ctx == nil, "Metal unavailable")
        app.debugSetPro(true)

        app.params.set(.mode, Float(MoshMode.crossMosh.rawValue), origin: .ui)
        app.params.set(.trace3D, 1, origin: .ui)
        app.params.set(.mirrorMode, 2, origin: .ui)
        app.params.set(.colorMode, 1, origin: .ui)
        app.params.set(.lfo1Depth, 0.5, origin: .ui)
        app.sources?.setTestPattern(slot: .b)
        app.sources?.setTestPattern(slot: .mod)

        app.debugSetPro(false)
        app.enforceFreeTierState()

        XCTAssertEqual(app.params.mode, .bloom, "Pro mode snaps back to Bloom")
        XCTAssertEqual(app.params.get(.trace3D), 0)
        XCTAssertEqual(app.params.get(.mirrorMode), 0)
        XCTAssertEqual(app.params.get(.colorMode), 0)
        XCTAssertEqual(app.params.get(.lfo1Depth), ParameterID.lfo1Depth.defaultValue)
        // sources dict is cleared synchronously (names update async on main).
        XCTAssertNil(app.sources?.texture(for: .b), "slot B detached")
        XCTAssertNil(app.sources?.texture(for: .mod), "slot MOD detached")
        XCTAssertNotEqual(app.ndi?.isSending, true)
        XCTAssertNotEqual(app.mjpeg?.isRunning, true)
    }

    func testWatermarkLatchSurvivesEntitlementFlip() throws {
        guard let ctx = MetalContext() else { throw XCTSkip("Metal unavailable") }
        let recorder = MoshRecorder(ctx: ctx)
        recorder.start(width: 64, height: 64, watermark: true)
        XCTAssertTrue(recorder.watermarkLatched)
        // A purchase completing mid-recording must not change the latch —
        // it is only ever written at start().
        recorder.start(width: 64, height: 64, watermark: false)   // no-op: already recording
        XCTAssertTrue(recorder.watermarkLatched, "latch immutable while recording")
        recorder.stop()
        recorder.start(width: 64, height: 64, watermark: false)
        XCTAssertFalse(recorder.watermarkLatched, "next artifact re-latches at start")
        recorder.stop()
    }

    // MARK: - StoreKit 2 end-to-end (SKTestSession + MoshPit.storekit)

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

    private func waitUntil(timeout: TimeInterval = 10,
                           _ condition: @MainActor () -> Bool) async {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func testPurchaseFlowEndToEnd() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }

        let manager = ProManager(debugOverrideIsPro: nil)   // live StoreKit
        await manager.loadProduct()
        try XCTSkipIf(manager.product == nil,
                      "StoreKit test configuration not reachable in this environment")

        XCTAssertFalse(manager.isPro)
        await manager.purchase()
        XCTAssertTrue(manager.isPro, "verified purchase must entitle")
        XCTAssertEqual(manager.purchaseState, .idle)
    }

    func testRefundRevokesEntitlement() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }

        let manager = ProManager(debugOverrideIsPro: nil)
        await manager.loadProduct()
        try XCTSkipIf(manager.product == nil,
                      "StoreKit test configuration not reachable in this environment")

        await manager.purchase()
        XCTAssertTrue(manager.isPro)

        // Simulate an App Store refund; Transaction.updates should revoke.
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

        let manager = ProManager(debugOverrideIsPro: nil)
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

        let manager = ProManager(debugOverrideIsPro: nil)
        await manager.loadProduct()
        try XCTSkipIf(manager.product == nil,
                      "StoreKit test configuration not reachable in this environment")

        await manager.purchase()
        XCTAssertTrue(manager.isPro)

        // A second manager starts cold and recovers the entitlement via
        // restore (AppStore.sync + currentEntitlements).
        let fresh = ProManager(debugOverrideIsPro: nil)
        await fresh.restore()
        XCTAssertTrue(fresh.isPro, "restore must recover a prior purchase")
        XCTAssertEqual(fresh.purchaseState, .idle)
    }
}
