# Performance Notes

**Status: unprofiled.** Instruments was not run this session; the claims below come from
reading the code and the existing commit history. No new performance code was added.

## Already in place (before this session)
- `1e06092` os_signpost lanes (`Perf.swift`, subsystem `com.moshpit.perf`): UI.Drawer, UI.Sheet,
  Params.Publish, Slider.Drag, Haptics, Coach. Ships in Release (negligible cost); deliberately
  not in the per-frame Metal path.
- `5cb5c26` stats publish throttled to 10 Hz, slider observation scoped so a drag does not
  invalidate unrelated views.
- `ce799c4` shared haptic generator pre-warmed and reused.

## Reviewed this session
- `openSheet` / `openDrawer` defer by `overlaySwap` = 0.35 s ONLY when another overlay must
  animate away first. Opening from a clean state is immediate. Kept at 0.35 s: shortening it
  without a trace risks the two overlays being on screen together, which the exclusivity system
  exists to prevent. Measure with the `openSheet` / `openDrawer` intervals (a ~0.35 s bar = swap
  path) before changing it.
- Metal pipeline, camera queues and `ParameterStore` thread-safety were left unchanged.

## Not done / to measure on device
- Per-frame render stage timing (use Metal System Trace / GPU tools).
- Before/after numbers: none exist, so none are claimed.
