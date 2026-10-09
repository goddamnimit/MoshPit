import Foundation

// MARK: - Labels: the single source for display text and "?" hints

/// Display-only copy. NOTHING here is an identifier: parameter IDs, MIDI
/// mappings, automation sessions, mod-matrix routes and UserDefaults keys keep
/// their original raw values. Each entry has a plain-language `title` (primary),
/// the `original` technical name (shown small, nil when identical) and a
/// short `hint` for the "?" card.
struct LabelEntry: Equatable {
    let title: String
    let original: String?
    let hint: String

    /// "Smear (Classic Smear)" style text for hint card headers.
    var fullName: String {
        guard let original, original != title else { return title }
        return "\(title) · \(original)"
    }
}

enum Labels {

    // MARK: Hint-only groups (section headers, panels with no parameter)

    enum Group: String, CaseIterable {
        case effectsChain, mixer, processing, hls, strukt, midi, modMatrix
        case trace, mass, cameraOrbit
        case recording, exportSettings, mjpeg, ndi, broadcast, outputResolution
        case automationTakes
    }

    private static func e(_ title: String, _ original: String? = nil, _ hint: String) -> LabelEntry {
        LabelEntry(title: title, original: original, hint: hint)
    }

    static func group(_ g: Group) -> LabelEntry {
        switch g {
        case .effectsChain:
            return e("Effects Chain", "Chain", "Turn effects on and stack them. They run in the order shown, and you can drag to reorder. Try one at a time first.")
        case .mixer:
            return e("Blend Sources", "Mix A/B wipes", "Fade or wipe between your two video sources, A and B. You'll see the picture change from one to the other. Needs something loaded in both.")
        case .processing:
            return e("Quality", "Processing", "Trade sharpness for speed. Lower numbers run smoother on older phones and look chunkier. Higher numbers look cleaner but use more battery.")
        case .hls:
            return e("Web Video", "Network stream (HLS)", "Paste a link to a live video stream (an .m3u8 address) to glitch it like the camera. Protected streams from big services won't work.")
        case .strukt:
            return e("Rhythm", "Strukt LFO bank", "Make things pulse on a beat. Set a tempo, then use the two rhythm waves to flip, flash or invert the picture in time. Great with music.")
        case .midi:
            return e("MIDI Knobs", "MIDI learn", "Control sliders with a hardware knob or pad. Press and hold a slider's name, then turn a knob. You'll see the link appear in this list.")
        case .modMatrix:
            return e("Links", "Mod matrix", "Connect a source (brightness, movement or a rhythm wave) to any control so it moves on its own. Example: link brightness to Blend so bright scenes clear the smear.")
        case .trace:
            return e("3D Mode", "Trace", "Turns your video into a 3D shape you can orbit. Bright areas push toward you. Drag on the picture to rotate and pinch to zoom.")
        case .mass:
            return e("Objects", "Mass", "Wrap your glitched video around a cube, sphere or torus and spin it. You'll see the picture on the surface of the shape.")
        case .cameraOrbit:
            return e("3D Camera", "Orbit camera", "Where you're looking from in 3D mode. Auto-spin keeps it turning, distance zooms in and out.")
        case .recording:
            return e("Recording", nil, "Capture what you see, including effects. Free recordings get a small MoshPit watermark and stay in the app. Unlocking removes it and lets you save and share.")
        case .exportSettings:
            return e("Video Quality", "Export", "Choose the file type and size for your next recording. Bigger files look better but take more space. If unsure, leave the defaults.")
        case .mjpeg:
            return e("Web Stream", "MJPEG", "Shows your glitch live in a web browser or in OBS on the same Wi-Fi. Turn it on, then open the address shown. Free and clean, no watermark.")
        case .ndi:
            return e("Network Video", "NDI", "Sends your glitch live over Wi-Fi to VJ software like Resolume or OBS. Free and clean, no watermark.")
        case .broadcast:
            return e("Screen Share", "Screen broadcast (ReplayKit)", "Mirrors the whole phone screen to a broadcast app. Use Clean Feed to hide the controls while you do.")
        case .outputResolution:
            return e("Stream Size", "Output resolution", "The biggest size sent to NDI and used for recording when set to match the canvas. Lower it if the phone gets warm.")
        case .automationTakes:
            return e("Saved Takes", "Automation takes", "Your recorded slider moves. Tap play to repeat your performance over any video.")
        }
    }

