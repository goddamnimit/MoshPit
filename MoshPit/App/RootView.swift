import SwiftUI
import MetalKit

// MARK: - Root: fullscreen canvas + edge drawers

/// Resting state: video, top strip, bottom bar, two edge handles. Everything
/// else lives in drawers — Parameters on the right (dwell), Modes & Panels on
/// the left (quick in-and-out).
struct RootView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var lastInteraction = Date()
    @State private var lastDrawerInteraction = Date()
    @State private var recordStart: Date?

    // Drawer motion: 0 = closed, 1 = open. Interactive drags write these
    // directly (pure state mutation; the render loop never blocks on it).
    @State private var leftProgress: CGFloat = 0
    @State private var rightProgress: CGFloat = 0
    @State private var anchorFrames: [CoachAnchor: CGRect] = [:]

    private let idleTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static let edgeZone: CGFloat = 24
    private static let drawerAutoClose: TimeInterval = 20

    var body: some View {
        GeometryReader { geo in
            let leftWidth = geo.size.width * 0.75
            let rightWidth = geo.size.width * 0.52
            ZStack {
                Color.black.ignoresSafeArea()
                if app.ctx != nil {
                    MoshMetalView().ignoresSafeArea().coachAnchor(.canvas)
                } else {
                    Text("Metal is unavailable on this device.")
                        .font(Theme.label).foregroundStyle(Theme.textSecondary)
                }

                // Tap-to-wake (and tap-outside-closes-drawer).
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if app.openDrawer != nil { setDrawer(nil) } else { wake() }
                    }

                // 3D orbit/zoom — center-screen drags only; the edge zones
                // win at the edges, so canvas drags never open drawers and
                // edge swipes never orbit.
                if app.params.bool(.trace3D), app.activePanel == nil,
                   !app.showCheatSheet, app.openDrawer == nil {
                    OrbitGestureLayer(size: geo.size, onWake: wake)
                        .padding(.horizontal, Self.edgeZone)
                }

                chromeBars

                // Edge swipe zones (only while no drawer is open).
                if app.openDrawer == nil {
                    edgeZones(leftWidth: leftWidth, rightWidth: rightWidth)
                }

                // Scrim behind an open/partially open drawer; tap closes.
                let progress = max(leftProgress, rightProgress)
                if progress > 0.01 {
                    Color.black.opacity(0.25 * progress)
                        .ignoresSafeArea()
                        .onTapGesture { setDrawer(nil) }
                }

                LeftDrawer(onSelect: { setDrawer(nil) },
                           onTouch: { lastDrawerInteraction = Date() })
                    .frame(width: leftWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .offset(x: -leftWidth * (1 - leftProgress))
                    .allowsHitTesting(leftProgress > 0.9)

                RightDrawer(width: rightWidth,
                            onTouch: { lastDrawerInteraction = Date() })
                    .frame(width: rightWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .offset(x: rightWidth * (1 - rightProgress))
                    .allowsHitTesting(rightProgress > 0.9)

                // Swipe-close strips on an open drawer's inner edge (drawer
                // content is inset from it, so ParamRow drags never collide).
                if leftProgress > 0.9 {
                    closeStrip(side: .left, width: leftWidth)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .offset(x: leftWidth - Self.edgeZone)
                }
                if rightProgress > 0.9 {
                    closeStrip(side: .right, width: rightWidth)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .offset(x: -(rightWidth - Self.edgeZone))
                }

                edgeHandles

                TipCardView()
                CoachOverlay(frames: anchorFrames)

                // Snapshot toast (saved / permission denied) — non-blocking.
                if let toast = app.toast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(Theme.label).foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, Theme.g2)
                            .padding(.vertical, Theme.g1)
                            .scrim(strong: true)
                            .padding(.bottom, Theme.g6 * 2)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                // Saved/Share toast (post-recording + snapshot) — an overlay
                // above the bottom bar, NOT a sheet: the canvas and drawers
                // stay fully interactive while it's up.
                if let shareToast = app.shareToast {
                    VStack {
                        Spacer()
                        ShareToastView(item: shareToast)
                            .padding(.bottom, Theme.g6 * 2)
                    }
                    .transition(.opacity)
                }

                // Shutter flash — topmost, brief, purely visual.
                if app.snapshotFlash {
                    Color.white.ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                KeyCommandBridge().frame(width: 0, height: 0)
            }
        }
        .onPreferenceChange(CoachFrameKey.self) { anchorFrames = $0 }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $app.showCheatSheet) { HelpSheet() }
        .sheet(isPresented: $app.showDemoSheet) { DemoSheet() }
        .sheet(item: $app.activePanel) { panel in
            PanelSheet(panel: panel)
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .fullScreenCover(item: $app.playbackClip) { clip in
            ClipPlaybackView(clip: clip)
        }
        .onChange(of: scenePhase) { _, phase in app.scenePhaseChanged(phase) }
        .onChange(of: app.openDrawer) { _, side in
            lastDrawerInteraction = Date()
            withAnimation(.spring(duration: 0.3)) {
                leftProgress = side == .left ? 1 : 0
                rightProgress = side == .right ? 1 : 0
            }
        }
        .onReceive(idleTick) { _ in
            let now = Date()
            if app.openDrawer != nil,
               now.timeIntervalSince(lastDrawerInteraction) > Self.drawerAutoClose {
                setDrawer(nil)   // drawers auto-close after 20s idle inside
            }
            guard !app.performanceMode, app.activePanel == nil, !app.showCheatSheet,
                  now.timeIntervalSince(lastInteraction) > Theme.idleTimeout
            else { return }
            withAnimation(Theme.fade) { app.performanceMode = true }
        }
        .onAppear {
            applyDebugLaunchArguments()
            if !UserDefaults.standard.bool(forKey: CoachScript.hasSeenKey) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if app.coachIndex == nil { app.startTutorial() }
                }
            }
        }
    }

    // MARK: chrome

    private var chromeBars: some View {
        VStack(spacing: 0) {
            if !app.performanceMode {
                TopStrip()
                    .padding(.horizontal, Theme.g2)
                    .padding(.top, Theme.g1)
                    .transition(.opacity)
            }
            RecordingTimePill(recordStart: recordStart)
                .padding(.top, Theme.g1)
            Spacer()
            if !app.performanceMode {
                MainControlRow(recordStart: $recordStart)
                    .padding(.bottom, Theme.g1)
                    .transition(.opacity)
            }
        }
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in wake() })
    }

    /// Slim always-visible grabbers hugging each edge — they dim with
    /// auto-hide but never disappear, keeping the drawers discoverable.
    private var edgeHandles: some View {
        HStack {
            if leftProgress < 0.1 { handlePill.coachAnchor(.leftHandle) }
            Spacer()
            if rightProgress < 0.1 { handlePill.coachAnchor(.rightHandle) }
        }
        .opacity(app.performanceMode ? 0.3 : 0.7)
        .allowsHitTesting(false)   // visual only; the edge zones do the work
        .animation(Theme.fade, value: app.performanceMode)
    }

    private var handlePill: some View {
        Capsule()
            .fill(Theme.textSecondary)
            .frame(width: Theme.gHalf, height: Theme.g6)
    }

    /// 24pt interactive strips on both edges: drag tracks the finger, tap
    /// opens outright. Narrow on purpose — center-canvas gestures (orbit,
    /// tap-to-wake) never collide with them.
    private func edgeZones(leftWidth: CGFloat, rightWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: Self.edgeZone)
                .contentShape(Rectangle())
                .onTapGesture { setDrawer(.left) }
                .gesture(DragGesture(minimumDistance: 4)
                    .onChanged { g in
                        leftProgress = min(1, max(0, g.translation.width / leftWidth))
                    }
                    .onEnded { g in
                        let open = leftProgress > 0.3
                            || g.predictedEndTranslation.width > leftWidth * 0.5
                        setDrawer(open ? .left : nil)
                    })
            Spacer()
            Color.clear
                .frame(width: Self.edgeZone)
                .contentShape(Rectangle())
                .onTapGesture { setDrawer(.right) }
                .gesture(DragGesture(minimumDistance: 4)
                    .onChanged { g in
                        rightProgress = min(1, max(0, -g.translation.width / rightWidth))
                    }
                    .onEnded { g in
                        let open = rightProgress > 0.3
                            || -g.predictedEndTranslation.width > rightWidth * 0.5
                        setDrawer(open ? .right : nil)
                    })
        }
        .ignoresSafeArea()
    }

    private func closeStrip(side: DrawerSide, width: CGFloat) -> some View {
        Color.clear
            .frame(width: Self.edgeZone)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { g in
                    lastDrawerInteraction = Date()
                    switch side {
                    case .left:
                        leftProgress = min(1, max(0, 1 + g.translation.width / width))
                    case .right:
                        rightProgress = min(1, max(0, 1 - g.translation.width / width))
                    }
                }
                .onEnded { _ in
                    let p = side == .left ? leftProgress : rightProgress
                    setDrawer(p > 0.7 ? side : nil)
                })
    }

    private func setDrawer(_ side: DrawerSide?) {
        wake()
        if app.openDrawer == side {
            // Same target (or already nil): still settle any partial drag.
            withAnimation(.spring(duration: 0.3)) {
                leftProgress = side == .left ? 1 : 0
                rightProgress = side == .right ? 1 : 0
            }
            return
        }
        app.openDrawer(side)
    }

    private func wake() {
        lastInteraction = Date()
        if app.performanceMode {
            withAnimation(Theme.fade) { app.performanceMode = false }
        }
    }

    /// UI-test / screenshot hooks (DEBUG only; stripped from Release).
    private func applyDebugLaunchArguments() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.count > 1 {
            // Any debug-hook launch marks the tutorial as seen (deterministic
            // screenshots) — unless explicitly requesting a coach stop.
            UserDefaults.standard.set(true, forKey: CoachScript.hasSeenKey)
        }
        if let i = args.firstIndex(of: "-coach"), i + 1 < args.count,
           let n = Int(args[i + 1]), n < CoachScript.stops.count {
            // Jump straight to stop n: open the drawer first, spotlight only
            // after its spring settles (same sequencing as advanceTutorial).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                app.openDrawer = CoachScript.stops[n].drawer
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(Theme.fade) { app.coachIndex = n }
                }
            }
        }
        if args.contains("-demos") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { app.showDemoSheet = true }
        }
        if args.contains("-demotip") {   // screenshot hook: tip card over canvas
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                app.activeTip = "Move slowly in front of the camera. Watch the trail follow you. The longer you hold still, the more the last frame freezes into the canvas."
            }
        }
        if args.contains("-help") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { app.showCheatSheet = true }
        }
        if let i = args.firstIndex(of: "-panel"), i + 1 < args.count,
           let panel = AppModel.Panel.allCases.first(where: {
               $0.rawValue.lowercased() == args[i + 1].lowercased()
           }) {
            // Through openSheet, after any -drawer hook: exercises (and
            // screenshots) the drawer-closes-before-sheet exclusivity rule.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                app.openSheet(panel)
            }
        }
        if let i = args.firstIndex(of: "-trace"), i + 1 < args.count {
            app.params.set(.trace3D, 1, origin: .system)
            let modes = ["point": 0, "wire": 1, "solid": 2]
            app.params.set(.traceMode, Float(modes[args[i + 1]] ?? 0), origin: .system)
        }
        if let i = args.firstIndex(of: "-object"), i + 1 < args.count,
           let idx = TracePrimitive.names.firstIndex(of: args[i + 1].uppercased()) {
            app.params.set(.tracePrimitive, Float(idx), origin: .system)
        }
        if args.contains("-testpattern") {
            app.sources?.setTestPattern(slot: .b, inverted: true)   // distinct B
        }
        if let i = args.firstIndex(of: "-wipe"), i + 1 < args.count,
           let v = Float(args[i + 1]) {
            app.params.set(.wipeMode, 1, origin: .system)           // luma wipe
            app.params.set(.mixCrossfade, v, origin: .system)
        }
        if args.contains("-fit") { app.previewFill = false }
        if let i = args.firstIndex(of: "-mirror"), i + 1 < args.count {
            let modes = ["h": 1, "v": 2, "quad": 3]
            app.params.set(.mirrorMode, Float(modes[args[i + 1]] ?? 0), origin: .system)
        }
        if let i = args.firstIndex(of: "-colormode"), i + 1 < args.count {
            let modes = ["invert": 1, "duotone": 2, "hueshift": 3]
            app.params.set(.colorMode, Float(modes[args[i + 1]] ?? 0), origin: .system)
        }
        if args.contains("-snapflash") {   // frozen shutter flash for screenshots
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                app.snapshotFlash = true
            }
        }
        if args.contains("-reverse") {     // with -testvideo: reverse slot A
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                app.toggleReverse()
            }
        }
        if let i = args.firstIndex(of: "-mode"), i + 1 < args.count {
            let m = MoshMode.allCases.first {
                $0.title.lowercased() == args[i + 1].lowercased()
                || $0.shortTitle.lowercased() == args[i + 1].lowercased()
            }
            if let m { app.params.set(.mode, Float(m.rawValue), origin: .system) }
        }
        if args.contains("-demolfo"),
           !app.modMatrix.routes.contains(where: { $0.source == .lfo1 }) {
            app.modMatrix.routes.append(
                ModRoute(source: .lfo1, destination: .mixCrossfade, amount: 0.8))
        }
        if let i = args.firstIndex(of: "-drawer"), i + 1 < args.count {
            switch args[i + 1] {
            case "left": app.openDrawer = .left
            case "right": app.openDrawer = .right
            case "halfright": rightProgress = 0.5   // mid-swipe shot
            case "halfleft": leftProgress = 0.5
            default: break
            }
        }
        if args.contains("-landscape") {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }.first
            scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
        }
        if args.contains("-hidden") {
            app.performanceMode = true
            lastInteraction = .distantFuture
        }
        #endif
    }
}

