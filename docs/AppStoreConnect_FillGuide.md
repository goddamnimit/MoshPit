# App Store Connect Fill Guide — MoshPit 1.0

Copy-paste reference, organized to match App Store Connect's page structure.
Sources: AppStore.md, PrivacyPolicy.md, ReviewerNotes.md, Support.md,
PrivacyInfo.xcprivacy. Fields the docs don't cover are marked
"NOT YET DRAFTED — needs your input".

---

## App Information

- **Name:** MoshPit
  (fallback if taken: `MoshPit — Datamosh Instrument`, 29 chars)
- **Subtitle:** Real-time datamosh instrument
  (29 characters; limit 30)
- **Category (primary):** Photo & Video
- **Category (secondary):** Music
- **Content rights:** Select "No, it does not contain, show, or access
  third-party content." The app ships with no media content; the NDI SDK is
  licensed code, not displayed third-party content.

Also on this page:
- **Age rating questionnaire:** answer "No"/"None" to everything → 4+.
  (No user-generated content is shared; the strobe feature is a visual
  effect, not a questionnaire category.)

## Pricing and Availability

- **Price tier:** Free ($0). This is the APP price — the $4.99 is the
  separate `com.moshpit.app.pro` in-app purchase configured on its own page
  (below), not here.
- **Availability:** NOT YET DRAFTED — needs your decision. Default is all
  territories; no doc records a reason to exclude any.

## App Privacy

Matches the shipped `PrivacyInfo.xcprivacy` (no tracking, no tracking
domains, empty collected-data types, UserDefaults/CA92.1 only):

- **Privacy Policy URL:** https://goddamnimit.github.io/MoshPit/PrivacyPolicy.html
- **Data collection questionnaire:** answer **"No, we do not collect data
  from this app"** → the label shows **"Data Not Collected"**. Confirmed
  consistent with the manifest: no analytics, no third-party SDK collection,
  no account. Purchase processing is Apple's own collection and is NOT
  declared by you in this questionnaire.
- **Tracking:** No.

## In-App Purchases (creating the com.moshpit.app.pro product)

- **Reference type:** Non-Consumable
- **Product ID:** com.moshpit.app.pro
  (must match `ProManager.productID` exactly — copy-paste it)
- **Reference Name:** MoshPit Pro
- **Display Name (localized, en-US):** MoshPit Pro
  (11 characters; limit 30)
- **Description (localized, en-US):** Save your recorded videos to Photos.
  (37 characters; limit 45)
- **Price tier:** USD 4.99
- **Review screenshot:** ⛔ BLOCKED — requires an actual screenshot of the
  in-app upgrade sheet (pending, tomorrow's screenshot task). The product
  can be created and saved without it, but cannot be submitted for review
  until it's uploaded.
- **Availability:** set "Cleared for Sale".
- After creating it: on the Version 1.0 page, add this product under
  "In-App Purchases" so it is reviewed WITH the 1.0 submission (a first IAP
  cannot be reviewed separately from an app version).

## Version 1.0 — App Store page

- **Promotional Text (170 char limit):** NOT YET DRAFTED — needs your input.
  (Optional field; can be added/edited any time without a new review.)

- **Description (4000 char limit)** — paste exactly (≈2,700 chars):

MoshPit turns datamoshing — the melting, smearing glitch look born from
broken video compression — into a live instrument. Point it at your camera,
a video from your library, or a network stream, and play the decay in real
time. Every pixel is processed on the GPU, so what you see is instant and
what you record is exactly what you saw.

SEVEN MOSH MODES
Classic Smear never lets a fresh frame in. Bloom erupts detail where motion
happens. Timed Bloom fires on a rhythm. Mix Mosh blends decay with reality.
Cross-Mosh drags one video's pixels with another video's motion. Feedback
Mosh zooms, rotates, and hue-shifts the canvas into itself. Reset is always
one tap away.

A REAL MOTION ENGINE
MoshPit estimates motion the way a video encoder does — chunky macroblocks
at 4, 8, 16, or 32 pixels — or switches to smooth per-pixel optical flow
when you want melt instead of blocks. Block size is a playable parameter,
because it is the look.

EFFECTS AND RHYTHM
Chain echo trails, slit-scan, weaver, pixel sort, and a proc-amp in any
order. Two LFOs (sine, square, triangle, saw, sample-and-hold) with tap
tempo drive any parameter, flip sources on the beat, or gate color inverts.
A flicker limiter is on by default.

BEYOND THE FLAT CANVAS
Re-render the moshed canvas as a 3D point cloud, wireframe, or solid mesh
with luma displacement and feedback trails — or wrap it around a spinning
cube, sphere, or torus. Orbit with one finger, zoom with two.

MIX TWO SOURCES
An A/B crossfader with luma and mask wipes feeds the mosh engine itself,
so source cuts become moshable events. Route an LFO to the crossfader for
rhythmic switching.

PLAY IT LIKE AN INSTRUMENT
An XY performance pad remaps per mode. Every slider learns MIDI CC with a
long-press. A mod matrix routes video luma and motion to any parameter.
Record every knob move as an automation take and replay it, looped, over a
completely different source. Full hardware-keyboard shortcuts on iPad.

SEND IT TO THE BIG SCREEN
Stream your output over the local network to VJ and streaming software via
NDI, or from any browser via built-in MJPEG — no extra hardware. Record
1080p video with mic audio — every clip lands in the session gallery for
instant sharing — or grab a single frame with the shutter button.

NO STRINGS
No account. No ads. No analytics. No subscriptions. Nothing leaves your
device unless you point an output at your own network. Every mode, effect,
and output is free; the one optional purchase is MoshPit Pro, a single
one-time unlock that saves your recordings directly to Photos.

MoshPit is for VJs, video artists, glitch enthusiasts, and anyone who ever
deleted an I-frame on purpose.

- **Keywords (100 char limit)** — paste exactly (93 characters):

datamosh,glitch,vj,video effects,ndi,glitch art,video synth,camera fx,pixel sort,visuals,live

- **Support URL:** https://goddamnimit.github.io/MoshPit/Support.html
- **Marketing URL:** leave blank (none exists; optional field).
- **Copyright line:** NOT YET DRAFTED — needs your input. Likely
  "2026 Dan Flash LLC" based on the support email, but confirm the exact
  legal entity name yourself.
- **Version:** 1.0
- **What's New in This Version** (first release — field may be absent or
  optional for 1.0; if shown, paste):