    // MARK: Panels (drawer buttons, sheet titles)

    static func panel(_ p: AppModel.Panel) -> LabelEntry {
        switch p {
        case .sources:
            return e("Inputs", "Sources", "Pick what gets glitched: your front or back camera, or a video from your library. Slot A is the main picture, B is a second one, and MOD is a hidden one that only controls things.")
        case .effects:
            return e("Effects", nil, "Extra looks that stack on top of your glitch: echoes, streaks, mirrors, color, meshes and more. Switch them on one by one.")
        case .threeD:
            return e("3D View", "3D", "Turn your live glitch into a 3D scene you can orbit, made of dots, a mesh or a solid shape.")
        case .control:
            return e("Rhythm & Links", "Control", "Make the glitch move to a beat and link controls together. Includes tap tempo, rhythm waves, MIDI knobs and links.")
        case .automation:
            return e("Record Moves", "Automation", "Record your slider moves, then replay them as a loop. Handy for repeating a performance.")
        case .output:
            return e("Record & Stream", "Output", "Start a recording, choose video quality, and send your glitch live to other screens over Wi-Fi.")
        case .gallery:
            return e("My Clips", "Gallery", "Recordings and snapshots from this session. Watch them, load one back in as a source, or delete it. Exporting needs the one-time unlock.")
        }
    }

    // MARK: Modes

    static func mode(_ m: MoshMode) -> LabelEntry {
        switch m {
        case .clean:
            return e("Clean", nil, "Your camera with no glitch. A safe baseline you can return to at any time.")
        case .classicSmear:
            return e("Smear", "Classic Smear", "Moving parts of the picture smear into streaks while still parts freeze. Move slowly in front of the camera to see trails. A great first effect.")
        case .bloom:
            return e("Burst", "Bloom", "When something moves, that area erupts with a frozen copy of the picture. Hold still, then move suddenly.")
        case .timedBloom:
            return e("Pulse Burst", "Timed Bloom", "Bursts go off on their own rhythm, even if you hold still. Set how often with Rate.")
        case .drift:
            return e("Push", "Drift", "Pushes the whole picture in one direction like wind. Use the square pad to choose where it flows.")
        case .mixMosh:
            return e("Blend", "Mix Mosh", "Mixes fresh camera frames back into the smear. Low = heavy smear, high = clearer picture.")
        case .crossMosh:
            return e("Swap Motion", "Cross-Mosh", "Motion from one source pushes around the pixels of the other. Load two sources in Inputs first, like camera plus a video.")
        case .feedback:
            return e("Tunnel", "Feedback", "The picture keeps copying itself a little bigger or twisted each time, making tunnels and spirals.")
        }
    }

    // MARK: Parameters

    static func param(_ id: ParameterID) -> LabelEntry {
        guard let entry = paramTable[id] else {
            // Coverage test guarantees this never happens for shipped IDs.
            return LabelEntry(title: id.rawValue, original: nil, hint: "")
        }
        return entry
    }

