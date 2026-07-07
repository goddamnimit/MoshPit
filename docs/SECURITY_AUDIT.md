# MoshPit Security and Privacy Audit

This document records the findings and fixes from the security and privacy audit of MoshPit.

---

## Executive Summary

- **What data MoshPit collects:** None. MoshPit does not gather, transmit, store, or process any telemetry, analytics, or personal identifiers.
- **What leaves the device:** Only user-initiated NDI streams, user-initiated MJPEG streams (with token authorization), and photos/videos explicitly exported by the user to the local Photo Library.

---

## Audit Findings & Fixes

### 1. Permissions (Lazy & Honest)

| Severity | Status | Key/Finding | Description of Fix |
| :--- | :--- | :--- | :--- |
| **Medium** | **Fixed** | Camera requested at launch | Lazy-load camera check added to `AppModel.init`. Camera starts only if already authorized; otherwise, a test pattern is safely loaded. |
| **Medium** | **Fixed** | Camera denial silent failure | CameraSource now delegates error status to `SourceManager` when access is denied, updating the slot status to "Camera access denied". |
| **Medium** | **Fixed** | Mic permission & AVAudioSession | Mic permission is requested lazily only when "Record mic audio" is active. `AVAudioSession` is activated solely during recording and set to `.ambient` on stop. |
| **High** | **Fixed** | Local network / Bonjour prompt | Deferred calling `NDIlib_initialize()` in `NDISender` to when the user first starts NDI, preventing Bonjour discovery/registration at launch. |

### 2. Data Handling (On-Device Isolation)

| Severity | Status | Key/Finding | Description of Fix |
| :--- | :--- | :--- | :--- |
| **High** | **Fixed** | iCloud backup for Automations | The custom `Automations` directory in Documents is now explicitly marked as `isExcludedFromBackup = true` to prevent iCloud upload. |
| **High** | **Fixed** | Lingering temporary videos | Added explicit cleanup of the temporary recording file in `MoshRecorder.stop()` on all exit paths, including when Photos access is denied. |
| **High** | **Fixed** | MJPEG server access gap | Implemented secure token-based authentication. A dynamic UUID session token is generated on startup, verified on incoming HTTP requests, and shown in the UI. |

### 3. Network Security

| Severity | Status | Key/Finding | Description of Fix |
| :--- | :--- | :--- | :--- |
| **High** | **Fixed** | HLS URL validation and HTTP check | Input HLS URLs are strictly validated: non-HTTPS and non-HLS (`.m3u8`) inputs are rejected in the UI with a detailed error message. |
| **Info** | **N/A** | Outbound telemetry/analytics | Confirmed zero calls to Firebase, Sentry, Mixpanel, Amplitude, etc. Outbound traffic is exclusively user-initiated. |

### 4. Metal & GPU Safety

| Severity | Status | Key/Finding | Description of Fix |
| :--- | :--- | :--- | :--- |
| **High** | **Fixed** | Canvas size bounds check | Added strict clamping in `MoshEngine.canvasDimensions` restricting the target longEdge and source resolution dimensions to a max of 4096px to avoid out-of-memory GPU crashes. |
| **Medium** | **Fixed** | TextureCache thread safety | Locked texture ingest and flush operations inside `TextureIngestor` with an `NSLock` to prevent race conditions across different queues. |

### 5. Recording & Privacy Indicator

| Severity | Status | Key/Finding | Description of Fix |
| :--- | :--- | :--- | :--- |
| **High** | **Fixed** | Precise camera status dot | Changed `CameraSource.stop()` to run synchronously via `queue.sync` to ensure `AVCaptureSession` is fully stopped before the app enters the background. |
| **Medium** | **Fixed** | Stop recording on background | Modified `scenePhaseChanged` to automatically stop any active video recording when the app transitions to the background. |

### 6. Input Validation

| Severity | Status | Key/Finding | Description of Fix |
| :--- | :--- | :--- | :--- |
| **Medium** | **Fixed** | Automation key validation | Updated `loadSessions()` to perform schema key validation, rejecting any file that contains arbitrary ParameterID injections. |
| **Low** | **Fixed** | MIDI parameter clamping | Confirmed that `ParameterStore.set` automatically handles out-of-bounds inputs by clamping values to the parameter's closed range. |
