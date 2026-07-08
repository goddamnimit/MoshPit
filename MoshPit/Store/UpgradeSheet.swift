import SwiftUI

/// The one upgrade surface. Presented through AppModel.presentUpgrade(for:)
/// so it respects the overlay mutual-exclusivity system. No dark patterns:
/// no timers, no fake urgency, no nagging — what's gated (only saving
/// recordings to Photos), one price button with the localized price, Restore,
/// and a plain Not Now.
///
/// v1 ships with NO redeem-code entry anywhere in the UI (App Store
/// Guideline 3.1.1: license-key-style unlocks outside IAP are a rejection
/// trigger). The RedeemCodes validation and ProManager.redeem(_:) plumbing
/// remain in the codebase, deliberately unreachable; restore the UI from git
/// history (RedeemCodeField, removed 2026-07-07) or adopt Apple Offer Codes
/// if promotional unlocks are ever wanted.
struct UpgradeSheet: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var pro = ProManager.shared
    @Environment(\.dismiss) private var dismiss

    private var busy: Bool {
        pro.purchaseState == .purchasing || pro.purchaseState == .restoring
    }

    var body: some View {
        VStack(spacing: Theme.g3) {
            Text("Save to Photos")
                .font(.title2.bold())
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, Theme.g4)

            VStack(alignment: .leading, spacing: Theme.g2) {
                benefitRow(icon: "square.and.arrow.down",
                           text: "Save your recordings straight to your Photos library")
                benefitRow(icon: "sparkles.tv",
                           text: "Full quality, direct from the canvas — no on-screen UI in the way")
                benefitRow(icon: "checkmark.seal",
                           text: "One-time purchase. Unlocks forever, on all your devices")
                Text("Everything else in MoshPit is free — every mode, effect, output, the session gallery, sharing, and snapshots stay unlocked.")
                    .font(Theme.labelSmall)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, Theme.g1)
            }
            .padding(.horizontal, Theme.g3)

            Spacer(minLength: 0)

            statusLine

            VStack(spacing: Theme.g1) {
                Button {
                    Task { await pro.purchase() }
                } label: {
                    Group {
                        if busy {
                            ProgressView().tint(Theme.textPrimary)
                        } else {
                            // Localized price from StoreKit — never hardcoded.
                            Text("Unlock — \(pro.product?.displayPrice ?? "…")")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(MoshButtonStyle(size: .large, selected: true, fillsWidth: true))
                .disabled(busy)

                Button("Restore Purchases") {
                    Task { await pro.restore() }
                }
                .font(Theme.label)
                .foregroundStyle(Theme.textSecondary)
                .frame(height: Theme.buttonStandard)
                .disabled(busy)

                Button("Not Now") { dismiss() }
                    .font(Theme.labelSmall)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(height: Theme.buttonSmall)
            }
            .padding(.horizontal, Theme.g3)
            .padding(.bottom, Theme.g3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.scrimBase)
        .preferredColorScheme(.dark)
        .onChange(of: pro.isPro) { _, isPro in
            if isPro { dismiss() }   // AppModel completes the pending action
        }
    }

    @ViewBuilder
    private func benefitRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.g1) {
            Image(systemName: icon)
                .font(Theme.label)
                .foregroundStyle(Theme.accent)
                .frame(width: Theme.g3)
            Text(text)
                .font(Theme.label)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch pro.purchaseState {
        case .failed(let message):
            Text(message)
                .font(Theme.labelSmall)
                .foregroundStyle(Theme.accent)   // Theme error/accent, inline — never an alert stack
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.g3)
        case .info(let message):
            Text(message)
                .font(Theme.labelSmall)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.g3)
        default:
            EmptyView()
        }
    }
}
