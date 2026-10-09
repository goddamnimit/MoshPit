# App Review Notes — MoshPit 1.0

Paste the text below into the "Notes" field in App Store Connect's App Review
Information section.

---

MoshPit is a real-time video effects instrument. It takes live video (camera,
a video file from the photo library, or a network video stream), applies a
"datamoshing" glitch effect on the GPU, and lets the user perform the effect
live, record the result to their photo library, or send it over the local
network to VJ/streaming software. There is no account, no login, no
server-side component, and no data collection of any kind.

HOW TO TEST WITHOUT ANY SPECIAL HARDWARE

1. Launch the app and allow camera access. The live camera feed appears on
   the canvas and immediately starts smearing where things move. Wave your
   hand in front of the camera — that's the core effect.
2. Swipe from the left edge to pick a different mosh mode; swipe from the
   right edge for sliders and an XY pad. Tap the circular arrow to reset to
   a clean frame.
3. Recording: tap the record button, wave at the camera, tap again — the
   clip lands in the free in-app session gallery with a small "MoshPit"
   watermark burned in. Free clips can be viewed, played, remixed and
   deleted in the app; exporting them (Share, Save to Files/Photos, Share to
   Social) and clean, watermark-free recordings and snapshots require the
   app's single in-app purchase (see below). The photo-library-add
   permission is used when an unlocked user saves a recording or snapshot.
4. Network output does NOT require NDI hardware or NDI software. In the
   Output panel, enable "MJPEG Server", then open
   `http://<device-ip>:8080/stream` in any web browser on a computer on the
   same Wi-Fi network. You will see the app's live output in the browser.
   This is the easiest way to verify the local-network feature.

WHY EACH PERMISSION IS REQUESTED

- Camera: the primary input. The live camera feed is the video source that
  gets moshed on the canvas. Frames are processed on-device on the GPU and
  are never uploaded anywhere.
- Microphone: only used while recording a video, so the saved clip has
  sound. The mic is not accessed at any other time.
- Photo library (add): saving snapshot images (free) and recorded videos
  (after the Pro unlock) that the user explicitly captures.
- Photo library (read): the user can pick a video from their library as a
  mosh source instead of the camera.
- Local network + Bonjour (`_ndi._tcp.`): the app can act as a video output
  for VJ software (Resolume, OBS, VDMX) over NDI, and serves the MJPEG
  stream described above. The local-network prompt appears only when the
  user enables a network output in the Output panel. Nothing is sent unless
  the user turns an output on; there is no internet/analytics traffic.

IN-APP PURCHASE

MoshPit has exactly one IAP: "MoshPit Pro" (`com.moshpit.app.pro`), a
non-consumable that removes the watermark from new recordings and
snapshots and unlocks exporting (Share sheet, Save to Files/Photos, Share to
Social). Everything else — all modes, effects, sources, NDI/MJPEG output,
recording, the session gallery (view/play/remix/delete) — is free. To test:
record a clip, open the Gallery from the left drawer and see the watermark;
tap the clip's menu > Share (or the Share button on the post-recording
toast) to see the unlock sheet; a sandbox purchase (or Restore Purchases on
the same sheet) completes the share. New recordings after unlocking have
no watermark. StoreKit 2; testable with a sandbox Apple account.

OTHER NOTES

- Strobe safety: the rhythm engine can flash the screen. A flicker limiter
  capped at 3 Hz is ON by default; raising the limit shows a one-time
  photosensitivity warning in-app.
- Network streams: users can paste their own HLS URL as a source. The app
  ships with no content; DRM-protected media is detected and rejected.
- The app requires a device with Metal (all supported iOS 17 devices) and
  works best on a physical device; the simulator has no camera.
