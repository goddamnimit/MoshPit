import SwiftUI

// MARK: - Coach marks (Tier 1)

/// Every UI element a coach mark can anchor to. Views tag themselves with
/// `.coachAnchor(...)`; frames are collected via a PreferenceKey.
enum CoachAnchor: String, CaseIterable {
    case canvas, leftHandle, modeList, panelTriggers, rightHandle
    case xyPad, paramRows, resetButton, recordButton, bloomButton, hudPill
    case finale   // full-screen card, no spotlight
}

struct CoachStop: Equatable {
    let anchor: CoachAnchor
    let text: String
    /// Drawer that must be open for this stop (tutorial opens/closes it).
    let drawer: DrawerSide?
}

enum CoachScript {
    static let hasSeenKey = "hasSeenCoachMarks"

    /// The 12 stops, in order, plain non-technical language.
    static let stops: [CoachStop] = [
        .init(anchor: .canvas,
              text: "This is your canvas — your live camera feed gets glitched and smeared here in real time.",
              drawer: nil),
        .init(anchor: .leftHandle,
              text: "Swipe from the left to switch between effects and open settings panels.",
              drawer: nil),
        .init(anchor: .modeList,
              text: "These are your glitch styles. Smear stretches frames, Bloom erupts detail, T-Bloom fires on a rhythm — try them all.",
              drawer: .left),
        .init(anchor: .panelTriggers,
              text: "These panels give you sources (camera or video), effects, rhythm controls, automation, and output options.",
              drawer: .left),
        .init(anchor: .rightHandle,
              text: "Swipe from the right to tune the active effect with sliders and an XY pad.",
              drawer: nil),
        .init(anchor: .xyPad,
              text: "Drag anywhere on this pad to control two things at once — axes change per mode.",
              drawer: .right),
        .init(anchor: .paramRows,
              text: "Drag any row left or right to adjust it. Pull up or down while dragging for finer control. Double-tap to reset.",
              drawer: .right),
        .init(anchor: .resetButton,
              text: "Tap to snap back to a clean frame. Hold to peek at clean video without losing your glitch.",
              drawer: nil),
        .init(anchor: .recordButton,
              text: "Tap to record your glitched video with mic audio. Tap again to save to Photos.",
              drawer: nil),
        .init(anchor: .bloomButton,
              text: "Tap to manually trigger a bloom burst — moving areas erupt with duplicated detail.",
              drawer: nil),
        .init(anchor: .hudPill,
              text: "Your frame rate. Tap to expand for GPU timing details.",
              drawer: nil),
        .init(anchor: .finale,
              text: "You're ready. Swipe the edges to explore — Clean mode is always one tap away if you want to start fresh. Have fun.",
              drawer: nil),
    ]
}

// MARK: anchor frame plumbing

