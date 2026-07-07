# NDI Output Setup

**Status: integrated.** This project vendors the NDI SDK at `Vendor/NDI/`
(copied from `/Library/NDI SDK for Apple/` — the standard SDK's static-lib
form: `lib/iOS/libndi_ios.a` + `include/Processing.NDI.Lib.h`, exposed to
Swift via `Vendor/NDI/module.modulemap`). Device builds (Debug and Release)
compile and link the real `NDISender`; simulator builds automatically fall
back to `NDIStub` because the build settings below are scoped to
`[sdk=iphoneos*]` — the shipped `libndi_ios.a` is fat `x86_64 + arm64` with
no arm64-simulator slice, so it cannot link on Apple Silicon simulators.

If `Vendor/NDI/` is deleted (or on a machine without the SDK), device builds
also fall back to the stub via `#if canImport(NDI)` — the project always
builds.

## How it's wired

App-target build settings (both configurations):

```
SWIFT_INCLUDE_PATHS[sdk=iphoneos*]  = $(PROJECT_DIR)/Vendor/NDI
LIBRARY_SEARCH_PATHS[sdk=iphoneos*] = $(PROJECT_DIR)/Vendor/NDI/lib
OTHER_LDFLAGS[sdk=iphoneos*]        = -lndi_ios -lc++ -framework VideoToolbox
                                      -framework CoreMedia -framework CoreVideo
                                      -framework Accelerate
INFOPLIST_FILE                      = Support/Info.plist
```

`Support/Info.plist` merges into the generated Info.plist and provides the
NDI discovery requirements:

- `NSBonjourServices` -> `_ndi._tcp.`
- `NSLocalNetworkUsageDescription` -> user-facing local-network string

## Sender implementation notes (Output/Outputs.swift)

- `NDIlib_initialize()` is called once (static token) and gates `isAvailable`.
- The sender is created as **"MoshPit"** with `clock_video = false` — the
  render loop paces frames; NDI must never block.
- Frames: BGRA (`NDIlib_FourCC_video_type_BGRA`),
  `line_stride_in_bytes = width * 4`, progressive,
  `timecode = NDIlib_send_timecode_synthesize`, square pixels.
- The render thread only enqueues a GPU blit into a shared-storage staging
  texture; readback + `NDIlib_send_send_video_v2` run on a dedicated queue,
  and frames drop (never queue) when the sender is busy.
- Teardown: toggling output off or backgrounding the app drains the send
  queue and calls `NDIlib_send_destroy`.

## Updating the SDK

Re-copy from the new SDK into `Vendor/NDI/` (`include/` + `lib/iOS/`). If a
future SDK ships an `NDI.xcframework` with a simulator slice instead, embed
the xcframework in the target, delete the `[sdk=iphoneos*]` scoping so the
module resolves everywhere, and remove the stub-on-simulator caveat above.