    static let paramTable: [ParameterID: LabelEntry] = {
        var t: [ParameterID: LabelEntry] = [:]
        func p(_ id: ParameterID, _ title: String, _ original: String? = nil, _ hint: String) {
            t[id] = LabelEntry(title: title, original: original, hint: hint)
        }
        // Engine
        p(.mode, "Style", "Mode", "Which glitch style is active. Pick one in the left drawer.")
        p(.blockSize, "Chunk", "Block size", "How big the pieces of picture are that get smeared. Small = fine detail, large = big blocky chunks.")
        p(.processingRes, "Quality", "Canvas res", "How sharp the glitch canvas is. Lower is smoother on older phones and looks chunkier; higher looks cleaner.")
        p(.estimatorBackend, "Smart motion", "Vision optical flow", "Uses Apple's motion tracking instead of the quick method. It follows movement more accurately but works the phone harder.")
        p(.smoothVectors, "Soft smear", "Smooth vectors", "Makes smears flow smoothly instead of in hard blocks.")
        p(.heal, "Recover", "Heal", "Slowly lets the real picture seep back in so the glitch never freezes forever. Turn up if it gets stuck.")
        p(.motionGain, "Strength", "Gain", "How strongly movement pushes the picture. Higher = bigger, wilder smears.")
        // Bloom
        p(.bloomRate, "Speed", "Rate", "How often bursts happen, per second. Slow gives big, rare eruptions.")
        p(.bloomThreshold, "Trigger", "Threshold", "How much something must move to cause a burst. Lower = more sensitive, bursts from tiny movement.")
        p(.bloomDecay, "Fade", "Decay", "How long a burst lingers before fading. Higher = longer-lasting bursts.")
        p(.bloomAngle, "Direction", "Angle", "The direction bursts lean toward. Turn it to aim them.")
        p(.bloomBias, "Lean", "Bias", "How strongly bursts lean in that direction. Zero means no lean.")
        // Drift
        p(.driftX, "Push left/right", "Drift X", "Pushes the picture sideways. Use the square pad for easy control.")
        p(.driftY, "Push up/down", "Drift Y", "Pushes the picture up or down. Use the square pad for easy control.")
        p(.driftReplaces, "Override", "Drift replaces motion", "Uses your push instead of the camera's real movement, for a flow you fully steer.")
        // Mix / cross
        p(.mixAmount, "Blend", "Mix", "Left keeps the smear frozen, right shows the clean picture. Somewhere in the middle looks best.")
        p(.crossMosh, "Swap motion", "Cross-mosh", "Lets source A's movement push around source B's pixels. Needs two sources.")
        // Feedback
        p(.feedbackZoom, "Zoom", nil, "How much the picture grows or shrinks each pass. Small numbers make endless tunnels.")
        p(.feedbackRotate, "Twist", "Rotate", "How much the picture turns each pass, making spirals.")
        p(.feedbackX, "Slide across", "Offset X", "Shifts the repeating picture sideways each pass.")
        p(.feedbackY, "Slide down", "Offset Y", "Shifts the repeating picture up or down each pass.")
        p(.feedbackHue, "Color cycle", "Hue", "Slowly changes the colors on every pass, so the tunnel shifts through the rainbow.")
        // Effect chain
        p(.echoEnabled, "Echo Trails", "Echo", "Leaves ghost copies of recent frames behind you. Move around to see them trail.")
        p(.echoLayers, "Ghosts", "Layers", "How many ghost copies to keep. More = longer trails.")
        p(.echoKeyLow, "Dark cut", "Key low", "Only brightness above this shows in the ghosts. Raise to hide dark areas.")
        p(.echoKeyHigh, "Bright cut", "Key high", "Only brightness below this shows in the ghosts. Lower to hide bright areas.")
        p(.slitscanEnabled, "Time Slice", "SSSScan", "Different parts of the picture show different moments in time, so movement bends and stretches.")
        p(.slitscanSpeed, "Speed", nil, "How fast the time slices sweep across. Negative runs the other way.")
        p(.slitscanAngle, "Angle", nil, "The direction the time slices sweep.")
        p(.slitscanUseB, "Use B shape", "Gradient from source B", "Shapes the time slices using source B's brightness instead of a plain sweep.")
        p(.slitscanScrub, "Scrub", nil, "Slides the time-slice position by hand. Move it to scrub through the effect.")
        p(.weaverEnabled, "Weave", "Weaver", "Interlaces slices of recent frames like threads in cloth, giving a woven, glitchy texture.")
        p(.weaverAmount, "Amount", nil, "How much weaving is mixed in.")
        p(.pixelSortEnabled, "Pixel Streaks", "PXLMSH", "Sorts pixels into streaks by brightness, so parts of the picture melt into cascading lines.")
        p(.pixelSortThreshold, "Cutoff", "Threshold", "Which pixels get streaked. High = only bright edges, low = whole areas cascade.")
        p(.pixelSortVertical, "Vertical", nil, "Streaks run up and down instead of side to side.")
        p(.procAmpEnabled, "Picture Tuning", "Proc-Amp", "Basic picture adjustments: brightness, contrast, color strength, hue and gamma.")
        p(.brightness, "Brightness", "Bright", "Makes the picture lighter or darker.")
        p(.contrast, "Contrast", nil, "Pushes lights lighter and darks darker. Zero looks flat.")
        p(.saturation, "Color", "Sat", "How vivid the colors are. Zero is black and white.")
        p(.hueShift, "Color shift", "Hue", "Slides every color around the color wheel.")
        p(.gamma, "Midtones", "Gamma", "Brightens or darkens the middle tones without touching pure black or white.")
        // Strukt (rhythm)
        p(.bpm, "Tempo", "BPM", "Beats per minute. Tap the TAP button in time with music to match it.")
        p(.lfo1Wave, "Wave 1 shape", "LFO 1 wave", "The shape of rhythm wave 1: smooth (SIN), on/off (SQR), ramps (TRI, SAW) or random steps (S&H).")
        p(.lfo1Rate, "Wave 1 speed", "LFO 1 rate (Hz)", "How many times per second wave 1 repeats.")
        p(.lfo1Sync, "Wave 1 follows tempo", "LFO 1 sync", "Locks wave 1's speed to the tempo so it stays in time with music.")
        p(.lfo1Div, "Wave 1 beat", "LFO 1 division", "How often wave 1 repeats per beat when it follows tempo. 1/4 = four times per beat.")
        p(.lfo1Phase, "Wave 1 offset", "LFO 1 phase", "Starts wave 1 earlier or later in its cycle, to line up with the beat.")
        p(.lfo1Depth, "Wave 1 amount", "LFO 1 depth", "How strongly wave 1 affects things. Zero turns it off.")
        p(.lfo2Wave, "Wave 2 shape", "LFO 2 wave", "The shape of rhythm wave 2: smooth (SIN), on/off (SQR), ramps (TRI, SAW) or random steps (S&H).")
        p(.lfo2Rate, "Wave 2 speed", "LFO 2 rate (Hz)", "How many times per second wave 2 repeats.")
        p(.lfo2Sync, "Wave 2 follows tempo", "LFO 2 sync", "Locks wave 2's speed to the tempo so it stays in time with music.")
        p(.lfo2Div, "Wave 2 beat", "LFO 2 division", "How often wave 2 repeats per beat when it follows tempo. 1/4 = four times per beat.")
        p(.lfo2Phase, "Wave 2 offset", "LFO 2 phase", "Starts wave 2 earlier or later in its cycle, to line up with the beat.")
        p(.lfo2Depth, "Wave 2 amount", "LFO 2 depth", "How strongly wave 2 affects things. Zero turns it off.")
        p(.struktFlip, "Swap A/B", "Flip A/B", "Swaps between sources A and B on the beat of a rhythm wave. Needs two sources.")
        p(.struktInvert, "Invert beat", "Invert", "Flips the colors to their opposite on the beat of a rhythm wave.")
        p(.struktFlash, "Flash beat", "Flash", "Flashes the screen on the beat of a rhythm wave. Capped to 3 flashes a second unless you turn the safety limit off.")
        p(.struktFlashWhite, "White flash", "Whiteout flash", "Flashes go white instead of black.")
        p(.flickerLimit, "Flash safety", "Flicker limiter", "Keeps flashing at 3 times a second or slower. Leave on unless you're sure your audience is OK with strobes; fast flashing can trigger seizures.")
        // Trace / Mass
        p(.trace3D, "3D mode", "Trace 3D", "Turns your video into a 3D scene. Drag on the picture to turn it, pinch to zoom.")
        p(.traceMode, "Draw as", "Render", "Show the 3D picture as dots, a wire mesh or a solid surface.")
        p(.traceGrid, "Detail", "Grid", "How many points make up the 3D picture. More = sharper but slower.")
        p(.tracePointSize, "Dot size", "Pt size", "How big each dot is when drawn as dots.")
        p(.traceDepth, "Depth", nil, "How far bright areas push toward you. Negative pushes them away.")
        p(.traceAutoRotate, "Auto-spin", "Auto-rot", "Slowly turns the scene by itself. Negative spins the other way.")
        p(.traceAdditive, "Glow", "Additive points", "Lets overlapping dots add together for a glowing look.")
        p(.traceTrails, "Trails", "Feedback trails", "Leaves fading trails behind moving dots.")
        p(.tracePrimitive, "Shape", "Object", "The shape your video wraps around: flat plane, cube, sphere or torus (a donut).")
        p(.traceSpinX, "Spin tilt", "Spin X", "Spins the shape forward and back.")
        p(.traceSpinY, "Spin turn", "Spin Y", "Spins the shape left and right.")
        p(.traceSpinZ, "Spin roll", "Spin Z", "Rolls the shape like a wheel.")
        p(.orbitAzimuth, "Look around", "Orbit azimuth", "Turns the 3D camera around the scene. Usually set by dragging on the picture.")
        p(.orbitElevation, "Look up/down", "Elevation", "Raises or lowers the 3D camera.")
        p(.orbitDistance, "Zoom", "Distance", "How far the 3D camera is from the scene. Usually set by pinching.")
        // Mixer
        p(.mixCrossfade, "A ↔ B", "A <-> B", "Slide between source A (left) and source B (right).")
        p(.wipeMode, "Fade style", "Wipe", "How the change from A to B happens: a smooth fade, by brightness, or using a hidden clip as a mask.")
        p(.wipeSoftness, "Soft edge", "Soft", "How soft the edge of the wipe is. Low = hard cut.")
        p(.wipeLumaFromMod, "Use hidden clip", "Luma wipe reads MOD", "Lets the hidden MOD clip decide where the wipe happens, instead of source B.")
        // Finisher
        p(.mirrorMode, "Mirror", nil, "Reflects the picture for symmetry: left-right, up-down or four ways. Applied last, so recordings get it too.")
        p(.mirrorRightToLeft, "Mirror other side", "Mirror right half", "Copies the right half onto the left instead of the left onto the right.")
        p(.colorMode, "Color look", "Color mode", "Change all the colors: invert them, tint with two colors, or cycle through the rainbow.")
        p(.duotoneShadowHue, "Dark color", "Shadow°", "The color used for dark areas in the two-color look.")
        p(.duotoneHighlightHue, "Light color", "Light°", "The color used for bright areas in the two-color look.")
        p(.colorHueShift, "Color spin", "Hue°", "Rotates all colors around the color wheel. Link it to a rhythm wave for a color cycle.")
        p(.gridWarpEnabled, "Mesh Warp", "Grid-Mesh Glitch Warp", "Warps the picture through a drifting grid of cells, with an optional visible mesh on top.")
        p(.gridWarpCellSize, "Cells", nil, "How many grid cells fit across the picture.")
        p(.gridWarpIntensity, "Warp", nil, "How far the grid pushes the picture around.")
        p(.gridWarpLineOpacity, "Mesh lines", "Mesh", "How visible the grid lines are. Zero warps without showing the grid.")
        p(.gridWarpAnimSpeed, "Drift speed", "Speed", "How fast the grid drifts and wobbles.")
        p(.spreadsheetEnabled, "Spreadsheet Look", "Spreadsheet Mosh Filter", "Turns the picture into flat-colored cells like a spreadsheet, complete with fake menus and a moving selection box.")
        p(.spreadsheetCellSize, "Columns", "Cols", "How many columns of cells across the picture. More = finer.")
        p(.spreadsheetChromeOpacity, "Menu overlay", "Chrome", "How visible the fake spreadsheet toolbar and headers are.")
        p(.spreadsheetGridLineOpacity, "Grid lines", "Lines", "How visible the lines between cells are.")
        p(.spreadsheetSelectionSpeed, "Cursor speed", "Cursor", "How fast the selection box hops between cells.")
        p(.spreadsheetCellRevealMode, "Reveal", nil, "How cells appear: all at once, wiping in, or randomly.")
        p(.trackingHUDEnabled, "Tracker Dots", "Tracking HUD Overlay", "Scatters tracking dots and number readouts over moving areas, like a sci-fi targeting screen. Purely decorative.")
        p(.trackingHUDPointDensity, "Dots", "Points", "How many tracking dots are drawn.")
        p(.trackingHUDLabelDensity, "Number tags", "Labels", "How many dots get a coordinate number next to them.")
        p(.trackingHUDLineOpacity, "Link lines", "Mesh", "How visible the lines joining nearby dots are.")
        p(.trackingHUDColor, "Tracker color", "Hue°", "The color of the dots and lines.")
        // Output
        p(.cleanFeed, "Clean feed", nil, "Hides the on-screen controls while you broadcast the screen, so viewers only see the picture.")
        p(.outputRes, "Max size", "Max res", "The largest size used for streaming and for recordings set to match the canvas.")
        return t
    }()