// MARK: - Right drawer: Parameters (XY pad + ParamRows)

private struct RightDrawer: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var ticker = RefreshTicker.shared
    let width: CGFloat
    let onTouch: () -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: Theme.g1) {
                if app.params.mode == .clean {
                    Text("CLEAN PASSTHROUGH")
                        .font(Theme.mono).foregroundStyle(Theme.textPrimary)
                        .padding(.top, Theme.g4)
                    Text("No parameters — the source renders untouched. Pick a mode in the left drawer to start moshing.")
                        .font(Theme.labelSmall).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.g1)
                } else {
                    XYPad()
                        .frame(width: width - Theme.g4 - Theme.g3,
                               height: width - Theme.g4 - Theme.g3)
                        .coachAnchor(.xyPad)
                    ModeParamList(compact: true)
                        .coachAnchor(.paramRows)
                }
            }
            // Inset from the drawer's inner edge: the close-swipe strip
            // lives there; rows must not reach it.
            .padding(.leading, Theme.g4)
            .padding(.trailing, Theme.g2)
            .padding(.vertical, Theme.g6)
        }
        .background(Theme.scrimStrong)
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: Theme.radius, bottomLeadingRadius: Theme.radius))
        .ignoresSafeArea(edges: .vertical)
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in onTouch() })
    }
}

