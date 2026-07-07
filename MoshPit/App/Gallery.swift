import SwiftUI
import AVFoundation
import UIKit

// MARK: - Gallery panel (session clips)

/// Left-drawer "Gallery" panel: recordings made this session. List-based to
/// match the other panels; rows tap through to fullscreen playback and carry
/// a per-clip action menu (Share / Load into Slot A / Share to Social / Delete).
struct GalleryPanel: View {
    @EnvironmentObject var app: AppModel
    /// Passed in (app.socialExporter) so this view re-renders on progress —
    /// AppModel doesn't republish its children.
    @ObservedObject var exporter: SocialExporter
    @State private var confirmingDelete: SessionClip?
    @State private var blockedDelete: SessionClip?

    var body: some View {
        List {
            if app.sessionClips.isEmpty {
                Section {
                    Text("Recordings from this session appear here.")
                        .font(Theme.label)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, Theme.g3)
                }
            } else {
                Section("This session") {
                    ForEach(app.sessionClips) { clip in
                        ClipRow(clip: clip,
                                onDelete: { requestDelete(clip) },
                                onSocialExport: { socialExport(clip) })
                    }
                }
            }
        }
        .overlay {
            if exporter.isExporting {
                SocialExportProgressView(exporter: exporter)
            }
        }
        .alert("Delete recording?", isPresented: Binding(
            get: { confirmingDelete != nil },
            set: { if !$0 { confirmingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let clip = confirmingDelete { _ = app.deleteClip(clip) }
                confirmingDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmingDelete = nil }
        } message: {
            Text("This removes the clip from the session gallery and deletes the file. Anything already saved to Photos is unaffected.")
        }
        .alert("Clip is loaded in Slot A", isPresented: Binding(
            get: { blockedDelete != nil },
            set: { if !$0 { blockedDelete = nil } })) {
            Button("OK", role: .cancel) { blockedDelete = nil }
        } message: {
            Text("This clip is currently playing in Slot A. Load a different source into Slot A first, then delete it.")
        }
    }

    private func requestDelete(_ clip: SessionClip) {
        // Blocked (with an explanation) rather than unloading the source:
        // never delete the file out from under the player.
        if app.clipIsLoadedInSlotA(clip) { blockedDelete = clip }
        else { confirmingDelete = clip }
    }

    private func socialExport(_ clip: SessionClip) {
        exporter.export(clipURL: clip.url) { url in
            if let url { ShareSheetPresenter.present(fileURL: url) }
        }
    }
}

/// One gallery row: thumbnail + duration/size/relative-time, tap = playback,
/// trailing menu for the per-clip actions.
private struct ClipRow: View {
    @EnvironmentObject var app: AppModel
    let clip: SessionClip
    let onDelete: () -> Void
    let onSocialExport: () -> Void

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: Theme.g2) {
            Button { app.presentPlayback(clip) } label: {
                HStack(spacing: Theme.g2) {
                    Image(uiImage: clip.thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: Theme.buttonLarge, height: Theme.buttonLarge)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius,
                                                    style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius,
                                                  style: .continuous)
                            .stroke(Theme.stroke, lineWidth: 1))
                    VStack(alignment: .leading, spacing: Theme.gHalf) {
                        Text("\(SessionClipStore.durationText(clip.duration)) · \(SessionClipStore.fileSizeText(clip.fileSize))")
                            .font(Theme.mono).monospacedDigit()
                            .foregroundStyle(Theme.textPrimary)
                        Text(Self.relative.localizedString(for: clip.timestamp,
                                                           relativeTo: Date()))
                            .font(Theme.labelSmall)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    ShareSheetPresenter.present(fileURL: clip.url)
                } label: { Label("Share", systemImage: "square.and.arrow.up") }
                Button {
                    app.loadClipIntoSlotA(clip)
                } label: { Label("Load into Slot A", systemImage: "arrow.uturn.left.circle") }
                Button(action: onSocialExport) {
                    Label("Share to Social", systemImage: "arrow.up.forward.app")
                }
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: Theme.buttonSmall, height: Theme.buttonSmall)
                    .contentShape(Rectangle())
            }
        }
    }
}