    // MARK: Mod sources, LFO/steps (display only)

    /// Display names for mod-matrix sources. `ModSource.rawValue` is the
    /// persisted identifier and is never changed.
    static func modSource(_ s: ModSource) -> String {
        switch s {
        case .meanLuma: return "Brightness"
        case .motionMagnitude: return "Movement amount"
        case .motionAngle: return "Movement direction"
        case .lfo1: return "Rhythm wave 1"
        case .lfo2: return "Rhythm wave 2"
        }
    }

    /// X / Y axis captions on the drawer pad.
    static func xyAxes(_ mode: MoshMode) -> (x: String, y: String) {
        switch mode {
        case .bloom: return ("TRIGGER →", "SPEED →")
        case .timedBloom: return ("DIRECTION / LEAN", "")
        case .feedback: return ("SLIDE ACROSS →", "SLIDE DOWN →")
        case .mixMosh: return ("BLEND →", "STRENGTH →")
        default: return ("PUSH LEFT/RIGHT →", "PUSH UP/DOWN →")
        }
    }

    // MARK: Help sheet

    static let shortcuts: [(String, String)] = [
        ("0", "Clean (no glitch)"), ("1–7", "Pick a glitch style"),
        ("Space", "Trigger a burst"), ("Hold Reset", "Peek at clean video"),
        ("W A S D / arrows", "Push the picture"), ("R", "Reset to a clean frame"),
        ("⌘R", "Start/stop recording"), ("⇧R", "Play video backwards"),
        ("F", "Flip camera"),
        ("H", "Hide/show controls"), ("T", "Tap tempo"),
        ("M", "Cycle mirror"), ("C", "Cycle color look"),
        ("[", "Open/close styles drawer"), ("]", "Open/close sliders drawer"),
        ("?", "Open this help"), ("Long-press a slider name", "Link a MIDI knob"),
    ]
}