/// The contextual ParamRows for the active mode (drawer-only now). Same
/// ParamRow widget, same ParameterIDs — bindings unchanged by the move.
struct ModeParamList: View {
    @EnvironmentObject var app: AppModel
    var compact = false

    private var rows: [(ParameterID, String, [String]?)] {
        var r: [(ParameterID, String, [String]?)]
        switch app.params.mode {
        case .clean:
            return []
        case .classicSmear, .drift, .crossMosh:
            r = [(.motionGain, "Gain", nil), (.heal, "Heal", nil)]
        case .bloom:
            r = [(.bloomRate, "Rate", nil), (.bloomThreshold, "Thresh", nil)]
        case .timedBloom:
            r = [(.bloomRate, "Rate", nil), (.bloomAngle, "Angle", nil),
                 (.bloomBias, "Bias", nil), (.bloomDecay, "Decay", nil)]
        case .mixMosh:
            r = [(.mixAmount, "Mix", nil), (.motionGain, "Gain", nil)]
        case .feedback:
            r = [(.feedbackZoom, "Zoom", nil), (.feedbackRotate, "Rotate", nil),
                 (.feedbackHue, "Hue", nil)]
        }
        r.append((.blockSize, "Block", kBlockSizes.map(String.init)))
        return r
    }

    var body: some View {
        VStack(spacing: Theme.g1) {
            ForEach(rows, id: \.0) { row in
                ParamRow(id: row.0, label: row.1, steps: row.2, compact: compact)
            }
        }
    }
}

