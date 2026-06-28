# FPV Cam v2 — Latency Fix + Full Camera Controls

**Date:** 2026-06-29
**Builds on:** `docs/specs/2026-06-29-fpv-cam-design.md` (v1, shipped & installable)
**Driver:** real-device feedback — "huge input lag", only one lens, no frame-rate
control, missing standard camera features.

Priorities: **P0** = ship first (the lag bug + the two named gaps), **P1/P2** =
camera features the user selected (all three buckets).

---

## P0-A — Kill the input lag (bug, do this first)

Phone passthrough has an inherent ~3-frame motion-to-photon floor — unavoidable. But
the current build stacks fixable latency on top. Fix in this order, biggest first:

1. **Disable video stabilization on the live connection.** `CaptureService.apply()`
   currently sets `.auto` when `stabilizationEnabled` (default `true`). iOS stabilization
   buffers a window of frames + crops → adds 150–300 ms. For a live FPV passthrough this
   is the dominant lag source. **Default stabilization OFF**, and when off set
   `connection.preferredVideoStabilizationMode = .off` explicitly. (It can't be "on for
   recording only" here — the `VideoDataOutput` connection feeds both preview and the
   recorder. If the user wants stabilized footage, that's a separate post-process; do not
   re-introduce preview latency for it.)
2. **Reduce Metal buffering.** In `MetalSplitRenderer.configure(mtkView:)` set
   `mtkView.maximumDrawableCount = 2` (default 3 → up to 2 extra frames) and keep
   `presentsWithTransaction = false`.
3. **Flush the texture cache each frame.** `MetalSplitRenderer.captureOutput` never calls
   `CVMetalTextureCacheFlush(cache, 0)` → drift/stutter over time. Add it after creating
   the texture.
4. **Default to 1080p, label 4K as "higher latency".** 4K BGRA per-frame Metal work is
   ~3× heavier.
5. Verify `alwaysDiscardsLateVideoFrames = true` stays on (already correct — prevents
   queue backup).

**Acceptance:** noticeably tighter than current build on a real device; document the
residual floor so it isn't mistaken for a bug.

## P0-B — All three lenses

`CaptureService.swift:36` hardcodes `.builtInWideAngleCamera`. Replace with a virtual
multi-lens device so iOS can use ultrawide + telephoto:

- Device discovery preference order: `.builtInTripleCamera` → `.builtInDualWideCamera`
  → `.builtInDualCamera` → `.builtInWideAngleCamera` (fallback).
- **Lens UI:** discrete `0.5× / 1× / 2× / 5×` buttons. Implement by setting
  `videoZoomFactor` to the device's `virtualDeviceSwitchOverVideoZoomFactors` boundaries
  so iOS auto-switches the physical lens; clamp to `minAvailableVideoZoomFactor` /
  `maxAvailableVideoZoomFactor`. Only show buttons for lenses the device actually has.
- **Gotcha:** high frame rates (120/240) and some formats are only available on a single
  physical lens — selecting them may disable lens switching. Surface this in the UI
  rather than silently failing (see P0-C interaction).

## P0-C — Frame-rate control (the deferred gap)

Current 120fps check tests the *preset's* `activeFormat`, which caps at 60, so it never
appears. Real fix:

- Offer `24 / 30 / 60 / 120 / 240` fps.
- On selection, search `device.formats` for the best format that
  `videoSupportedFrameRateRanges` covers at the chosen fps **and** matches the chosen
  resolution; `lockForConfiguration`, set `device.activeFormat`, then
  `activeVideoMin/MaxFrameDuration = CMTime(1, fps)`.
- Encode the constraint matrix in the UI: picking 120/240 may force 1080p and/or a single
  lens. Disable/grey incompatible resolution & lens options rather than erroring.

---

## P1 — Tap focus & exposure  (user-selected)

- Tap → focus + expose at point: `focusPointOfInterest` + `focusMode = .autoFocus`,
  `exposurePointOfInterest` + `exposureMode = .continuousAutoExposure`.
