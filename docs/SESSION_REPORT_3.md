# Session Report 3: simpler names, "?" hints, welcome (2026-10-08)

## Commits
- a4b7daa Phase G/H: Labels.swift (friendly titles + original names + hints), Hints.swift ("?" system), copy in tutorial/demos
- e1f184f Phase I: first-launch welcome (3 cards), Skip/persist, replay from Help, hands off to coach marks
- d2ae324 Phase J: free snapshots in the gallery, runtime shared-frame test, layout tests, recorder race fix
- (docs commit) Phase K docs + this report

## Phase G: naming (display only)
Identifiers untouched: ParameterID raw values, MIDI mappings, automation sessions, ModSource raw
values, UserDefaults keys, MoshMode.title (used by launch args). `Labels` is the single source.
Modes: Smear (Classic Smear), Burst (Bloom), Pulse Burst (Timed Bloom), Push (Drift), Blend (Mix Mosh),
Swap Motion (Cross-Mosh), Tunnel (Feedback), Clean. Panels: Inputs, Effects, 3D View, Rhythm & Links,
Record Moves, Record & Stream, My Clips. Routed through Labels: ParamRow, PanelSlider, mode and panel
buttons, panel titles, toggles, section headers, XY pad axes, MIDI learn and link (mod matrix) text,
Help shortcuts, coach marks, and all demos (titles, blurbs, tips). Original name appears as small text
under each mode, in section headers, and in the "?" card ("Also called: ...").
Kept as-is (not routed): short helper captions in a few places (e.g. "Block"-style step values like
"4/8/16/32 px", LFO wave names SIN/SQR, 3D shape names PLANE/CUBE), the Export format names, HUD pill
contents and the debug-only strings. They are values, not primary labels.

## Phase H: "?" hints
`HintButton` renders automatically whenever a hint exists (ParamRow, PanelSlider, ParamToggle, mode
and panel buttons, section headers via HintSection, panel toolbar). One open at a time (HintCenter),
popover card in Theme style, 44pt hit area / ~20pt visual, VoiceOver "What does X do?". Coverage tests
require a hint for every ParameterID, mode, panel and group, no unexplained jargon, <=260 chars.
Note: the "?" sits inside the row; the row's drag gesture does not start on the 44pt "?" area.

## Phase I: welcome
3 cards (what it is, how to play, honest pricing: free to record, watermark until the one-time
unlock which also enables save/share, no subscription, no hard-coded price). Skip on every card,
persists `moshpit.hasSeenWelcome`, Help > Replay welcome, presented via the overlay-exclusivity rules,
hands off to the coach marks (never underneath it). No permission prompts.

## Phase J
1. Free snapshots now appear in My Clips (watermarked, session-only); still not savable/shareable
   without the unlock. Image clips hide "Use as Input A" and "Share to Social".
2. New runtime test: while a free recording watermarks, the shared frame other outputs get is
   unchanged. NDI/MJPEG senders themselves need a peer/SDK, so their own blit is still pinned by the
   source-scan test (kept as fallback).
3. Coach marks: the script has 15 stops (not 12). Anchors read: nothing moved. Layout tests assert
   ParamRow and the mode buttons keep their 44pt height with "?" and two-line labels. The three Effects
   toggles still carry `.coachAnchorGlobal`. Only verifiable on device: actual spotlight alignment.
4. Recording memory read: frames are dropped when the writer isn't ready (no queue growth), pixel
   buffers come from the writer pool and are released after append. REAL BUG FIXED: a frame/audio
   completion handler could append after stop() called markAsFinished (NSException); now serialized
   with a lock.

## Tests: 101 -> 116 (4 skipped, 0 failures)
LabelsTests (6) + HintLayoutTests (2) + WelcomeTests (5) + 1 runtime shared-frame test + snapshot
gallery assertions. Builds: Debug + Release simulator, generic iOS Debug + Release.

## Not done
- No device run: hint popovers on small phones, welcome flow, coach alignment, watermark look.
- UpgradeSheet screenshot for the IAP: no suitable local image exists (see ASC section).