// MARK: - Left drawer: modes + panel triggers

private struct LeftDrawer: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var ticker = RefreshTicker.shared
    let onSelect: () -> Void
    let onTouch: () -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: Theme.g1) {
                modeButtons.coachAnchor(.modeList)
                Rectangle().fill(Theme.stroke).frame(height: 1)
                    .padding(.vertical, Theme.g1)
                panelButtons.coachAnchor(.panelTriggers)
            }
            .padding(.leading, Theme.g2)
            .padding(.trailing, Theme.g4)   // inset from the close strip
            .padding(.vertical, Theme.g6)
        }
        .background(Theme.scrimStrong)
        .clipShape(UnevenRoundedRectangle(
            bottomTrailingRadius: Theme.radius, topTrailingRadius: Theme.radius))
        .ignoresSafeArea(edges: .vertical)
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in onTouch() })
    }

    private var modeButtons: some View {
        VStack(spacing: Theme.g1) {
                ForEach(MoshMode.displayOrder, id: \.rawValue) { mode in
                    Button {
                        Theme.haptic()
                        app.selectMode(mode)
                        onSelect()   // mode switch is quick: auto-close
                    } label: {
                        Text(mode.shortTitle).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(MoshButtonStyle(size: .standard,
                                                 selected: app.params.mode == mode,
                                                 fillsWidth: true))
                }
        }
    }

    private var panelButtons: some View {
        VStack(spacing: Theme.g1) {
            ForEach(AppModel.Panel.allCases) { panel in
                Button {
                    app.openSheet(panel)   // closes this drawer first
                    onSelect()
                } label: {
                    Label(panel.rawValue, systemImage: panel.icon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(MoshButtonStyle(size: .standard, fillsWidth: true))
            }
        }
    }
}

// MARK: - Top strip: HUD pill + utility icons

private struct TopStrip: View {
    @EnvironmentObject var app: AppModel
    #if DEBUG
    @State private var hudExpanded =
        ProcessInfo.processInfo.arguments.contains("-hudx")   // screenshot hook
    #else
    @State private var hudExpanded = false
    #endif

    var body: some View {
        HStack(alignment: .top, spacing: Theme.g1) {
            HUDPill(expanded: $hudExpanded).coachAnchor(.hudPill)
            Spacer()
            IconButton(systemName: app.previewFill
                        ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
                       selected: false) {
                app.previewFill.toggle()
            }
            .accessibilityLabel(app.previewFill ? "Fit preview" : "Fill preview")
            FlipCameraButton()
            IconButton(systemName: "questionmark",
                       selected: app.showCheatSheet) {
                app.showCheatSheet.toggle()
            }
        }
    }
}

/// Camera flip — standard camera-app pattern. Disabled (40%) when no slot
/// holds a camera or the opposite device doesn't exist (e.g. simulator).
private struct FlipCameraButton: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var ticker = RefreshTicker.shared

    var body: some View {
        let enabled = app.sources?.canFlipCamera == true
        IconButton(systemName: "arrow.triangle.2.circlepath.camera") {
            guard enabled else { return }
            Theme.haptic()
            app.flipCamera()
        }
        .opacity(enabled ? 1 : Theme.disabledOpacity)
        .disabled(!enabled)
        .accessibilityLabel("Flip camera")
    }
}

private struct HUDPill: View {
    @EnvironmentObject var app: AppModel
    @Binding var expanded: Bool

    var body: some View {
        Button {
            withAnimation(Theme.fade) { expanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: Theme.gHalf) {
                Text(String(format: "%3.0f FPS", app.stats.fps))
                    .font(Theme.mono).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).fixedSize()
                if expanded {
                    Group {
                        Text(String(format: "gpu %6.2f ms", app.stats.gpuMS))
                        Text(String(format: "est %6.2f ms", app.stats.estimatorMS))
                        Text(String(format: "|v| %6.2f px", app.stats.meanMotionMag))
                    }
                    .font(Theme.monoSmall).foregroundStyle(Theme.textSecondary)
                    if app.stats.thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                        Text("THERMAL · est res ↓")
                            .font(Theme.monoSmall).foregroundStyle(Theme.accent)
                    }
                }
            }
            .monospacedDigit()
            .padding(.horizontal, Theme.g2)
            .padding(.vertical, Theme.g1)
        }
        .buttonStyle(.plain)
        .scrim()
        .frame(minHeight: Theme.buttonSmall)
    }
}

