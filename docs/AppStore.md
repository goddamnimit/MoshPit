# App Store Metadata — MoshPit 1.0

All fields below are ready to paste into App Store Connect. Character counts
are noted where Apple enforces a limit.

## App Name

**MoshPit** (7 characters; limit 30)

If the plain name is taken on App Store Connect, fall back to
**MoshPit — Datamosh Instrument** (29 characters).

## Subtitle (limit 30 characters)

**Real-time datamosh instrument** (29 characters)

## Description (limit 4000 characters — this copy is ~2,700)

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

## Keywords (limit 100 characters)

`datamosh,glitch,vj,video effects,ndi,glitch art,video synth,camera fx,pixel sort,visuals,live` (93 characters)

## URLs

- **Support URL:** `https://goddamnimit.github.io/MoshPit/Support.html`
- **Privacy Policy URL:** `https://goddamnimit.github.io/MoshPit/PrivacyPolicy.html`

## What's New in Version 1.0

Initial release.

- Seven real-time mosh modes with block-match and optical-flow motion engines
- Effect chain: echo, slit-scan, weaver, pixel sort, proc-amp, mirror and color finishers
- Two-LFO rhythm engine with tap tempo and mod matrix
- 3D point cloud, wireframe, and textured-object render paths
- A/B source mixer with luma and mask wipes
- MIDI CC learn, automation record/replay, hardware keyboard shortcuts
- NDI and MJPEG network output; 1080p recording, snapshots, session gallery
- Optional one-time MoshPit Pro unlock: save recordings straight to Photos

## In-App Purchases (must be created in App Store Connect)

One product. It must exist in App Store Connect and be attached to the 1.0
version before submission — a first IAP is reviewed together with the app
version and cannot ship separately.

| Field | Value |
|---|---|
| Type | Non-consumable |
| Product ID | `com.moshpit.app.pro` (must match `ProManager.productID` exactly) |
| Reference name | MoshPit Pro |
| Display name (limit 30) | MoshPit Pro (11 characters) |
| Description (limit 45) | Save your recorded videos to Photos. (37 characters) |
| Price | USD 4.99 tier |

Checklist:
- Add at least the English (U.S.) localization above.
- Upload the required IAP review screenshot (the in-app upgrade sheet).
- Set the product to "Cleared for Sale".
- On the version page, add the IAP under "In-App Purchases" so it is
  submitted with the 1.0 review.
- "Restore Purchases" is implemented in the upgrade sheet (App Review
  requires a visible restore mechanism for non-consumables).

## Category & Rating Notes

- **Primary category:** Photo & Video. **Secondary:** Music (live-performance tooling).
- **Age rating:** 4+ (no user-generated content is shared; all questionnaire answers "No").
- The app contains an optional strobe feature; a flicker limiter capped at
  3 Hz is ON by default and raising it shows a photosensitivity warning
  in-app. Mention this in the Review Notes field (see ReviewerNotes.md).