Initial release.

- Seven real-time mosh modes with block-match and optical-flow motion engines
- Effect chain: echo, slit-scan, weaver, pixel sort, proc-amp, mirror and color finishers
- Two-LFO rhythm engine with tap tempo and mod matrix
- 3D point cloud, wireframe, and textured-object render paths
- A/B source mixer with luma and mask wipes
- MIDI CC learn, automation record/replay, hardware keyboard shortcuts
- NDI and MJPEG network output; 1080p recording, snapshots, session gallery
- Optional one-time MoshPit Pro unlock: save recordings straight to Photos

- **Screenshots (6.7"):** ⛔ BLOCKED — pending tomorrow's manual capture.

## App Review Information

- **Sign-in required:** NO — there is no account system (confirmed
  consistent across PrivacyPolicy.md and ReviewerNotes.md). Leave the demo
  username/password fields empty.
- **Contact Information:**
  - First name: NOT YET DRAFTED — needs your input (likely "Nimit"; no doc
    records the name App Review should call)
  - Last name: NOT YET DRAFTED — needs your input
  - Phone: NOT YET DRAFTED — needs your input (not in any doc)
  - Email: danflashllc@gmail.com (from Support.md; use your personal email
    instead if you'd rather App Review reach you directly)
- **Notes** — paste (condensed from ReviewerNotes.md, ~2,300 chars, fits
  the field):

MoshPit is a real-time video effects instrument. It takes live video
(camera, a photo-library video, or a network stream), applies a
"datamoshing" glitch effect on the GPU, and lets the user perform it live,
record it, or send it over the local network to VJ/streaming software. No
account, no login, no server component, no data collection.

HOW TO TEST WITHOUT SPECIAL HARDWARE
1. Launch and allow camera access. The live feed smears where things move —
wave a hand at the camera; that's the core effect.
2. Swipe from the left edge for mosh modes; from the right for sliders and
an XY pad. The circular arrow resets to a clean frame.
3. Recording: tap record, wave, tap again — the clip lands in the free
in-app session gallery with a share sheet. Saving recordings directly to
Photos is the single in-app purchase (below). The shutter (snapshot) button
saves a still to Photos with no purchase.
4. Network output needs NO NDI hardware/software: in the Output panel
enable "MJPEG Server", then open http://<device-ip>:8080/stream in any
browser on the same Wi-Fi to see the live output.

PERMISSIONS
- Camera: the primary video input; frames are processed on-device and never
uploaded.
- Microphone: only while recording, so clips have sound.
- Photo library add: snapshots (free) and recordings (after Pro unlock).
- Photo library read: picking a library video as a mosh source.
- Local network + Bonjour (_ndi._tcp.): NDI output to VJ software
(Resolume, OBS, VDMX) and the MJPEG stream above. Prompted only when the
user enables a network output; no internet/analytics traffic.

IN-APP PURCHASE
One IAP: "MoshPit Pro" (com.moshpit.app.pro), non-consumable, unlocks
saving recorded videos to Photos. Everything else — all modes, effects,
outputs, recording itself, the session gallery, sharing, snapshots — is
free. When a non-purchaser stops a recording, the clip is kept in the
session gallery and an upgrade sheet is offered; after purchase (or Restore
Purchases, on the same sheet) the pending save completes. StoreKit 2;
testable with a sandbox Apple account.

OTHER
- Strobe safety: a flicker limiter capped at 3 Hz is ON by default; raising
it shows a one-time photosensitivity warning.
- Users can paste their own HLS URL as a source; the app ships with no
content and rejects DRM-protected media.
- Requires a Metal device (all iOS 17 hardware); the simulator has no
camera.

## App Store Version Release

- **Recommendation (not a fill-in value):** choose **"Manually release this
  version"** so you control launch timing after approval — you can flip to
  automatic on a later version. This is a recommendation, not something the
  docs mandate.