/// Elapsed-time pill shown top-center while recording.
private struct RecordingTimePill: View {
    let recordStart: Date?

    var body: some View {
        if let recordStart {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let s = max(0, Int(context.date.timeIntervalSince(recordStart)))
                Label(String(format: "%02d:%02d", s / 60, s % 60),
                      systemImage: "record.circle")
                    .font(Theme.mono).monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, Theme.g2)
                    .padding(.vertical, Theme.g1)
                    .background(Theme.accent.opacity(0.9))
                    .clipShape(Capsule())
            }
            .transition(.opacity)
        }
    }
}

// MARK: - Bottom bar: Reset | RECORD | Bloom

private struct MainControlRow: View {
    @EnvironmentObject var app: AppModel
    @Binding var recordStart: Date?

    var body: some View {
        HStack(spacing: Theme.g3) {
            HoldResetButton().coachAnchor(.resetButton)
            RecordButton(recordStart: $recordStart).coachAnchor(.recordButton)

            Button {
                Theme.haptic()
                app.triggerBloom()
            } label: {
                Image(systemName: "sparkles")
                    .frame(width: Theme.buttonStandard - Theme.g2)
            }
            .buttonStyle(MoshButtonStyle(size: .standard))
            .coachAnchor(.bloomButton)

            // Camera-app style snapshot: saves the post-effect, post-mirror
            // canvas to Photos — what you see is what you save.
            Button {
                app.snapshot()
            } label: {
                Image(systemName: "camera")
                    .frame(width: Theme.buttonStandard - Theme.g2)
            }
            .buttonStyle(MoshButtonStyle(size: .standard))
            .accessibilityLabel("Save frame to Photos")
        }
    }
}

/// Reset with hold-to-preview: tap = manual I-frame; press-and-hold shows
/// clean passthrough while held and snaps back to the mosh (canvas
/// preserved) on release.
private struct HoldResetButton: View {
    @EnvironmentObject var app: AppModel
    @State private var pressed = false
    @State private var holdFired = false

    var body: some View {
        Image(systemName: app.holdClean ? "eye" : "arrow.counterclockwise")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .frame(width: Theme.buttonStandard + Theme.g2, height: Theme.buttonStandard)
            .background(app.holdClean ? Theme.accent : Theme.scrim)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1))
            .scaleEffect(pressed ? Theme.pressedScale : 1)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.3, maximumDistance: Theme.g4) {
                // fires when the hold threshold passes
            } onPressingChanged: { isPressing in
                pressed = isPressing
                if isPressing {
                    holdFired = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if pressed {
                            holdFired = true
                            Theme.haptic()
                            app.holdClean = true
                        }
                    }
                } else {
                    if app.holdClean { app.holdClean = false }
                    else if !holdFired { app.reset() }   // short tap = reset
                }
            }
            .accessibilityLabel("Reset (hold to preview clean)")
    }
}

/// The unmissable 56pt record button — hollow ring idle, filled red square
/// while recording, exactly like the system Camera.
private struct RecordButton: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var ticker = RefreshTicker.shared
    @Binding var recordStart: Date?

    var body: some View {
        let recording = app.recorder?.isRecording == true
        Button {
            Theme.haptic()
            app.toggleRecord()
            withAnimation(Theme.fade) {
                recordStart = recording ? nil : Date()
            }
        } label: {
            ZStack {
                Circle().stroke(Theme.textPrimary, lineWidth: 3)
                    .frame(width: Theme.buttonLarge, height: Theme.buttonLarge)
                if recording {
                    RoundedRectangle(cornerRadius: Theme.gHalf)
                        .fill(Theme.accent)
                        .frame(width: Theme.g3, height: Theme.g3)
                } else {
                    Circle().fill(Theme.accent)
                        .frame(width: Theme.buttonLarge - Theme.g1,
                               height: Theme.buttonLarge - Theme.g1)
                }
            }
            .frame(width: Theme.buttonLarge, height: Theme.buttonLarge)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(recording ? "Stop recording" : "Record")
    }
}

