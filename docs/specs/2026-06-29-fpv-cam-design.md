# FPV Cam — Design Spec

**Date:** 2026-06-29
**Repo:** `SenulMapa/fpv-cam` (public)
**Platform:** iOS 26, SwiftUI native
**Status:** Approved design — ready for implementation

---

## What we're building

An iPhone app for capturing **first-person-view (FPV) footage** while the phone is
strapped to the head/chest, optionally slid into a Cardboard-style headset.

Two things happen from a **single rear camera feed**:

1. **Live split-view passthrough** rendered to the screen (two side-by-side eye images
   with lens barrel-distortion correction) so the wearer can see where they're going
   through the headset lenses.
2. **Clean single-frame recording** — the saved video is a normal, undistorted,
   single-frame `.mov`. The split view and distortion are *never* baked into the file.

This is "lane #3": see split live, record clean underneath.

---

## Critical architectural constraint

You **cannot** attach two `AVCaptureVideoPreviewLayer`s to one `AVCaptureSession` to
duplicate the viewfinder — iOS does not share the camera buffer that way.
(Refs: https://developer.apple.com/forums/thread/7286 ,
https://developer.apple.com/documentation/avfoundation/avcapturevideopreviewlayer )

Therefore the preview is **not** layer-based. We pull raw frames and render with Metal.

## Pipeline

```
AVCaptureSession (1 back camera, wide FOV)
        │
        └─ AVCaptureVideoDataOutput ──► delegate: per-frame CMSampleBuffer
                                              │
                        ┌─────────────────────┴─────────────────────┐
                        ▼                                            ▼
            Upload to Metal texture                     If recording:
            Render TWICE to MTKView:                    AVAssetWriter appends the
              - left eye + right eye                     RAW single CVPixelBuffer
              - barrel-distortion shader per eye         (undistorted, single frame)
              - adjustable IPD (eye spacing)                    │
                        ▼                                       ▼
            Live split-view passthrough                 clean FPV .mov on disk
```

One feed forks into **(a)** Metal split-view for the eyes and **(b)** clean
AVAssetWriter recording. Single capture pipeline, no double-session.

### Why AVAssetWriter (not AVCaptureMovieFileOutput)

We already own the frames in the `AVCaptureVideoDataOutput` delegate to feed Metal.
Routing those same `CMSampleBuffer`s into an `AVAssetWriter` keeps one source of truth
and guarantees the recording is the clean, pre-distortion frame. Add audio via an
`AVCaptureAudioDataOutput` writing to a second `AVAssetWriterInput`.

---

## Fork base & references

- **Skeleton — Apple AVCam sample** (SwiftUI + Swift concurrency, actor-based
  `CaptureService`, permissions, device discovery, recording UI):
  https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app
  - **Keep:** capture-session lifecycle, permissions flow, app structure, settings UI patterns.
  - **Replace:** its `AVCaptureVideoPreviewLayer` preview + `AVCaptureMovieFileOutput`
    recording with the `VideoDataOutput → Metal + AVAssetWriter` pipeline above.
- **Buffer/Metal pattern reference (read, do not fork wholesale):**
  https://github.com/NextLevel/NextLevel (MIT — custom CMSampleBuffer processing).
- **Rejected:** Mijick/Camera, SwiftyCam, CameraEngine — they abstract away the buffer
  pipeline we specifically need to control.

---

## MVP features (all confirmed in scope — do not cut)

1. **Live split-view passthrough** — Metal, per-eye barrel distortion, adjustable IPD slider.
2. **Record button** — toggles clean single-frame `.mov` recording via AVAssetWriter (+ audio).
3. **Settings:**
   - Resolution (e.g. 1080p / 4K)
   - Frame rate (60 / 120 fps)
   - FOV / zoom factor
   - Stabilization on/off
   - IPD / eye-spacing slider
   - Center grid line (alignment aid)
4. **Save** to Photos and/or Files.

## Explicitly out of scope (v1)

- Stereo *depth* (we have one lens — split view is the same image per eye, this is expected).
- AR overlays / object placement.
- External camera input.

---

## Suggested module boundaries

- `CaptureService` (actor) — owns `AVCaptureSession`, inputs, `AVCaptureVideoDataOutput`,
  `AVCaptureAudioDataOutput`. Exposes async config + a frame stream.
- `MetalSplitRenderer` — `MTKView` + shaders; takes a texture, renders left/right with
  barrel distortion and IPD offset.
- `Recorder` — wraps `AVAssetWriter` + inputs; `start()` / `stop()`; appends sample buffers.
- `SettingsStore` — observable settings (resolution, fps, FOV, stabilization, IPD, grid).
- SwiftUI views — viewfinder host (`MTKView` via `UIViewRepresentable`), record button, settings sheet.

## Shaders

- Barrel/pincushion distortion shader applied per eye to pre-distort the image so the
  headset lenses produce a rectified view. IPD shifts the two viewports horizontally.
- Keep distortion coefficients tunable (start with a standard Cardboard-style profile;
  expose in a debug/settings control for tuning against real lenses).

---

## Infra (reuse existing proven pipeline)

- **XcodeGen** project generation (same as Hermes Native / Tani Native).
- **GitHub Actions CI** → build signed `.ipa` → **AltStore OTA** distribution.
- Public repo `SenulMapa/fpv-cam`.

## Hardware test notes

- Must run on a real device (Simulator has no camera).
- Test at 60 and 120 fps for stabilization/latency headroom.
- Validate distortion profile against an actual Cardboard-style headset; expose IPD +
  distortion tuning so the wearer can dial it in.
```

