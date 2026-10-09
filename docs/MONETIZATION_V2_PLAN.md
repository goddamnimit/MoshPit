# Monetization V2 plan: watermark free tier, unlock exports

Model: free = everything + recording/snapshots (watermarked, cannot leave the app).
Unlock (`com.moshpit.app.pro`, unchanged) = no watermark on NEW recordings/snapshots,
Save to Photos, the share sheet (incl. Save to Files), Social Export.

## Single choke point
`AppModel.entitled(_:)` stays the only entitlement read. Derived helpers:
`watermarkRequired()` (= !entitled(.removeWatermark)) and `requireExport(_:)` which runs an
action if entitled(.exportOutput) or else `presentUpgrade(for:andThen:)`.
`Capability` gains `.removeWatermark`, `.exportOutput`; all map to `isPro`.
DEBUG: `entitled()` still returns true (bypass) unless `debugSetPro` is set (takes precedence)
or the new DEBUG-only free-tier preview toggle forces false.

## Watermark call sites (Metal)
- Recorder: `MoshRecorder.consume` (Outputs.swift) uses `blitScale` into the BGRA pixel buffer.
  Add kernel `blitScaleWatermark` (same sampling + composites the mark). Entitlement latched at
  `start()` via an injected closure; entitled recordings keep the existing zero-cost `blitScale`.
- Snapshot: `Renderer.encodeSnapshotIfNeeded` (two call sites share it). `requestSnapshot` gets a
  `watermark:` flag decided on main at shutter time.
- NOT watermarked (live outputs): preview, NDI, MJPEG (Outputs.swift:470 blitScale, NDI).
- Mark: "MoshPit" wordmark rasterized once with CoreGraphics (system font, no assets) into an R8
  mask texture; bottom-right, height ~4.5% of short edge, 60% opacity, soft shadow.

## Gating call sites
1. `ShareSheetPresenter.present` callers: RootView ShareToastView (826), Gallery row Share (120),
   Gallery social-export completion (72). All go through `AppModel.shareFile`/`requireExport`.
   Presenter itself refuses to present in Release when not entitled (defence in depth).
2. `VideoPhotosSaver.save` / `MoshRecorder.stop` auto-save: only when the recording was latched
   entitled; free recordings land in the gallery only (`.gated`, toast, no auto paywall).
3. `SnapshotSaver.save` (AppModel.snapshot): free snapshot is watermarked, NOT written to Photos.
4. `SocialExporter.export` (Gallery `socialExport`): gated; inherits the clip's watermark.
5. Free (ungated): gallery view/play/Load into Slot A/Delete.

## Loophole review
- Info.plist has no UIFileSharingEnabled / LSSupportsOpeningDocumentsInPlace, and clips live in
  the temp dir, so they are not exposed in the Files app.
- Gallery has no drag/drop, context menu, Quick Look, ShareLink or UIDocumentInteraction paths;
  the only exits are the four above. Playback uses a bare AVPlayerLayer (no system chrome).
- Out of scope, documented: ReplayKit / screen recording and NDI/MJPEG capture of the live clean
  output (live outputs are deliberately unwatermarked) can still produce clean video.
- Remosh: loading a watermarked clip as a source keeps its baked-in mark (expected).
- Purchase mid-recording does not clean that recording (latched). Social Export adds no 2nd mark.
