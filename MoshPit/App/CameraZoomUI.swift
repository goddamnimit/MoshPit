import SwiftUI
import UIKit

// MARK: - Lens pill (stock Camera-app zoom selector)

/// One tap target per available lens factor on the ACTIVE camera —
/// e.g. 0.5 / 1 / 2 on a triple-camera back, just 1 on the front. Options
/// come from the device's real switch-over factors, never hardcoded.
/// Hidden entirely when no slot holds a camera.
struct ZoomPillView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        if let sources = app.sources {
            ZoomPillContent(sources: sources)
        }
    }
}

private struct ZoomPillContent: View {
    @ObservedObject var sources: SourceManager

    var body: some View {
        if !sources.cameraZoomOptions.isEmpty {
            HStack(spacing: Theme.gHalf) {
                ForEach(sources.cameraZoomOptions, id: \.self) { option in
                    let selected = option == selectedOption
                    Button {
                        Theme.haptic()
                        sources.setCameraZoom(option)
                    } label: {
                        Text(selected ? Self.format(sources.cameraZoom) + "×"
                                      : Self.format(option))
                            .font(Theme.monoSmall).monospacedDigit()
                            .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                            .frame(minWidth: Theme.buttonSmall,
                                   minHeight: Theme.buttonSmall)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Zoom \(Self.format(option))x")
                }
            }
            .padding(.horizontal, Theme.gHalf)
            .scrim()
            .transition(.opacity)
        }
    }

    /// The lens the current zoom is "in": largest option at or below it
    /// (stock behavior — 1.7x highlights the 1x lens, 2.3x the 2x lens).
    private var selectedOption: CGFloat? {
        sources.cameraZoomOptions.filter { $0 <= sources.cameraZoom + 0.01 }.max()
            ?? sources.cameraZoomOptions.first
    }

    private static func format(_ value: CGFloat) -> String {
        value.truncatingRemainder(dividingBy: 1).magnitude < 0.05
            ? String(Int(value.rounded()))
            : String(format: "%.1f", value)
    }
}

// MARK: - Pinch-to-zoom

/// Camera pinch-to-zoom with the stock Camera feel. The recognizer attaches
/// to the WINDOW, not this view: the SwiftUI overlays above the Metal canvas
/// own hit-testing, so a view-local UIPinchGestureRecognizer would never see
/// touches. Window-level with cancelsTouchesInView=false observes two-finger
/// pinches without stealing the single-finger taps/drags SwiftUI relies on.
/// RootView only mounts this layer when camera zoom should win the pinch
/// (camera present, 3D orbit off, no drawer open) — unmounting removes the
/// recognizer, so it can never fight the orbit zoom or drawer gestures.
struct CameraPinchLayer: UIViewRepresentable {
    @EnvironmentObject var app: AppModel

    func makeUIView(context: Context) -> PinchHostView {
        let view = PinchHostView()
        view.coordinator = context.coordinator
        context.coordinator.app = app
        return view
    }

    func updateUIView(_ view: PinchHostView, context: Context) {
        context.coordinator.app = app
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var app: AppModel?
        private var startZoom: CGFloat = 1

        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            guard let sources = app?.sources else { return }
            switch gesture.state {
            case .began:
                startZoom = sources.cameraZoom
            case .changed:
                // Fast ramp rate: chases the finger closely but still glides,
                // instead of snapping videoZoomFactor per touch delta.
                sources.setCameraZoom(startZoom * gesture.scale, rate: 30)
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }

    /// Never hit-tests (fully transparent to SwiftUI); its only job is
    /// installing/removing the window-level recognizer with its lifetime.
    final class PinchHostView: UIView {
        weak var coordinator: Coordinator?
        private var recognizer: UIPinchGestureRecognizer?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
                self.recognizer = nil
            }
            guard let window, let coordinator else { return }
            let pinch = UIPinchGestureRecognizer(
                target: coordinator, action: #selector(Coordinator.pinch(_:)))
            pinch.cancelsTouchesInView = false
            pinch.delegate = coordinator
            window.addGestureRecognizer(pinch)
            recognizer = pinch
        }

        deinit {
            if let recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
        }
    }
}