/// Saved/Share toast row: message + "Saved" (dismiss) + "Share" (activity
/// sheet with the artifact's FILE URL). Auto-dismisses after 4s.
private struct ShareToastView: View {
    @EnvironmentObject var app: AppModel
    let item: ShareToast

    var body: some View {
        HStack(spacing: Theme.g2) {
            Text(item.message)
                .font(Theme.label)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            Button { app.dismissShareToast() } label: {
                Text("Saved").padding(.horizontal, Theme.g1)
            }
            .buttonStyle(MoshButtonStyle(size: .small))
            if let url = item.shareURL {
                Button {
                    app.dismissShareToast()
                    ShareSheetPresenter.present(fileURL: url)
                } label: {
                    Text("Share").padding(.horizontal, Theme.g1)
                }
                .buttonStyle(MoshButtonStyle(size: .small, selected: true))
            }
        }
        .padding(.horizontal, Theme.g2)
        .padding(.vertical, Theme.g1)
        .scrim(strong: true)
        .padding(.horizontal, Theme.g2)
    }
}

/// Plain press feedback for custom-drawn controls (record button).
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? Theme.pressedScale : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - ParamRow (whole-row drag surface)

/// Pro-camera-style parameter row: the WHOLE 44pt row is the drag surface.
/// Horizontal pan adjusts the value; vertical distance from the initial touch
/// scales sensitivity (farther = finer). Double-tap resets to default.
/// `compact` (drawer width): tighter value column, truncated label — the full
/// name surfaces while the row is being dragged.
struct ParamRow: View {
    @EnvironmentObject var app: AppModel
    let id: ParameterID
    let label: String
    var steps: [String]? = nil
    var compact = false

    @State private var dragStartValue: Float?
    @State private var fineFactor: Float = 1

    /// Screenshot hook (-dragdemo): presents one row in its mid-drag state.
    private var demoDrag: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-dragdemo") && id == .motionGain
        #else
        return false
        #endif
    }

    private var isDragging: Bool { dragStartValue != nil || demoDrag }

    static func fraction(normalizedValue: Float) -> CGFloat {
        return CGFloat(min(max(normalizedValue, 0), 1))
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fraction = ParamRow.fraction(normalizedValue: app.params.getNormalized(id))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Theme.scrimBase.opacity(0.4))
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Theme.accent.opacity(isDragging ? 0.45 : 0.28))
                    .frame(width: w)
                    .mask(
                        HStack {
                            Rectangle()
                                .frame(width: max(Theme.g1, fraction * w))
                            Spacer(minLength: 0)
                        }
                    )
                HStack(spacing: Theme.g1) {
                    Text(label)
                        .font(Theme.label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: isDragging, vertical: false)
                        .foregroundStyle(app.midi.learnTarget == id
                                         ? Theme.accent : Theme.textPrimary)
                        .onLongPressGesture { app.midi.learnTarget = id }
                    if fineFactor < 1 || demoDrag {
                        Text("FINE")
                            .font(Theme.monoSmall).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: Theme.gHalf)
                    Text(valueText)
                        .font(compact ? Theme.monoSmall : Theme.mono).monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: compact ? Theme.g4 + Theme.g1 : Theme.g6,
                               alignment: .trailing)
                }
                .padding(.horizontal, compact ? Theme.g1 : Theme.g2)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .stroke(app.highlightParam == id ? Theme.accent : Theme.stroke,
                        lineWidth: app.highlightParam == id ? 2 : 1))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                Theme.haptic()
                app.params.set(id, id.defaultValue, origin: .ui)
            }
            .gesture(DragGesture(minimumDistance: Theme.gHalf)
                .onChanged { g in
                    if dragStartValue == nil {
                        dragStartValue = app.params.getNormalized(id)
                        if app.highlightParam == id { app.highlightParam = nil }
                    }
                    // Fine-adjust: vertical distance from touch-down damps
                    // sensitivity (48pt away = half speed, and so on).
                    let dy = abs(Float(g.translation.height))
                    fineFactor = max(0.05, 1 / (1 + dy / Float(Theme.g6)))
                    let dx = Float(g.translation.width / w)
                    let n = min(max(dragStartValue! + dx * fineFactor, 0), 1)
                    if steps != nil {
                        let r = id.range
                        let value = (r.lowerBound + n * (r.upperBound - r.lowerBound)).rounded()
                        app.params.set(id, value, origin: .ui)
                    } else {
                        app.params.setNormalized(id, n, origin: .ui)
                    }
                }
                .onEnded { _ in dragStartValue = nil; fineFactor = 1 })
        }
        .frame(height: Theme.buttonStandard)
    }

    private var valueText: String {
        if let steps {
            return steps[min(steps.count - 1, max(0, Int(app.params.get(id))))]
        }
        return String(format: compact ? "%4.2f" : "%5.2f", app.params.get(id))
    }
}

// MARK: - XY pad (drawer-only): grid, crosshair, axis labels

