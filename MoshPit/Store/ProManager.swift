import Foundation
import StoreKit

// MARK: - ProManager (StoreKit 2 + offline redeem codes)

/// Single source of truth for the MoshPit Pro entitlement (which now covers
/// exactly one thing: saving recorded videos to the Photos library).
///
/// Two independent entitlement sources, kept deliberately separable so it is
/// always possible to tell WHY a user is entitled (support/debugging):
///
/// - `storeEntitled` — StoreKit 2 only: `Transaction.currentEntitlements`
///   (locally cached signed transactions, works offline) is the source of
///   truth — no receipts leave the device, no server, no analytics. A
///   UserDefaults mirror exists purely to avoid a one-frame flash of locked
///   UI at launch; it is reconciled against `currentEntitlements` immediately.
/// - `codeRedeemed` — a locally persisted flag set by a valid offline redeem
///   code (see RedeemCodes). Plain UserDefaults, NOT StoreKit: a promotional
///   unlock is not a financial transaction and doesn't need the receipt
///   security model.
///
/// `isPro` = `storeEntitled || codeRedeemed`.
@MainActor
final class ProManager: ObservableObject {
    static let shared = ProManager()
    static let productID = "com.moshpit.app.pro"

    enum PurchaseState: Equatable {
        case idle
        case purchasing
        case restoring
        /// Non-error status (Ask to Buy pending, "no previous purchase found").
        case info(String)
        case failed(String)
    }

    enum StoreError: LocalizedError {
        case failedVerification
        var errorDescription: String? { "Purchase could not be verified by the App Store." }
    }

    /// Entitled via a verified App Store transaction.
    @Published private(set) var storeEntitled: Bool
    /// Entitled via an offline redeem code (persisted local flag).
    @Published private(set) var codeRedeemed: Bool
    /// The one flag the rest of the app reads: either source entitles.
    @Published private(set) var isPro: Bool
    @Published private(set) var product: Product?
    @Published private(set) var purchaseState: PurchaseState = .idle

    private var updatesTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private static let cacheKey = "moshpit.pro.lastKnown"
    private static let redeemKey = "moshpit.pro.codeRedeemed"

    private init() {
        defaults = .standard
        #if DEBUG
        // Unit tests: default the SHARED instance to Pro so the save gate
        // never interferes with unrelated suites. StoreTests build their own
        // instances via init(debugOverrideIsPro:) to exercise free/pro/live
        // states.
        if NSClassFromString("XCTestCase") != nil {
            storeEntitled = true
            codeRedeemed = false
            isPro = true
            return
        }
        #endif
        // Launch-flash cache only — reconciled below, never trusted alone.
        let cached = defaults.bool(forKey: Self.cacheKey)
        let redeemed = defaults.bool(forKey: Self.redeemKey)
        storeEntitled = cached
        codeRedeemed = redeemed
        isPro = cached || redeemed
        startStoreKit()
    }

    #if DEBUG
    /// Tests & previews: force the StoreKit entitlement state without
    /// touching StoreKit (pass nil to run the live StoreKit path, e.g. under
    /// SKTestSession). `defaults` is injectable so redeem-persistence tests
    /// can use an isolated suite.
    init(debugOverrideIsPro: Bool?, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let redeemed = defaults.bool(forKey: Self.redeemKey)
        let entitled = debugOverrideIsPro ?? false
        codeRedeemed = redeemed
        storeEntitled = entitled
        isPro = entitled || redeemed
        if debugOverrideIsPro == nil { startStoreKit() }
    }
    #endif

    deinit { updatesTask?.cancel() }

    private func startStoreKit() {
        // MANDATORY per StoreKit 2 docs: a long-lived Transaction.updates
        // listener handles purchases completed outside the app (Ask to Buy
        // approvals, purchase on another device, refunds). Every update is
        // verified and finished.
        updatesTask = Task.detached { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(update: result)
            }
        }
        Task { [weak self] in
            await self?.loadProduct()
            await self?.refreshEntitlement()
        }
    }

    private func handle(update result: VerificationResult<Transaction>) async {
        guard let transaction = try? verified(result) else { return }
        if transaction.productID == Self.productID {
            setStoreEntitled(transaction.revocationDate == nil)
        }
        await transaction.finish()
    }

    // MARK: Verification

    /// JWS signature check — the only thing that makes an entitlement
    /// trustworthy, in sandbox and production alike. Unverified results NEVER
    /// entitle.
    nonisolated func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let safe): return safe
        case .unverified: throw StoreError.failedVerification
        }
    }

    // MARK: Entitlement

    func refreshEntitlement() async {
        var pro = false
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? verified(result) else { continue }
            if transaction.productID == Self.productID, transaction.revocationDate == nil {
                pro = true
            }
        }
        setStoreEntitled(pro)
    }

    private func setStoreEntitled(_ entitled: Bool) {
        if storeEntitled != entitled { storeEntitled = entitled }
        defaults.set(entitled, forKey: Self.cacheKey)
        recomputeIsPro()
    }

    private func recomputeIsPro() {
        let pro = storeEntitled || codeRedeemed
        if isPro != pro { isPro = pro }
    }

    // MARK: Redeem codes (offline)

    /// Validates a user-entered code (see RedeemCodes for the scheme) and, if
    /// valid, persists the local unlock flag. Returns whether it was valid.
    @discardableResult
    func redeem(_ code: String) -> Bool {
        guard RedeemCodes.isValid(code) else { return false }
        codeRedeemed = true
        defaults.set(true, forKey: Self.redeemKey)
        recomputeIsPro()
        return true
    }

    func loadProduct() async {
        guard product == nil else { return }
        product = try? await Product.products(for: [Self.productID]).first
    }

    // MARK: Purchase

    func purchase() async {
        if product == nil { await loadProduct() }
        guard let product else {
            purchaseState = .failed("Can't reach the App Store right now. Please try again.")
            return
        }
        purchaseState = .purchasing
        do {
            switch try await product.purchase() {
            case .success(let verification):
                let transaction = try verified(verification)
                setStoreEntitled(transaction.revocationDate == nil)
                await transaction.finish()
                purchaseState = .idle
            case .userCancelled:
                purchaseState = .idle   // cancellation is not an error
            case .pending:
                purchaseState = .info("Purchase pending approval (Ask to Buy). Pro unlocks automatically once approved.")
            @unknown default:
                purchaseState = .idle
            }
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    // MARK: Restore

    func restore() async {
        purchaseState = .restoring
        try? await AppStore.sync()
        await refreshEntitlement()
        purchaseState = storeEntitled ? .idle : .info("No previous purchase found.")
    }
}
