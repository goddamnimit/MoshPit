import Foundation
import StoreKit

// MARK: - ProManager (StoreKit 2)

/// Single source of truth for the MoshPit Pro entitlement.
///
/// StoreKit 2 only: `Transaction.currentEntitlements` (locally cached signed
/// transactions, works offline) is the source of truth — no receipts leave the
/// device, no server, no analytics. A UserDefaults mirror exists purely to
/// avoid a one-frame flash of locked UI at launch; it is reconciled against
/// `currentEntitlements` immediately.
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

    @Published private(set) var isPro: Bool
    @Published private(set) var product: Product?
    @Published private(set) var purchaseState: PurchaseState = .idle

    /// Lock-free mirror of `isPro` readable from the render/MIDI threads
    /// (the ParameterStore write gate). Written only alongside `isPro`.
    nonisolated(unsafe) private(set) var isProUnsafe: Bool

    private var updatesTask: Task<Void, Never>?
    private static let cacheKey = "moshpit.pro.lastKnown"

    private init() {
        #if DEBUG
        // Unit tests: default to Pro so feature gates never interfere with
        // unrelated suites. StoreTests build their own instances via
        // init(debugOverrideIsPro:) to exercise free/pro/live states.
        if NSClassFromString("XCTestCase") != nil {
            isPro = true
            isProUnsafe = true
            return
        }
        #endif
        // Launch-flash cache only — reconciled below, never trusted alone.
        let cached = UserDefaults.standard.bool(forKey: Self.cacheKey)
        isPro = cached
        isProUnsafe = cached
        startStoreKit()
    }

    #if DEBUG
    /// Tests & previews: force an entitlement state without touching StoreKit
    /// (pass nil to run the live StoreKit path, e.g. under SKTestSession).
    init(debugOverrideIsPro: Bool?) {
        if let forced = debugOverrideIsPro {
            isPro = forced
            isProUnsafe = forced
        } else {
            isPro = false
            isProUnsafe = false
            startStoreKit()
        }
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
            setPro(transaction.revocationDate == nil)
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
        setPro(pro)
    }

    private func setPro(_ pro: Bool) {
        isProUnsafe = pro
        if isPro != pro { isPro = pro }
        UserDefaults.standard.set(pro, forKey: Self.cacheKey)
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
                setPro(transaction.revocationDate == nil)
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
        purchaseState = isPro ? .idle : .info("No previous purchase found.")
    }
}