struct XYPad: View {
    @EnvironmentObject var app: AppModel
    @State private var knob: CGPoint = .init(x: 0.5, y: 0.5)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Theme.scrim)
                Path { p in
                    for i in 1..<4 {
                        let f = CGFloat(i) / 4
                        p.move(to: .init(x: f * w, y: 0)); p.addLine(to: .init(x: f * w, y: h))
                        p.move(to: .init(x: 0, y: f * h)); p.addLine(to: .init(x: w, y: f * h))
                    }
                }
                .stroke(Theme.stroke, lineWidth: 0.5)
                Path { p in
                    p.move(to: .init(x: knob.x * w, y: 0)); p.addLine(to: .init(x: knob.x * w, y: h))
                    p.move(to: .init(x: 0, y: knob.y * h)); p.addLine(to: .init(x: w, y: knob.y * h))
                }
                .stroke(Theme.accent.opacity(0.5), lineWidth: 1)
                Circle().fill(Theme.accent)
                    .frame(width: Theme.g2, height: Theme.g2)
                    .position(x: knob.x * w, y: knob.y * h)
                Text(axisLabels.x)
                    .font(Theme.monoSmall).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, Theme.gHalf)
                Text(axisLabels.y)
                    .font(Theme.monoSmall).foregroundStyle(Theme.textSecondary)
                    .rotationEffect(.degrees(-90))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.leading, -Theme.g1)
            }
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let x = min(max(g.location.x / w, 0), 1)
                    let y = min(max(g.location.y / h, 0), 1)
                    knob = CGPoint(x: x, y: y)
                    apply(Float(x), Float(y))
                }
                .onEnded { _ in
                    if app.params.mode == .drift || app.params.mode == .classicSmear {
                        // Spring back: drift is a momentary push.
                        withAnimation(.easeOut(duration: 0.15)) { knob = .init(x: 0.5, y: 0.5) }
                        app.params.set(.driftX, 0, origin: .ui)
                        app.params.set(.driftY, 0, origin: .ui)
                    }
                })
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var axisLabels: (x: String, y: String) {
        switch app.params.mode {
        case .bloom: return ("THRESH →", "RATE →")
        case .timedBloom: return ("ANGLE / BIAS", "")
        case .feedback: return ("OFFSET X →", "OFFSET Y →")
        case .mixMosh: return ("MIX →", "GAIN →")
        default: return ("DRIFT X →", "DRIFT Y →")
        }
    }

    private func apply(_ x: Float, _ y: Float) {
        switch app.params.mode {
        case .bloom:
            app.params.setNormalized(.bloomThreshold, x, origin: .ui)
            app.params.setNormalized(.bloomRate, 1 - y, origin: .ui)
        case .timedBloom:
            app.params.set(.bloomAngle, atan2(y - 0.5, x - 0.5) + .pi, origin: .ui)
            app.params.setNormalized(.bloomBias,
                min(1, 2 * hypot(x - 0.5, y - 0.5)), origin: .ui)
        case .feedback:
            app.params.setNormalized(.feedbackX, x, origin: .ui)
            app.params.setNormalized(.feedbackY, y, origin: .ui)
        case .mixMosh:
            app.params.setNormalized(.mixAmount, x, origin: .ui)
            app.params.setNormalized(.motionGain, 1 - y, origin: .ui)
        default:
            app.params.set(.driftX, (x - 0.5) * 2, origin: .ui)
            app.params.set(.driftY, (y - 0.5) * 2, origin: .ui)
        }
    }
}

// MARK: - 3D orbit gestures

/// One-finger orbit / two-finger pinch zoom for the Trace 3D camera.
/// Delta-based in screen space, so the Fill/Fit preview crop cannot skew it.
private struct OrbitGestureLayer: View {
    @EnvironmentObject var app: AppModel
    let size: CGSize
    let onWake: () -> Void
    @State private var lastDrag: CGSize?
    @State private var startDistance: Float?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { onWake() }   // tap-to-wake still works in 3D
            .gesture(DragGesture(minimumDistance: Theme.gHalf)
                .onChanged { g in
                    let last = lastDrag ?? .zero
                    let dx = Float((g.translation.width - last.width) / max(1, size.width))
                    let dy = Float((g.translation.height - last.height) / max(1, size.height))
                    lastDrag = g.translation
                    app.params.set(.orbitAzimuth,
                        app.params.get(.orbitAzimuth) - dx * 2 * .pi, origin: .ui)
                    app.params.set(.orbitElevation,
                        app.params.get(.orbitElevation) + dy * .pi, origin: .ui)
                }
                .onEnded { _ in lastDrag = nil })
            .simultaneousGesture(MagnificationGesture()
                .onChanged { scale in
                    let start = startDistance ?? app.params.get(.orbitDistance)
                    startDistance = start
                    app.params.set(.orbitDistance, start / Float(scale), origin: .ui)
                }
                .onEnded { _ in startDistance = nil })
    }
}

// MARK: - Metal preview

