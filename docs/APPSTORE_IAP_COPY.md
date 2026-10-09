# App Store Connect copy: paste-ready (nothing was submitted or edited)

## In-App Purchase `com.moshpit.app.pro` (Non-Consumable, unchanged)
- Reference name: MoshPit Pro
- Display name (limit 30): MoshPit Pro
- Description (limit 45): Remove watermark. Share and save videos. (40 chars)
- Family Sharing: off. Price: USD 4.99 (current).

## IAP review screenshot
Capture the **Unlock sheet** ("Remove the watermark and export your work", price button,
Restore Purchases). Easiest: run a Debug build, left drawer > Record & Stream > Debug >
"Preview free tier", record, open My Clips, clip menu > Share. Use a 6.9" or 6.5" iPhone, no status-bar clutter.
Must be a real screenshot of the app.

## App Review note (paste into the version's Review Notes and the IAP's Review Notes)
MoshPit has one in-app purchase, "MoshPit Pro". Free users get every mode and effect plus
recording; recordings carry a small "MoshPit" watermark and stay in the app. The purchase
removes the watermark on NEW recordings/snapshots and unlocks exporting.
To test: (1) tap the red record button, wave at the camera, tap again. (2) Swipe in from the
left edge, tap "My Clips" and play the clip: a small watermark is visible bottom-right. The
camera (shutter) button also adds a watermarked snapshot to My Clips. (3) Tap the clip's "..."
menu > Share (or Share to Social), or Share on the toast: the unlock sheet appears. (4) Buy with
a sandbox account (or Restore Purchases on the sheet); the share sheet opens. (5) Record again:
the new clip has no watermark. Viewing, playing, reusing as an input and deleting clips, and
NDI/MJPEG output, are always free. First launch shows a short welcome and "?" buttons explain
each control. No account, ads, or analytics.
The strobe flicker limiter (3 Hz) is on by default.

## Revised description section (free vs unlocked)
FREE: every glitch style, effect and input; recording and snapshots; the in-app My Clips gallery;
live NDI and MJPEG output. Free recordings and snapshots carry a small MoshPit watermark and stay
in the app. Friendly names and "?" hints explain every control in plain language.
UNLOCK (one-time purchase, no subscription): remove the watermark from new recordings and
snapshots, and export: Share, Save to Files or Photos, and social-ready 9:16 export.

## Guideline check
- 3.1.1: the unlock is digital content/functionality sold via StoreKit IAP only. No external
  purchase links, no license keys; redeem-code UI is unreachable. Restore Purchases is visible.
- 2.1(b): the IAP must be attached to the new version and submitted WITH the new build (this was
  the reason build 18 was rejected). Review screenshot required.
- 3.1.2: not a subscription; one-time non-consumable. Price shown from `Product.displayPrice`.
- 5.x privacy: no tracking or data collection; manifest unchanged (UserDefaults CA92.1).
- Metadata honesty: free = everything + recording (watermarked); gated = watermark removal and
  exporting only. Copy never claims gated things are free nor free things are locked. Remove any
  older text saying "snapshots/Photos saving are free".
- Possible reviewer question: a free app whose output is watermarked until purchase is a common,
  accepted pattern; the free tier is fully functional for live use (NDI/MJPEG clean).

## Needs your action
- [ ] Paid Apps Agreement: add bank account + tax form (status was Pending User Info).
- [ ] IAP: upload review screenshot, confirm metadata above, Cleared for Sale.
- [ ] Build number must be above 18 (e.g. 19); archive and upload.
- [ ] On the new version page attach the IAP under "In-App Purchases"; paste review notes.
- [ ] Update the app description, screenshots/notes that mention free Photos saving, and any screenshots
      showing old labels (modes are now Smear / Burst / Pulse Burst / Push / Blend / Swap Motion / Tunnel;
      panels are Inputs / Effects / 3D View / Rhythm & Links / Record Moves / Record & Stream / My Clips).
- [ ] Resubmit.
