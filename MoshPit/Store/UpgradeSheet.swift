import SwiftUI

/// The one upgrade surface. Presented through AppModel.presentUpgrade(for:)
/// so it respects the overlay mutual-exclusivity system. No dark patterns:
/// no timers, no fake urgency, no nagging — a feature list, one price button
/// with the localized price, Restore, and a plain Not Now.
struct UpgradeSheet: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var pro = ProManager.shared
    @Environment(\.dismiss) private var dismiss

    /// Display rows and the capabilities they cover (for highlighting the
    /// one the user tapped).
    private static let features: [(icon: String, title: String, caps: [Capability])] = [
        ("square.grid.2x2", "All 7 mosh modes",
         [.modeTBloom, .modeDrift, .modeMix, .modeCross, .modeFeedback]),
        ("video.badge.plus", "Source slots B + MOD",
         [.sourceSlotB, .sourceSlotMOD]),
        ("antenna.radiowaves.left.and.right", "NDI + MJPEG network output",
         [.ndiOutput, .mjpegOutput]),
        ("waveform.path", "LFOs, mod matrix & automation",
         [.lfo, .modMatrix, .automation]),
        ("cube.transparent", "3D geometry — Trace + Mass",
         [.geometry3D]),
        ("wand.and.stars", "Mirror & color modes",
         [.mirrorModes, .colorModes]),
        ("backward.fill", "Reverse playback",
         [.reversePlayback]),
        ("square.and.arrow.up", "ProRes 4444, 4K & social export",
         [.proResExport, .export4K, .socialExport]),
        ("checkmark.seal", "No watermark on recordings & snapshots",
         [.watermarkFree]),
    ]

    private var busy: Bool {
        pro.purchaseState == .purchasing || pro.purchaseState == .restoring
    }

    var body: some View {
        VStack(spacing: Theme.g3) {
            Text("MoshPit Pro")
                .font(.title2.bold())
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, Theme.g4)

            VStack(alignment: .leading, spacing: Theme.g1) {
                ForEach(Self.features, id: \.title) { feature in
                    featureRow(feature)
                }
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
                            Text("Unlock Everything — \(pro.product?.displayPrice ?? "…")")
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
    private func featureRow(_ feature: (icon: String, title: String, caps: [Capability])) -> some View {
        let highlighted = app.upgradeCapability.map(feature.caps.contains) ?? false
        HStack(spacing: Theme.g1) {
            Image(systemName: feature.icon)
                .font(Theme.label)
                .foregroundStyle(highlighted ? Theme.accent : Theme.textSecondary)
                .frame(width: Theme.g3)
            Text(feature.title)
                .font(Theme.label)
                .foregroundStyle(highlighted ? Theme.textPrimary : Theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, Theme.g1)
        .frame(height: Theme.buttonSmall)
        .background(highlighted ? Theme.accent.opacity(0.18) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .stroke(highlighted ? Theme.accent : .clear, lineWidth: 1))
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