struct MoshMetalView: UIViewRepresentable {
    @EnvironmentObject var app: AppModel

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: UIScreen.main.bounds)
        view.device = app.ctx?.device
        view.delegate = app.renderer
        // Display-link driven, never paused, never waiting for setNeedsDisplay.
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        // framebufferOnly=false: some iOS versions composite black when
        // framebufferOnly is combined with explicit colorPixelFormat under
        // SwiftUI hosting; the readback flexibility also serves consumers.
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm          // matches previewPipeline
        view.preferredFramesPerSecond = 60
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Opaque Metal layer + clear background: the compositor treats the
        // layer as owning its pixels instead of blending it away.
        view.layer.isOpaque = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // Force the first frame onto screen: some SwiftUI hosting setups
        // defer the initial display-link tick until a later layout pass,
        // leaving the view black until first interaction.
        if !context.coordinator.kicked, uiView.drawableSize.width > 0 {
            context.coordinator.kicked = true
            uiView.draw()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var kicked = false }
}

/// Cheap 10 Hz UI refresher for values driven by MIDI/automation.
final class RefreshTicker: ObservableObject {
    static let shared = RefreshTicker()
    private var timer: Timer?
    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

// MARK: - Hardware keyboard

struct KeyCommandBridge: UIViewControllerRepresentable {
    @EnvironmentObject var app: AppModel

    func makeUIViewController(context: Context) -> KeyCommandVC {
        let vc = KeyCommandVC()
        vc.app = app
        return vc
    }
    func updateUIViewController(_ vc: KeyCommandVC, context: Context) { vc.app = app }
}

final class KeyCommandVC: UIViewController {
    weak var app: AppModel?
    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var keyCommands: [UIKeyCommand]? {
        var cmds: [UIKeyCommand] = []
        for i in 0...7 {
            cmds.append(UIKeyCommand(input: "\(i)", modifierFlags: [],
                                     action: #selector(modeKey(_:))))
        }
        let simple: [(String, Selector)] = [
            (" ", #selector(bloomKey)), ("r", #selector(resetKey)),
            ("f", #selector(flipKey)), ("h", #selector(perfKey)),
            ("t", #selector(tapKey)),
            ("m", #selector(mirrorKey)), ("c", #selector(colorKey)),
            ("[", #selector(leftDrawerKey)), ("]", #selector(rightDrawerKey)),
            ("?", #selector(helpKey)),
            ("w", #selector(upKey)), ("s", #selector(downKey)),
            ("a", #selector(leftKey)), ("d", #selector(rightKey)),
            (UIKeyCommand.inputUpArrow, #selector(upKey)),
            (UIKeyCommand.inputDownArrow, #selector(downKey)),
            (UIKeyCommand.inputLeftArrow, #selector(leftKey)),
            (UIKeyCommand.inputRightArrow, #selector(rightKey)),
        ]
        for (key, sel) in simple {
            let c = UIKeyCommand(input: key, modifierFlags: [], action: sel)
            c.wantsPriorityOverSystemBehavior = true
            cmds.append(c)
        }
        cmds.append(UIKeyCommand(input: "r", modifierFlags: .command,
                                 action: #selector(recordKey)))
        // Shift+R: reverse playback (plain R stays Reset).
        cmds.append(UIKeyCommand(input: "r", modifierFlags: .shift,
                                 action: #selector(reverseKey)))
        return cmds
    }

    @objc private func modeKey(_ cmd: UIKeyCommand) {
        guard let n = Int(cmd.input ?? "") else { return }
        // 0 = Clean passthrough; 1-7 = mosh modes.
        let mode: MoshMode? = n == 0 ? .clean : MoshMode(rawValue: n - 1)
        if let mode { app?.selectMode(mode) }
    }
    @objc private func bloomKey() { app?.triggerBloom() }
    @objc private func resetKey() { app?.reset() }
    @objc private func recordKey() { app?.toggleRecord() }
    @objc private func flipKey() { app?.flipCamera() }
    @objc private func reverseKey() { app?.toggleReverse() }
    @objc private func mirrorKey() { app?.cycleMirrorMode() }
    @objc private func colorKey() { app?.cycleColorMode() }
    @objc private func tapKey() { app?.tapTempo() }
    @objc private func perfKey() { app?.performanceMode.toggle() }
    @objc private func helpKey() { app?.showCheatSheet.toggle() }
    @objc private func leftDrawerKey() {
        app?.openDrawer(app?.openDrawer == .left ? nil : .left)
    }
    @objc private func rightDrawerKey() {
        app?.openDrawer(app?.openDrawer == .right ? nil : .right)
    }
    @objc private func upKey() { app?.nudgeDrift(dx: 0, dy: -0.1) }
    @objc private func downKey() { app?.nudgeDrift(dx: 0, dy: 0.1) }
    @objc private func leftKey() { app?.nudgeDrift(dx: -0.1, dy: 0) }
    @objc private func rightKey() { app?.nudgeDrift(dx: 0.1, dy: 0) }
}

/// Compact segment names for the mode list.
extension MoshMode {
    var shortTitle: String {
        switch self {
        case .clean: return "CLEAN"
        case .classicSmear: return "SMEAR"
        case .bloom: return "BLOOM"
        case .timedBloom: return "T-BLOOM"
        case .drift: return "DRIFT"
        case .mixMosh: return "MIX"
        case .crossMosh: return "CROSS"
        case .feedback: return "FEEDBK"
        }
    }
}
