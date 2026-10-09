# Session Report 2: watermark model (2026-10-08)

## Commits
- 90da802.. earlier session (see SESSION_REPORT.md)
- Plan: docs/MONETIZATION_V2_PLAN.md (call-site and loophole review)
- ee2394c Free-tier watermark (Metal pass), entitlement latched at record start, exports gated, DEBUG preview toggle
- Rewrite UpgradeSheet (watermark removal + export, before/after, hint in gallery)
- Update App Store docs, privacy manifest note, docs/APPSTORE_IAP_COPY.md
- Phase F commit: Reduce Motion curves, permission recovery, interruption handling, hit areas

## What changed
- Free tier: everything, plus recording/snapshots with a burned-in "MoshPit" wordmark (bottom-right,
  4.5% of short edge, 60% opacity, shadow). Metal kernel `blitScaleWatermark`; only the recorder and
  snapshot paths use it; preview/NDI/MJPEG stay clean. Entitled = plain `blitScale` (zero cost).
- Entitlement latched at `MoshRecorder.start()`; fails closed if no gate is injected.
- Gated by `AppModel.requireExport` / `shareFile`: share sheet (incl. Files), social export, Photos.
  Free snapshot is watermarked, not saved to Photos (decision: it has no in-app home, so the toast
  explains and Share routes to the unlock sheet). Gallery view/play/remosh/delete stay free.
  Release `ShareSheetPresenter` refuses to present unless entitled (backstop).
- `Capability` now `.saveVideoToPhotos/.removeWatermark/.exportOutput`, all = one entitlement.
- DEBUG: still fully entitled. New DEBUG-only toggle (Output panel > Debug > Preview free tier).
  `debugSetPro` still wins. Not compiled in Release (Release build verified).
- No auto-paywall after recording any more; a toast + once-per-session dismissible gallery hint.
- Phase F: Theme curves honor Reduce Motion; "Open Settings" for camera/mic denied; recording is
  finalized on backgrounding / audio interruption; gallery menu hit area 44pt (shared button style
  already padded hit areas). Coach-mark anchors untouched (no layout change).

## Tests: 89 -> 101 (4 skipped, 0 failures)
Watermark placement math at 5 sizes/orientations; GPU pixel sampling vs clean render (changes only the
corner, at 720p/1080p/4K portrait+landscape); latch and fail-closed; free snapshot not saved; export gate;
Debug bypass and preview-toggle precedence; source-scan that only recorder/snapshot use the watermark
kernel (NDI/MJPEG clean); backgrounding finalizes a recording.
Builds verified: Debug + Release simulator, generic iOS Debug + Release (signing off).

## Not done / caveats
- Not run on device: no Instruments, no real camera/IAP sandbox, Reduce Motion and the 12 coach-mark
  stops were not visually re-verified (no layout changed, so alignment should be unchanged).
- Memory over long recordings: reviewed by reading (pooled pixel buffers, frames dropped when the
  writer is not ready); not measured.
- Social export inherits the clip's watermark (no second mark). ReplayKit/screen recording and
  live NDI/MJPEG capture can still produce clean video (out of scope; documented in the plan).
- The "unread" docs mention of AppStore screenshots/description still needs your update in ASC.

## You must do
1. App Store Connect (see docs/APPSTORE_IAP_COPY.md): Paid Apps Agreement bank+tax, IAP screenshot and
   metadata, attach IAP to a NEW version, build number above 18, paste review notes, resubmit.
2. On device: Xcode Run = no watermark, everything open; Output panel > Debug > "Preview free tier"
   shows the watermark on a new recording and the unlock sheet on Share. Archive/TestFlight = real
   paywall, watermarked recordings, sandbox purchase removes the watermark for NEW recordings.
3. Eyeball the watermark size/legibility on a real clip and the new UpgradeSheet layout on a small phone.
