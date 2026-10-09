import SwiftUI

// MARK: - Coach marks (Tier 1)

/// Every UI element a coach mark can anchor to. Views tag themselves with
/// `.coachAnchor(...)`; frames are collected via a PreferenceKey.
enum CoachAnchor: String, CaseIterable {
    case canvas, leftHandle, modeList, panelTriggers, rightHandle
    case xyPad, paramRows, resetButton, recordButton, bloomButton, hudPill
    /// Finisher-effect toggles inside the Effects panel sheet. Sheets are a
    /// separate view hierarchy from moshRoot, so these publish/consume via
    /// `.global` instead — see `coachAnchorGlobal` below.
    case gridWarpToggle, spreadsheetToggle, trackingHUDToggle
    case finale   // full-screen card, no spotlight
}

struct CoachStop: Equatable {
    let anchor: CoachAnchor
    let text: String
    /// Drawer that must be open for this stop (tutorial opens/closes it).
    let drawer: DrawerSide?
    /// Panel sheet that must be open for this stop (tutorial opens/closes
    /// it the same way it does drawers). nil for every stop outside the
    /// Effects panel.
    var panel: AppModel.Panel? = nil
}

enum CoachScript {
    static let hasSeenKey = "hasSeenCoachMarks"

    /// The 15 stops, in order, plain non-technical language.
    static let stops: [CoachStop] = [
        .init(anchor: .canvas,
              text: "This is your canvas — your live camera feed gets glitched and smeared here in real time.",
              drawer: nil),
        .init(anchor: .leftHandle,
              text: "Swipe from the left to switch between effects and open settings panels.",
              drawer: nil),
        .init(anchor: .modeList,
              text: "These are your glitch styles. \(Labels.mode(.classicSmear).title) stretches frames, \(Labels.mode(.bloom).title) erupts detail, \(Labels.mode(.timedBloom).title) fires on a rhythm — try them all. Tap any ? to see what it does.",
              drawer: .left),
        .init(anchor: .panelTriggers,
              text: "These panels give you inputs (camera or video), effects, rhythm controls, recorded moves, and recording and streaming options.",
              drawer: .left),
        .init(anchor: .gridWarpToggle,
              text: "The Effects panel also hides \(Labels.param(.gridWarpEnabled).title) — a drifting mesh that warps the picture, applied after everything else.",
              drawer: nil, panel: .effects),
        .init(anchor: .spreadsheetToggle,
              text: "\(Labels.param(.spreadsheetEnabled).title) turns your glitch into flat cells under fake spreadsheet menus, with a moving selection box.",
              drawer: nil, panel: .effects),
        .init(anchor: .trackingHUDToggle,
              text: "\(Labels.param(.trackingHUDEnabled).title) scatters tracking dots and number readouts over moving areas — pure sci-fi decoration.",
              drawer: nil, panel: .effects),
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
              text: "Tap to record your glitched video. Tap again to stop — it appears in My Clips. Free clips carry a small watermark; unlocking removes it and lets you save and share.",
              drawer: nil),
        .init(anchor: .bloomButton,
              text: "Tap to trigger a \(Labels.mode(.bloom).title) — moving areas erupt with duplicated detail.",
              drawer: nil),
        .init(anchor: .hudPill,
              text: "Your frame rate. Tap to expand for more performance details.",
              drawer: nil),
        .init(anchor: .finale,
              text: "You're ready. Swipe the edges to explore — Clean is always one tap away if you want to start fresh. Tap any ? for a plain-English explanation. Have fun.",
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

    /// Same idea, for anchors that live inside a `.sheet` (e.g. the Effects
    /// panel): sheet content is a separate view hierarchy, so "moshRoot"
    /// isn't reachable there — `.global` is the one coordinate space shared
    /// by every hierarchy, sheet or not.
    func coachAnchorGlobal(_ anchor: CoachAnchor) -> some View {
        overlay(GeometryReader { geo in
            Color.clear.preference(key: CoachFrameKey.self,
                                   value: [anchor: geo.frame(in: .global)])
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
    /// nil = the root-hosted instance (shows every stop with no panel
    /// requirement, i.e. all 12 original stops). A specific panel = the
    /// instance hosted inside that panel's sheet (shows only stops that
    /// require it, e.g. the 3 Effects-panel Finisher stops).
    var hostPanel: AppModel.Panel? = nil

    @State private var lastTarget: CGRect? = nil

    var body: some View {
        // Both CoachOverlay instances are instrumented and self-identify in
        // the trace message: "root" is the RootView-hosted overlay (drawer
        // stops), "sheet:Effects" is the one hosted inside the Effects panel
        // for the Finisher-effect coach marks. Seeing both lanes rebuild is
        // how you confirm the sheet-hosted delay path is live.
        perfBody(Perf.coach, "CoachOverlay.body",
                 hostPanel.map { "sheet:\($0.rawValue)" } ?? "root") {
        if let index = app.coachIndex, index < CoachScript.stops.count,
           CoachScript.stops[index].panel == hostPanel {
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
                            .animation(Theme.springSlow, value: target)
                            .allowsHitTesting(false)
                        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                            .stroke(Theme.accent, lineWidth: 2)
                            .frame(width: target.width, height: target.height)
                            .position(x: target.midX, y: target.midY)
                            .animation(Theme.springSlow, value: target)
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
        // Sheet-hosted instances (hostPanel != nil) publish/consume via
        // .global — "moshRoot" isn't reachable from inside a .sheet. The
        // root instance keeps using moshRoot -> overlay-local as before.
        // With ignoresSafeArea the overlay's origin is (0,0) and this is the
        // identity, but converting explicitly keeps the ring glued to its
        // target even if the overlay is ever re-hosted.
        let localFrame = hostPanel != nil ? geo.frame(in: .global) : geo.frame(in: .named("moshRoot"))
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
        .animation(Theme.springSlow, value: target)
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
    static let sections = ["Basics", "Glitch Styles", "Rhythm & Timing",
                           "Sources & Mixing", "Visual Effects", "3D", "Output"]

    static func demos(in section: String) -> [DemoCard] {
        all.filter { $0.section == section }
    }

    static let all: [DemoCard] = basics + moshModes + rhythm + sourcesMixing
        + visualEffects + threeD + output

    // MARK: Basics

    private static let basics: [DemoCard] = [
        DemoCard(id: "clean", section: "Basics", title: "Clean (No Glitch)",
                 blurb: "Your baseline: pure camera, no effects.") { app in
            app.selectMode(.clean)
            app.activeTip = "This is your baseline. No effects — pure camera. Hold the Reset button anytime to peek back here without losing your glitch."
        },
        DemoCard(id: "firstsmear", section: "Basics", title: "Your First Smear",
                 blurb: "Watch frames stretch into trails.") { app in
            app.selectMode(.classicSmear)
            app.openDrawer(.right)
            app.activeTip = "Move slowly in front of the camera. Watch the trail follow you. The longer you hold still, the more the last frame freezes into the canvas."
        },
        DemoCard(id: "reset", section: "Basics", title: "Reset to Clean",
                 blurb: "Snap back to a clean frame.") { app in
            app.selectMode(.classicSmear)
            app.activeTip = "Tap Reset to snap back to a clean frame so your next glitch starts fresh. Hold Reset to peek without resetting."
        },
        DemoCard(id: "saving", section: "Basics", title: "Saving Your Work",
                 blurb: "Record video or snapshot a frame. Free clips are watermarked.") { app in
            app.activeTip = "Tap the record button to capture video; tap the camera icon for a single frame. Both appear in My Clips with a small watermark until you unlock — unlocking removes it and lets you save and share."
        },
    ]

    // MARK: Mosh Modes

    private static let moshModes: [DemoCard] = [
        DemoCard(id: "bloom", section: "Glitch Styles", title: "Burst",
                 blurb: "Moving areas erupt with frozen detail.") { app in
            app.selectMode(.bloom)
            app.openDrawer(.right)
            app.highlightParam = .bloomThreshold
            app.activeTip = "Stay still, then move suddenly. Moving areas erupt with frozen detail. Lower Trigger = more sensitive."
        },
        DemoCard(id: "tbloom", section: "Glitch Styles", title: "Pulse Burst",
                 blurb: "Bursts fire on their own rhythm.",) { app in
            app.selectMode(.timedBloom)
            app.openDrawer(.right)
            app.highlightParam = .bloomRate
            app.activeTip = "Bursts fire automatically on a timer. Speed controls how often. Try a slow Speed with sudden movement between bursts."
        },
        DemoCard(id: "drift", section: "Glitch Styles", title: "Push",
                 blurb: "Push the whole frame with the XY pad.",) { app in
            app.selectMode(.drift)
            app.openDrawer(.right)
            app.activeTip = "The XY pad controls the direction pixels smear. Push everything to one corner. Great for slow hypnotic flows."
        },
        DemoCard(id: "mix", section: "Glitch Styles", title: "Blend",
                 blurb: "Blend fresh frames into the smear.",) { app in
            app.selectMode(.mixMosh)
            app.openDrawer(.right)
            app.activeTip = "Blend mixes fresh frames into the smear continuously. All the way left = frozen. All the way right = clean. Middle = the sweet spot."
        },
        DemoCard(id: "cross", section: "Glitch Styles", title: "Swap Motion",
                 blurb: "One source's motion drives the other's pixels.",) { app in
            app.selectMode(.crossMosh)
            app.activeTip = "Load two different sources in slot A and B (Inputs panel). Motion from one drives the pixels of the other. Flip the camera mid-glitch for an instant swap between front and rear."
        },
        DemoCard(id: "feedback", section: "Glitch Styles", title: "Tunnel",
                 blurb: "The canvas zooms and rotates into itself.",) { app in
            app.selectMode(.feedback)
            app.openDrawer(.right)
            app.activeTip = "The canvas zooms and rotates into itself every frame. Small zoom values create infinite tunnels. Color cycle makes it shift through the rainbow."
        },
        DemoCard(id: "flip", section: "Glitch Styles", title: "Camera Flip Smear",
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
            app.activeTip = "Tap the TAP button repeatedly in time with music. MoshPit locks to your rhythm. Everything time-synced from here uses this tempo."
        },
        DemoCard(id: "lfo", section: "Rhythm & Timing", title: "Rhythm Wave Basics",
                 blurb: "Make any parameter pulse automatically.",) { app in
            app.openSheet(.control)
            app.activeTip = "Rhythm wave 1 goes up and down in time with your tempo. Pick its shape and speed, then add a link in Links to make any control pulse automatically."
        },
        DemoCard(id: "rhythmwipe", section: "Rhythm & Timing", title: "Rhythmic Source Switching",
                 blurb: "Beat-synced cuts between A and B.",) { app in
            app.openSheet(.control)
            app.activeTip = "Load two clips or use camera + clip. Link Rhythm wave 1 to A ↔ B with a square wave. Your sources now cut on the beat."
        },
        DemoCard(id: "strobe", section: "Rhythm & Timing", title: "Strobe Flash",
                 blurb: "Beat-gated blackout/whiteout flashes.",) { app in
            app.openSheet(.control)
            app.activeTip = "Set Flash beat to a rhythm wave. A square wave at 1/2 = a flash on every other beat. Keep Flash safety ON unless you know your audience."
        },
    ]

    // MARK: Sources & Mixing

    private static let sourcesMixing: [DemoCard] = [
        DemoCard(id: "loadvideo", section: "Sources & Mixing", title: "Load a Video",
                 blurb: "Any clip from Photos becomes a mosh source.") { app in
            app.openSheet(.sources)
            app.activeTip = "Tap Video under slot A to load a clip from your Photos library. It loops automatically and feeds the mosh engine just like the camera."
        },
        DemoCard(id: "reverse", section: "Sources & Mixing", title: "Reverse Playback",
                 blurb: "Play any clip backwards, mid-mosh.",) { app in
            app.openSheet(.sources)
            app.activeTip = "Toggle Reverse on any video slot to play it backwards. Try it mid-mosh — the smear reverses direction as the movement flips."
        },
        DemoCard(id: "selfcross", section: "Sources & Mixing", title: "Self Cross-Mosh",
                 blurb: "A clip smears itself with its own motion.",) { app in
            app.openSheet(.sources)
            app.activeTip = "Load the same clip into both slot A and B, then pick Swap Motion. The video smears itself with its own motion. Desync the clips for stranger results."
        },
        DemoCard(id: "lumawipe", section: "Sources & Mixing", title: "Luma Wipe",
                 blurb: "Brightness-keyed transitions between sources.",) { app in
            app.openSheet(.sources)
            app.activeTip = "Set Fade style to the brightness option in Blend Sources. Bright areas switch to source B first, dark areas last. Link a rhythm wave to A ↔ B for beat-synced wipes."
        },
        DemoCard(id: "videomod", section: "Sources & Mixing", title: "Video as Controller",
                 blurb: "A hidden clip drives your parameters.",) { app in
            app.openSheet(.control)
            app.activeTip = "Load a clip into the MOD slot — it never appears on screen. Its brightness and movement control anything you link it to in Links. A flickering fire clip in MOD = fire-driven bursts."
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
            app.activeTip = "Invert flips all colors. Combined with Burst it creates a negative-space explosion effect."
        },
        DemoCard(id: "duotone", section: "Visual Effects", title: "Two-tone",
                 blurb: "Two-color grade over any mosh.",) { app in
            app.openSheet(.effects)
            app.activeTip = "Two-tone maps your image to two colors — one for darks, one for lights. Pick Rainbow instead and link a rhythm wave to Color spin for continuous color cycling."
        },
        DemoCard(id: "echo", section: "Visual Effects", title: "Echo Trails",
                 blurb: "Ghosts of past frames, keyed by brightness.") { app in
            app.openSheet(.effects)
            app.activeTip = "Echo layers past frames behind the current one, keyed by brightness. More layers = longer ghosting. Combined with Smear it creates deep time-based trails."
        },
        DemoCard(id: "pixelsort", section: "Visual Effects", title: "Pixel Streaks",
                 blurb: "Cascading streaks along brightness edges.") { app in
            app.openSheet(.effects)
            app.activeTip = "Pixel Streaks sorts pixels along brightness edges. High Cutoff = subtle streaks along bright edges only. Low Cutoff = whole regions cascade."
        },
        DemoCard(id: "gridwarp", section: "Visual Effects", title: "Mesh Warp",
                 blurb: "A drifting mesh displaces every cell.") { app in
            app.params.set(.gridWarpEnabled, 1, origin: .ui)
            app.openSheet(.effects)
            app.activeTip = "Mesh Warp pushes your frame through a drifting cell mesh. Link a rhythm wave to Drift speed for a pulsing warp."
        },
        DemoCard(id: "spreadsheet", section: "Visual Effects", title: "Spreadsheet Look",
                 blurb: "Your glitch, quantized into a ledger.") { app in
            app.params.set(.spreadsheetEnabled, 1, origin: .ui)
            app.openSheet(.effects)
            app.activeTip = "Spreadsheet Look averages each cell into a flat color under fake spreadsheet menus. Try the Reveal options for a wipe-in."
        },
        DemoCard(id: "trackinghud", section: "Visual Effects", title: "Tracker Dots",
                 blurb: "Decorative motion-tracking dots and readouts.") { app in
            app.params.set(.trackingHUDEnabled, 1, origin: .ui)
            app.openSheet(.effects)
            app.activeTip = "Tracker Dots scatters dots along real movement with number readouts — pure sci-fi decoration."
        },
    ]

    // MARK: 3D

    private static let threeD: [DemoCard] = [
        DemoCard(id: "cloud", section: "3D", title: "Point Cloud",
                 blurb: "Your glitch becomes floating dots.",) { app in
            app.params.set(.trace3D, 1, origin: .ui)
            app.params.set(.traceMode, 0, origin: .ui)   // points
            app.openSheet(.threeD)
            app.activeTip = "Your glitched video becomes a cloud of glowing dots pushed out by brightness. Drag to orbit, pinch to zoom."
        },
        DemoCard(id: "wireframe", section: "3D", title: "Wireframe Face",
                 blurb: "Your video as a displaced grid mesh.",) { app in
            app.params.set(.trace3D, 1, origin: .ui)
            app.params.set(.traceMode, 1, origin: .ui)   // wireframe
            app.openSheet(.threeD)
            app.activeTip = "The mesh shows your video as a grid. Depth pushes bright areas toward you."
        },
        DemoCard(id: "object", section: "3D", title: "Textured Object",
                 blurb: "Wrap the mosh around a sphere or torus.",) { app in
            app.params.set(.trace3D, 1, origin: .ui)
            app.openSheet(.threeD)
            app.activeTip = "Set Shape to Sphere or Torus — your glitched video wraps around it like a skin. Dots on a torus are particularly strange."
        },
        DemoCard(id: "bloom3d", section: "3D", title: "3D + Bloom",
                 blurb: "Eruptions across the geometry surface.",) { app in
            app.activeTip = "Switch to Burst while in 3D dots. Bursts appear on the surface. Add Auto-spin for a self-animating visual instrument."
        },
    ]

    // MARK: Output

    private static let output: [DemoCard] = [
        DemoCard(id: "record", section: "Output", title: "Record a Performance",
                 blurb: "Full-resolution capture of everything.") { app in
            app.activeTip = "Tap Record before you start. Tap again to stop; the clip appears in My Clips. Recordings capture everything including mirror, color and 3D. Free clips have a small watermark; unlocking removes it and enables saving and sharing."
        },
        DemoCard(id: "ndi", section: "Output", title: "NDI to Resolume",
                 blurb: "Stream live into your VJ setup.",) { app in
            app.activeTip = "Start NDI in Record & Stream. Accept the local network permission prompt. Open Resolume on the same Wi-Fi and look for MoshPit in the NDI sources. Your glitch streams live, clean, to your VJ setup."
        },
        DemoCard(id: "automation", section: "Output", title: "Automation",
                 blurb: "Record knob moves, replay them anywhere.",) { app in
            app.openSheet(.automation)
            app.activeTip = "Hit Record my moves in Record Moves, perform your slider changes, then stop. Play it back over any source — your performance is now a reusable loop."
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

    private let keys = Labels.shortcuts

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
                    Button("Replay welcome") {
                        dismiss()
                        app.showCheatSheet = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            app.presentWelcome()
                        }
                    }
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