// MARK: - Social export progress modal

/// Small determinate-progress modal over the gallery while the writer-based
/// re-encode runs; Cancel tears it down and deletes the partial file.
struct SocialExportProgressView: View {
    @ObservedObject var exporter: SocialExporter

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: Theme.g2) {
                Text("Exporting for social")
                    .font(Theme.label)
                    .foregroundStyle(Theme.textPrimary)
                ProgressView(value: exporter.progress)
                    .tint(Theme.accent)
                Text("\(Int(exporter.progress * 100))%")
                    .font(Theme.monoSmall).monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                Button("Cancel") { exporter.cancel() }
                    .buttonStyle(MoshButtonStyle(size: .small))
            }
            .padding(Theme.g3)
            .frame(maxWidth: 280)
            .scrim(strong: true)
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1))
        }
    }
}

// MARK: - Clip playback modal

/// Fullscreen AVPlayer playback with a custom scrub bar bound to player time
/// via a periodic time observer; seeking follows the drag.
struct ClipPlaybackView: View {
    let clip: SessionClip
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback: ClipPlayback

    init(clip: SessionClip) {
        self.clip = clip
        _playback = StateObject(wrappedValue: ClipPlayback(url: clip.url,
                                                           duration: clip.duration))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerLayerView(player: playback.player)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    IconButton(systemName: "xmark") { dismiss() }
                        .accessibilityLabel("Close")
                }
                .padding(.horizontal, Theme.g2)
                .padding(.top, Theme.g1)
                Spacer()
                controls
                    .padding(.horizontal, Theme.g2)
                    .padding(.bottom, Theme.g3)
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear { playback.stop() }
    }

    private var controls: some View {
        HStack(spacing: Theme.g2) {
            Button { playback.togglePlay() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: Theme.buttonSmall, height: Theme.buttonSmall)
            }
            .buttonStyle(MoshButtonStyle(size: .small))
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

            Text(SessionClipStore.durationText(playback.currentTime))
                .font(Theme.monoSmall).monospacedDigit()
                .foregroundStyle(Theme.textSecondary)

            Slider(value: Binding(
                get: { playback.scrubPosition },
                set: { playback.scrub(to: $0) }),
                in: 0...1) { editing in
                playback.setScrubbing(editing)
            }
            .tint(Theme.accent)

            Text(SessionClipStore.durationText(playback.duration))
                .font(Theme.monoSmall).monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, Theme.g2)
        .padding(.vertical, Theme.g1)
        .scrim(strong: true)
    }
}

/// Player time model: periodic observer drives the scrub position; drags
/// seek with zero tolerance so the bar tracks the finger.
final class ClipPlayback: ObservableObject {
    let player: AVPlayer
    let duration: Double
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    private var timeObserver: Any?
    private var scrubbing = false

    var scrubPosition: Double {
        duration > 0 ? min(1, max(0, currentTime / duration)) : 0
    }

    init(url: URL, duration: Double) {
        self.player = AVPlayer(url: url)
        self.duration = duration
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main) {
            [weak self] time in
            guard let self, !self.scrubbing else { return }
            self.currentTime = CMTimeGetSeconds(time)
            self.isPlaying = self.player.rate != 0
        }
        player.play()
        isPlaying = true
    }

    func togglePlay() {
        if player.rate != 0 { player.pause(); isPlaying = false }
        else {
            // Replay from the top when the clip has run out.
            if duration > 0, currentTime >= duration - 0.05 {
                player.seek(to: .zero)
                currentTime = 0
            }
            player.play(); isPlaying = true
        }
    }

    func setScrubbing(_ active: Bool) {
        scrubbing = active
        if active { player.pause(); isPlaying = false }
    }

    func scrub(to fraction: Double) {
        guard duration > 0 else { return }
        let seconds = fraction * duration
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        player.pause()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }
}

/// AVPlayerLayer host (aspect-fit) — VideoPlayer ships its own chrome; the
/// spec wants our custom scrub bar, so we render the bare layer.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}