struct CoachFrameKey: PreferenceKey {
    static var defaultValue: [CoachAnchor: CGRect] { [:] }
    static func reduce(value: inout [CoachAnchor: CGRect],
                       nextValue: () -> [CoachAnchor: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Tags a view as a coach-mark anchor; its frame in moshRoot space is published.
    func coachAnchor(_ anchor: CoachAnchor) -> some View {
        overlay(GeometryReader { geo in
            Color.clear.preference(key: CoachFrameKey.self,
                                   value: [anchor: geo.frame(in: .named("moshRoot"))])
        })
    }
}

// MARK: overlay

/// Renders above everything (drawers included): dimmed background with a
/// spring-animated rounded-rect spotlight around the target, a callout
/// bubble, tap-anywhere-to-advance, and an ever-present Skip.
struct CoachOverlay: View {
    @EnvironmentObject var app: AppModel
    let frames: [CoachAnchor: CGRect]

    @State private var lastTarget: CGRect? = nil

    var body: some View {
        if let index = app.coachIndex, index < CoachScript.stops.count {
            let stop = CoachScript.stops[index]
            GeometryReader { geo in
                ZStack {
                    if stop.anchor == .finale {
                        Color.black.opacity(0.7).ignoresSafeArea()
                        finaleCard
                    } else {
                        let target = app.isTutorialTransitioning ? (lastTarget ?? spotlightRect(for: stop, in: geo)) : spotlightRect(for: stop, in: geo)
                        // Dim + spotlight are purely visual: hit-testing off,
                        // so the render loop / session UI beneath is never
                        // blocked by the overlay.
                        SpotlightShape(cutout: target)
                            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                            .ignoresSafeArea()
                            .animation(.spring(duration: 0.45), value: target)
                            .allowsHitTesting(false)
                        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                            .stroke(Theme.accent, lineWidth: 2)
                            .frame(width: target.width, height: target.height)
                            .position(x: target.midX, y: target.midY)
                            .animation(.spring(duration: 0.45), value: target)
                            .allowsHitTesting(false)
                        callout(for: stop, target: target, in: geo)
                            .onChange(of: target) { _, newTarget in
                                if !app.isTutorialTransitioning {
                                    lastTarget = newTarget
                                }
                            }
                    }
                    // Skip is always visible in the corner.
                    if stop.anchor != .finale {
                        VStack {
                            HStack {
                                Spacer()
                                Button("Skip tutorial") { app.skipTutorial() }
                                    .font(Theme.labelSmall)
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.horizontal, Theme.g2)
                                    .frame(height: Theme.buttonSmall)
                                    .scrim()
                            }
                            Spacer()
                        }
                        .padding(Theme.g2)
                    }
                }
            }
            .onChange(of: app.coachIndex) { _, newIndex in
                if newIndex == nil || newIndex == 0 {
                    lastTarget = nil
                }
            }
            // Anchor frames are published in moshRoot coordinates.
            // The overlay must live in the SAME space: without ignoresSafeArea
            // its GeometryReader starts below the notch, and .position()
            // (which is LOCAL) would draw every ring shifted by the safe-area
            // inset — subtle in the simulator, glaring on device.
            .ignoresSafeArea()
            .transition(.opacity)
        }
    }

    private func spotlightRect(for stop: CoachStop, in geo: GeometryProxy) -> CGRect {
        if stop.anchor == .canvas {
            // The canvas is the whole screen minus the bars: highlight a
            // generous center region (local space — the overlay IS the screen).
            return CGRect(origin: .zero, size: geo.size)
                .insetBy(dx: Theme.g4, dy: geo.size.height * 0.22)
        }
        let raw = frames[stop.anchor] ?? CGRect(x: geo.size.width / 2 - 40,
                                                y: geo.size.height / 2 - 40,
                                                width: 80, height: 80)
        // moshRoot -> overlay-local. With ignoresSafeArea the overlay's origin
        // is (0,0) and this is the identity, but converting explicitly keeps
        // the ring glued to its target even if the overlay is ever re-hosted.
        let localFrame = geo.frame(in: .named("moshRoot"))
        return raw.offsetBy(dx: -localFrame.origin.x, dy: -localFrame.origin.y)
            .insetBy(dx: -Theme.g1, dy: -Theme.g1)   // 8pt padding
    }

    @ViewBuilder
    private func callout(for stop: CoachStop, target: CGRect,
                         in geo: GeometryProxy) -> some View {
        let below = target.midY < geo.size.height * 0.5
        // The whole callout is the "Got it" button — the only interactive
        // surface besides Skip, everything else passes touches through.
        Button {
            app.advanceTutorial()
        } label: {
            VStack(alignment: .leading, spacing: Theme.g1) {
                // Content only — spotlight/positioning logic is untouched.
                Text(stop.text)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                HStack {
                    Spacer()
                    Text("Got it →")
                        .font(Theme.label)
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(Theme.g2)
            .frame(maxWidth: 280)
        }
        .buttonStyle(PressScaleStyle())
        .scrim(strong: true)
        .position(
            x: min(max(target.midX, 156), geo.size.width - 156),
            y: below ? min(target.maxY + 80, geo.size.height - 120)
                     : max(target.minY - 80, 120))
        .animation(.spring(duration: 0.45), value: target)
    }

    private var finaleCard: some View {
        VStack(spacing: Theme.g3) {
            Text("You're ready.")
                .font(.title2.bold()).foregroundStyle(Theme.textPrimary)
            Text("Swipe the edges to explore — Clean mode is always one tap away if you want to start fresh. Have fun.")
                .font(.body).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                app.finishTutorial()
            } label: {
                Text("Let's go").frame(maxWidth: .infinity)
            }
            .buttonStyle(MoshButtonStyle(size: .large, selected: true, fillsWidth: true))
        }
        .padding(Theme.g4)
        .frame(maxWidth: 320)
        .scrim(strong: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Full-screen rect with an even-odd rounded-rect cutout.
struct SpotlightShape: Shape {
    var cutout: CGRect
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                       AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(cutout.origin.x, cutout.origin.y),
                    .init(cutout.width, cutout.height)) }
        set { cutout = CGRect(x: newValue.first.first, y: newValue.first.second,
                              width: newValue.second.first, height: newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRect(rect)
        p.addRoundedRect(in: cutout, cornerSize: .init(width: Theme.radius,
                                                       height: Theme.radius))
        return p
    }
}

// MARK: - Tip cards (shared by demos; dismissible floating card)

struct TipCardView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        if let tip = app.activeTip {
            VStack {
                Spacer()
                VStack(alignment: .leading, spacing: Theme.g1) {
                    Text(tip)
                        .font(.body).foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Text("Tap to dismiss")
                            .font(Theme.labelSmall).foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(Theme.g2)
                .frame(maxWidth: 280)
                .scrim(strong: true)
                .padding(.bottom, Theme.g6 * 2.5)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { app.activeTip = nil }
            .transition(.opacity)
        }
    }
}

// MARK: - Guided demos (Tier 2)

/// Adding a demo = adding a struct here. `setup` receives the AppModel and
/// arranges app state (mode, drawers, panels, tips, highlights) — the MINIMUM
/// needed; demos point, the user plays.
struct DemoCard: Identifiable {
    let id: String
    let section: String
    let title: String
    let blurb: String
    let setup: (AppModel) -> Void
}

enum DemoLibrary {
    /// Section display order for the sheet.
    static let sections = ["Basics", "Mosh Modes", "Rhythm & Timing",
                           "Sources & Mixing", "Visual Effects", "3D", "Output"]

    static func demos(in section: String) -> [DemoCard] {
        all.filter { $0.section == section }
    }

    static let all: [DemoCard] = basics + moshModes + rhythm + sourcesMixing
        + visualEffects + threeD + output

    // MARK: Basics

    private static let basics: [DemoCard] = [
        DemoCard(id: "clean", section: "Basics", title: "Clean Passthrough",
                 blurb: "Your baseline: pure camera, no effects.") { app in
            app.selectMode(.clean)
            app.activeTip = "This is your baseline. No effects — pure camera. Hold the Reset button anytime to peek back here without losing your mosh."
        },
        DemoCard(id: "firstsmear", section: "Basics", title: "Your First Smear",
                 blurb: "Watch frames stretch into trails.") { app in
            app.selectMode(.classicSmear)
            app.openDrawer(.right)
            app.activeTip = "Move slowly in front of the camera. Watch the trail follow you. The longer you hold still, the more the last frame freezes into the canvas."
        },
        DemoCard(id: "reset", section: "Basics", title: "Reset & Seed",
                 blurb: "Manual I-frames: snap back to clean.") { app in
            app.selectMode(.classicSmear)
            app.activeTip = "Tap Reset to snap back to a clean frame — this seeds the canvas so your next mosh starts fresh. Hold Reset to peek without resetting."
        },
        DemoCard(id: "saving", section: "Basics", title: "Saving Your Work",
                 blurb: "Record video or snapshot a frame.") { app in
            app.activeTip = "Tap the record button to capture video with mic audio. Tap the camera icon to snapshot a single frame. Both save to Photos."
        },
    ]

    // MARK: Mosh Modes

    private static let moshModes: [DemoCard] = [
        DemoCard(id: "bloom", section: "Mosh Modes", title: "Bloom Burst",
                 blurb: "Moving areas erupt with frozen detail.") { app in
            app.selectMode(.bloom)
            app.openDrawer(.right)
            app.highlightParam = .bloomThreshold
            app.activeTip = "Stay still, then move suddenly. Moving areas erupt with frozen detail. Lower Threshold = more sensitive."
        },
        DemoCard(id: "tbloom", section: "Mosh Modes", title: "Timed Bloom",
                 blurb: "Blooms fire on a timer, direction of their own.",) { app in
            app.selectMode(.timedBloom)
            app.openDrawer(.right)
            app.highlightParam = .bloomRate
            app.activeTip = "Blooms fire automatically on a timer. Rate controls how often. Try slow Rate with sudden movement between blooms."
        },
        DemoCard(id: "drift", section: "Mosh Modes", title: "Directional Drift",
                 blurb: "Push the whole frame with the XY pad.",) { app in
            app.selectMode(.drift)
            app.openDrawer(.right)
            app.activeTip = "The XY pad controls the direction pixels smear. Push everything to one corner. Great for slow hypnotic flows."
        },
        DemoCard(id: "mix", section: "Mosh Modes", title: "Mix Wet/Dry",
                 blurb: "Blend fresh frames into the smear.",) { app in
            app.selectMode(.mixMosh)
            app.openDrawer(.right)
            app.activeTip = "The crossfader blends fresh frames into the smear continuously. All the way left = frozen. All the way right = clean. Middle = the sweet spot."
        },
        DemoCard(id: "cross", section: "Mosh Modes", title: "Cross Mosh",
                 blurb: "One source's motion drives the other's pixels.",) { app in
            app.selectMode(.crossMosh)
            app.activeTip = "Load two different sources in slot A and B (Sources panel). Motion from one drives the pixels of the other. Flip the camera mid-mosh for instant cross-mosh between front and rear."
        },
        DemoCard(id: "feedback", section: "Mosh Modes", title: "Feedback Loop",
                 blurb: "The canvas zooms and rotates into itself.",) { app in
            app.selectMode(.feedback)
            app.openDrawer(.right)
            app.activeTip = "The canvas zooms and rotates into itself every frame. Small zoom values create infinite tunnels. Hue rotation makes it cycle through color."
        },
        DemoCard(id: "flip", section: "Mosh Modes", title: "Camera Flip Smear",
                 blurb: "Flip cameras mid-smear for a face-melt cut.") { app in
            app.selectMode(.classicSmear)
            app.activeTip = "Tap the flip button mid-smear and watch your face melt into itself."
        },
    ]

    // MARK: Rhythm & Timing

    private static let rhythm: [DemoCard] = [
        DemoCard(id: "taptempo", section: "Rhythm & Timing", title: "Tap Tempo",
                 blurb: "Lock MoshPit to your music.") { app in
            app.openSheet(.control)
            app.activeTip = "Tap the TAP button repeatedly in time with music. MoshPit locks to your rhythm. Everything time-synced from here uses this BPM."
        },
        DemoCard(id: "lfo", section: "Rhythm & Timing", title: "LFO Basics",
                 blurb: "Make any parameter pulse automatically.",) { app in
            app.openSheet(.control)
            app.activeTip = "LFO 1 is a wave that goes up and down at your tempo. Set its waveform and rate, then drag it to a destination in the mod matrix to make any parameter pulse automatically."
        },
        DemoCard(id: "rhythmwipe", section: "Rhythm & Timing", title: "Rhythmic Source Switching",
                 blurb: "Beat-synced cuts between A and B.",) { app in
            app.openSheet(.control)
            app.activeTip = "Load two clips or use camera + clip. Route LFO 1 to Mix Crossfader with a square wave. Your sources now cut rhythmically on the beat."
        },
        DemoCard(id: "strobe", section: "Rhythm & Timing", title: "Strobe Flash",
                 blurb: "Beat-gated blackout/whiteout flashes.",) { app in
            app.openSheet(.control)
            app.activeTip = "Route an LFO to the Blackout destination in the strobe section. Square wave at 1/2 rate = flash on every other beat. Keep the flicker limiter ON unless you know your audience."
        },
    ]

    // MARK: Sources & Mixing

    private static let sourcesMixing: [DemoCard] = [
        DemoCard(id: "loadvideo", section: "Sources & Mixing", title: "Load a Video",
                 blurb: "Any clip from Photos becomes a mosh source.") { app in
            app.openSheet(.sources)
            app.activeTip = "Tap slot A to load a clip from your Photos library. It loops automatically and feeds the mosh engine just like the camera."
        },
        DemoCard(id: "reverse", section: "Sources & Mixing", title: "Reverse Playback",
                 blurb: "Play any clip backwards, mid-mosh.",) { app in
            app.openSheet(.sources)
            app.activeTip = "Toggle Reverse on any video slot to play it backwards. Try it mid-mosh — the smear reverses direction as the motion vectors flip."
        },
        DemoCard(id: "selfcross", section: "Sources & Mixing", title: "Self Cross-Mosh",
                 blurb: "A clip smears itself with its own motion.",) { app in
            app.openSheet(.sources)
            app.activeTip = "Load the same clip into both slot A and B, then select Cross mode. The video smears itself with its own motion. Desync the clips for stranger results."
        },
        DemoCard(id: "lumawipe", section: "Sources & Mixing", title: "Luma Wipe",
                 blurb: "Brightness-keyed transitions between sources.",) { app in
            app.openSheet(.sources)
            app.activeTip = "Set wipe mode to Luma in the Mix section. Drag the threshold — bright areas of the frame transition to source B first, dark areas last. Automate this with an LFO for rhythmic wipes."
        },
        DemoCard(id: "videomod", section: "Sources & Mixing", title: "Video as Controller",
                 blurb: "A hidden clip drives your parameters.",) { app in
            app.openSheet(.control)
            app.activeTip = "Load a clip into the MOD slot — it never appears on screen. Its brightness and motion control any parameter you route it to. A flickering fire clip in MOD = fire-driven bloom."
        },
    ]

    // MARK: Visual Effects

    private static let visualEffects: [DemoCard] = [
        DemoCard(id: "mirror", section: "Visual Effects", title: "Mirror Modes",
                 blurb: "Symmetry, applied after the mosh.",) { app in
            app.openSheet(.effects)
            app.activeTip = "Try Quad mirror with Smear active — your face becomes a symmetrical glitch mandala. Mirror applies after the mosh so smeared pixels get mirrored too."
        },
        DemoCard(id: "invert", section: "Visual Effects", title: "Color Invert",
                 blurb: "Negative-space glitch explosions.",) { app in
            app.openSheet(.effects)
            app.activeTip = "Invert flips all colors. Combined with Bloom it creates a negative-space explosion effect."
        },
        DemoCard(id: "duotone", section: "Visual Effects", title: "Duotone",
                 blurb: "Two-color grade over any mosh.",) { app in
            app.openSheet(.effects)
            app.activeTip = "Duotone maps your image to two colors — shadow hue and highlight hue. Route an LFO to Hue Shift instead for continuous color cycling."
        },
        DemoCard(id: "echo", section: "Visual Effects", title: "Echo Trails",
                 blurb: "Ghosts of past frames, keyed by brightness.") { app in
            app.openSheet(.effects)
            app.activeTip = "Echo layers past frames behind the current one, keyed by brightness. More layers = longer ghosting. Combined with Smear it creates deep time-based trails."
        },
        DemoCard(id: "pixelsort", section: "Visual Effects", title: "Pixel Sort",
                 blurb: "Cascading streaks along brightness edges.") { app in
            app.openSheet(.effects)
            app.activeTip = "PXLMSH sorts pixels along brightness edges. High threshold = subtle sorting along bright edges only. Low threshold = whole regions cascade."
        },
    ]

    // MARK: 3D

    private static let threeD: [DemoCard] = [
        DemoCard(id: "cloud", section: "3D", title: "Point Cloud",
                 blurb: "Your glitch becomes floating dots.",) { app in
            app.params.set(.trace3D, 1, origin: .ui)
            app.params.set(.traceMode, 0, origin: .ui)   // points
            app.openSheet(.threeD)
            app.activeTip = "Your moshed video becomes a cloud of glowing dots displaced by brightness. Drag to orbit, pinch to zoom."
        },
        DemoCard(id: "wireframe", section: "3D", title: "Wireframe Face",
                 blurb: "Your video as a displaced grid mesh.",) { app in
            app.params.set(.trace3D, 1, origin: .ui)
            app.params.set(.traceMode, 1, origin: .ui)   // wireframe
            app.openSheet(.threeD)
            app.activeTip = "The mesh shows the geometry of your video as a grid. Luma depth amount pushes bright areas toward you."
        },
        DemoCard(id: "object", section: "3D", title: "Textured Object",
                 blurb: "Wrap the mosh around a sphere or torus.",) { app in
            app.params.set(.trace3D, 1, origin: .ui)
            app.openSheet(.threeD)
            app.activeTip = "Switch the primitive to Sphere or Torus — your moshed video wraps around it as a skin. Point cloud on a torus is particularly strange."
        },
        DemoCard(id: "bloom3d", section: "3D", title: "3D + Bloom",
                 blurb: "Eruptions across the geometry surface.",) { app in
            app.activeTip = "Switch to Bloom mode while in 3D point cloud. Bloom eruptions appear on the geometry surface. Add auto-rotate for a self-animating visual instrument."
        },
    ]

    // MARK: Output

    private static let output: [DemoCard] = [
        DemoCard(id: "record", section: "Output", title: "Record a Performance",
                 blurb: "Full-resolution capture of everything.") { app in
            app.activeTip = "Tap Record before you start. Tap again to stop and save. Recordings capture everything including mirror modes, color, and 3D geometry at full resolution."
        },
        DemoCard(id: "ndi", section: "Output", title: "NDI to Resolume",
                 blurb: "Stream live into your VJ setup.",) { app in
            app.activeTip = "Toggle NDI in the Output panel. Accept the local network permission prompt. Open Resolume on the same Wi-Fi and look for MoshPit in the NDI sources. Your mosh streams live to your VJ setup."
        },
        DemoCard(id: "automation", section: "Output", title: "Automation",
                 blurb: "Record knob moves, replay them anywhere.",) { app in
            app.openSheet(.automation)
            app.activeTip = "Hit Record in the Automation panel, perform your parameter changes, then stop. Play it back over any source — your performance is now a reusable loop."
        },
    ]
}

struct DemoSheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Collapsed by default except Basics — scanning 7 headers beats
    /// scrolling 30 cards.
    @State private var expanded: Set<String> = {
        #if DEBUG
        // -demoexpand <word>: also expand the first section matching <word>
        // (screenshot hook).
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-demoexpand"), i + 1 < args.count,
           let match = DemoLibrary.sections.first(where: {
               $0.lowercased().contains(args[i + 1].lowercased())
           }) {
            return [match]
        }
        #endif
        return ["Basics"]
    }()

    var body: some View {
        NavigationStack {
            List {
                // Shuffle: launch a random demo from any section — discovery.
                Button {
                    if let demo = DemoLibrary.all.randomElement() { launch(demo) }
                } label: {
                    Label("Shuffle — surprise me", systemImage: "shuffle")
                        .font(Theme.label).foregroundStyle(Theme.accent)
                }
                .listRowBackground(Color.clear)

                ForEach(DemoLibrary.sections, id: \.self) { section in
                    Section {
                        if expanded.contains(section) {
                            ForEach(DemoLibrary.demos(in: section)) { demo in
                                demoRow(demo)
                            }
                        }
                    } header: {
                        sectionHeader(section)
                    }
                }
            }
            .navigationTitle("Guided Demos")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }

    private func sectionHeader(_ section: String) -> some View {
        Button {
            withAnimation(Theme.fade) {
                if expanded.contains(section) { expanded.remove(section) }
                else { expanded.insert(section) }
            }
        } label: {
            HStack {
                Text(section)
                Spacer()
                Text("\(DemoLibrary.demos(in: section).count)")
                    .font(Theme.monoSmall).monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                Image(systemName: "chevron.right")
                    .font(Theme.labelSmall)
                    .rotationEffect(.degrees(expanded.contains(section) ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func demoRow(_ demo: DemoCard) -> some View {
        VStack(alignment: .leading, spacing: Theme.g1) {
            HStack(spacing: Theme.gHalf) {
                Text(demo.title).font(Theme.label).foregroundStyle(Theme.textPrimary)
            }
            Text(demo.blurb)
                .font(Theme.labelSmall).foregroundStyle(Theme.textSecondary)
            HStack {
                Spacer()
                Button("Try it") { launch(demo) }
                    .buttonStyle(MoshButtonStyle(size: .small, selected: true))
            }
        }
        .padding(.vertical, Theme.gHalf)
        .listRowBackground(Color.clear)
    }

    private func launch(_ demo: DemoCard) {
        dismiss()
        app.showCheatSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            demo.setup(app)
        }
    }
}

// MARK: - Help sheet (replaces the old floating cheat sheet)

struct HelpSheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss

    private let keys: [(String, String)] = [
        ("0", "Clean passthrough"), ("1–7", "Select mosh mode"),
        ("Space", "Trigger bloom"), ("Hold Reset", "Peek clean (mosh kept)"),
        ("W A S D / arrows", "Nudge drift"), ("R", "Reset canvas (I-frame)"),
        ("⌘R", "Start/stop recording"), ("⇧R", "Reverse video playback"),
        ("F", "Flip camera"),
        ("H", "Hide/show controls"), ("T", "Tap tempo"),
        ("M", "Cycle mirror mode"), ("C", "Cycle color mode"),
        ("[", "Toggle modes drawer"), ("]", "Toggle parameters drawer"),
        ("?", "Toggle this sheet"), ("Long-press a label", "MIDI learn"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Quick reference") {
                    ForEach(keys, id: \.0) { row in
                        HStack(spacing: Theme.g2) {
                            Text(row.0).font(Theme.mono)
                                .foregroundStyle(Theme.textPrimary)
                                .frame(width: Theme.g6 * 3, alignment: .leading)
                            Text(row.1).font(Theme.label)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                Section("Tutorial") {
                    Button("Restart tutorial") {
                        dismiss()
                        app.showCheatSheet = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            app.startTutorial()
                        }
                    }
                    Button("Guided Demo") {
                        dismiss()
                        app.showCheatSheet = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            app.showDemoSheet = true
                        }
                    }
                }
                Section("About") {
                    LabeledContent("MoshPit", value: "Real-time video glitch instrument")
                    LabeledContent("Version", value: Bundle.main.versionString)
                }
            }
            .navigationTitle("Help")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }
}

extension Bundle {
    var versionString: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
