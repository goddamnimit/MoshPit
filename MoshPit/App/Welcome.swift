import SwiftUI

// MARK: - Welcome (first launch only, before the coach marks)

/// Three swipeable cards: what MoshPit is, how to play, and honest pricing.
/// No permission prompts here (camera/mic requests stay contextual). Skip is
/// on every card; dismissing by any route (Skip, Get started, swipe-down)
/// persists "seen" and hands off to the coach marks via
/// AppModel.welcomeDismissed(). Replayable from Help.
struct WelcomeView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private let lastPage = 2

    var body: some View {
        VStack(spacing: Theme.g2) {
            HStack {
                Spacer()
                Button("Skip") { dismiss() }
                    .font(Theme.label)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minWidth: Theme.buttonStandard, minHeight: Theme.buttonStandard)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Skip welcome")
            }
            .padding(.horizontal, Theme.g2)
            .padding(.top, Theme.g1)

            TabView(selection: $page) {
                card(icon: "sparkles.tv",
                     title: "Glitch your world, live",
                     lines: [("camera.viewfinder", "MoshPit turns your camera or any video into real-time glitch art."),
                             ("wand.and.stars", "Smear, burst and warp what you see, then record it.")])
                    .tag(0)
                card(icon: "hand.draw",
                     title: "How to play",
                     lines: [("arrow.right.to.line", "Swipe in from the left edge to pick a glitch style."),
                             ("slider.horizontal.3", "Swipe in from the right for sliders and a square pad. Drag the pad to steer."),
                             ("record.circle", "Tap the red button to record. Tap any ? to learn what a control does.")])
                    .tag(1)
                card(icon: "tag",
                     title: "Free to use. Unlock when you're ready.",
                     lines: [("checkmark.circle", "Everything works for free, including recording."),
                             ("drop", "Free clips carry a small MoshPit watermark and stay in the app."),
                             ("lock.open", "One purchase, no subscription: removes the watermark and lets you save to Photos, share and export.")])
                    .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: Theme.g1) {
                ForEach(0...lastPage, id: \.self) { i in
                    Circle()
                        .fill(i == page ? Theme.accent : Theme.stroke)
                        .frame(width: Theme.g1, height: Theme.g1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page \(page + 1) of \(lastPage + 1)")

            Button {
                if page < lastPage { withAnimation(Theme.spring) { page += 1 } }
                else { dismiss() }
            } label: {
                Text(page < lastPage ? "Next" : "Get started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(MoshButtonStyle(size: .large, selected: true, fillsWidth: true))
            .padding(.horizontal, Theme.g3)
            .padding(.bottom, Theme.g3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.scrimBase.opacity(0.75))
        .preferredColorScheme(.dark)
    }

    private func card(icon: String, title: String,
                      lines: [(String, String)]) -> some View {
        VStack(spacing: Theme.g3) {
            Spacer(minLength: 0)
            Image(systemName: icon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: Theme.g2) {
                ForEach(lines, id: \.1) { line in
                    HStack(alignment: .top, spacing: Theme.g1) {
                        Image(systemName: line.0)
                            .font(Theme.label)
                            .foregroundStyle(Theme.accent)
                            .frame(width: Theme.g3)
                            .accessibilityHidden(true)
                        Text(line.1)
                            .font(Theme.label)
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.g3)
        .accessibilityElement(children: .combine)
    }
}
