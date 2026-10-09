import SwiftUI

/// The one upgrade surface. Presented through AppModel.presentUpgrade(for:)
/// so it respects the overlay mutual-exclusivity system. No dark patterns:
/// no timers, no fake urgency, no nagging — what the unlock does (removes the
/// watermark on new recordings/snapshots, enables exporting), one price button
/// with the localized price, Restore, and a plain Not Now.
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
            Text("Remove the watermark and export your work")
                .font(.title2.bold())
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.top, Theme.g4)
                .padding(.horizontal, Theme.g3)

            beforeAfter

            VStack(alignment: .leading, spacing: Theme.g2) {
                benefitRow(icon: "drop.degreesign.slash",
                           text: "New recordings and snapshots come out clean, with no watermark")
                benefitRow(icon: "square.and.arrow.up",
                           text: "Share, save to Files or Photos, and export for social")
                benefitRow(icon: "checkmark.seal",
                           text: "One-time purchase — no subscription. Restore it any time")
                Text("Free forever: every mode and effect, recording, the session gallery, and live NDI / MJPEG output. Free recordings carry a small watermark and stay in the app until you unlock.")
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
                            Text(pro.product.map { "Unlock — \($0.displayPrice)" } ?? "Unlock")
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
        .task { await pro.loadProduct() }
        .onChange(of: pro.isPro) { _, isPro in
            if isPro { dismiss() }   // AppModel completes the pending action
        }
    }

    /// Schematic before/after built from Theme tokens (no assets): the same
    /// frame with and without the corner wordmark.
    private var beforeAfter: some View {
        HStack(spacing: Theme.g2) {
            sample(title: "Free", marked: true)
            sample(title: "Unlocked", marked: false)
        }
        .padding(.horizontal, Theme.g3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Free recordings carry a small MoshPit watermark in the corner. Unlocked recordings are clean.")
    }

    private func sample(title: String, marked: Bool) -> some View {
        VStack(spacing: Theme.gHalf) {
            ZStack(alignment: .bottomTrailing) {
                LinearGradient(colors: [Theme.accent.opacity(0.7), Theme.stroke],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if marked {
                    Text("MoshPit")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
                        .padding(Theme.g1)
                }
            }
            .frame(height: Theme.buttonLarge + Theme.g4)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            Text(title)
                .font(Theme.labelSmall)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
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