- **Coordinate mapping is non-trivial here** because there's no `AVCaptureVideoPreviewLayer`
  — the view is Metal split-view with barrel distortion. Map the tap like this: take the
  tap point in the `MTKView`, fold it into a single-eye `[0,1]²` UV (left half and right
  half map to the same texture), **invert the barrel distortion** (apply the inverse of
  `Shaders.metal: barrelDistort`), then convert to device coordinates
  (`(x,y)` with the camera's orientation). A first cut may skip distortion inversion
  (small error near center) — document the approximation.
- AF/AE **lock** on long-press (`.locked` modes); tap again to unlock.
- **Exposure compensation slider** → `setExposureTargetBias(_:)` within
  `minExposureTargetBias…maxExposureTargetBias`.

## P1 — Torch + pinch-zoom + photo  (user-selected)

- **Torch:** guard `device.hasTorch`; toggle `device.torchMode` /
  `setTorchModeOn(level:)`. (Front of an FPV rig — useful as a headlamp.)
- **Pinch-zoom:** `UIPinchGestureRecognizer` on the host view → ramp
  `videoZoomFactor` with `device.ramp(toVideoZoomFactor:withRate:)`; clamp to device max;
  cooperate with the P0-B discrete lens buttons (shared zoom-factor state).
- **Photo capture:** add `AVCapturePhotoOutput` to the session alongside the existing
  `AVCaptureVideoDataOutput` (both can coexist). Capture full-res stills, save via
  `PHPhotoLibrary` (reuse `Recorder.saveToPhotos` pattern). Add a still-shutter affordance
  distinct from the video record button.

## P2 — Pro / manual controls  (user-selected)

- **Manual exposure:** `setExposureModeCustom(duration:iso:)` with ISO + shutter sliders
  bounded by `activeFormat.min/maxISO` and `min/maxExposureDuration`.
- **Manual focus:** `setFocusModeLocked(lensPosition:)` slider `0…1`.
- **White balance:** `setWhiteBalanceModeLocked(with:)` from temperature/tint via
  `deviceWhiteBalanceGains(for:)`, clamped to `maxWhiteBalanceGain`.
- **Codec choice:** HEVC (default) / ProRes 422 / Apple Log.
  - ProRes: set `AVVideoCodecType.proRes422` in the `AVAssetWriterInput` video settings.
    Warn: 4K ProRes is very large and needs fast storage; gate by device support.
  - Apple Log: set `device.activeColorSpace = .appleLog` (where supported) for the capture;
    pair with an appropriate codec.
- Group these behind a "Pro" toggle so the default UI stays simple.

---

## Architecture notes for the implementer

- `SettingsStore` grows a lot — split into `VideoSettings` (res/fps/codec/stabilization),
  `LensSettings` (lens/zoom), and `ExposureSettings` (focus/exposure/WB/manual) to keep
  each file focused.
- Device configuration is increasingly stateful — funnel **all** `lockForConfiguration`
  mutations through `CaptureService` actor methods; never touch the device from the UI
  thread directly.
- Several features interact and must be resolved as a constraint set, not independently:
  **fps ↔ resolution ↔ lens** (high fps limits the other two), and
  **manual exposure ↔ tap-to-expose** (manual overrides tap). Centralize this so the UI
  can disable incompatible options instead of erroring.
- Keep the clean-recording invariant from v1: the recorder still receives the **raw,
  pre-distortion** buffer in `MetalSplitRenderer.captureOutput`.

## Verification

- Real device only (no camera in Simulator). Test each lens, each fps (confirm 120/240
  actually engages via the format switch, not just the toggle), torch, pinch + discrete
  zoom agreement, tap-to-focus accuracy across the split view, photo capture saved to
  Photos, and each codec produces a playable file.
- Re-confirm latency improvement after P0-A on-device, side-by-side with the current build.
