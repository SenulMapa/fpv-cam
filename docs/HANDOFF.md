You're picking up an approved iOS project. I'm Adam (SenulMapa). Read the full
design spec first — it has the architecture, the critical AVFoundation constraint,
the fork base, and module boundaries:

    /home/senul/fpv-cam/docs/specs/2026-06-29-fpv-cam-design.md

PROJECT: "FPV Cam" — iOS 26 SwiftUI native app. iPhone strapped to head/chest (or
slid into a Cardboard-style headset) for first-person-view footage.

ONE camera feed forks two ways:
  (a) live split-view passthrough on screen (Metal, per-eye barrel distortion,
      adjustable IPD) so I can see through the headset lenses, AND
  (b) a CLEAN single-frame .mov recording (no split, no distortion baked in).

CRITICAL CONSTRAINT (already researched): you CANNOT attach two
AVCaptureVideoPreviewLayers to one AVCaptureSession. Do NOT try. The preview is
Metal-rendered from raw frames. Pipeline:

  AVCaptureSession → AVCaptureVideoDataOutput → per-frame CMSampleBuffer
    ├─ Metal texture → MTKView, render twice (L/R) with barrel-distortion shader + IPD
    └─ when recording: AVAssetWriter appends the RAW single CVPixelBuffer (+ audio)

FORK BASE: Apple's modern AVCam sample (SwiftUI + Swift concurrency, actor-based
CaptureService): https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app
Keep its session lifecycle/permissions/UI scaffolding; REPLACE its
AVCaptureVideoPreviewLayer preview + AVCaptureMovieFileOutput recording with the
VideoDataOutput → Metal + AVAssetWriter pipeline. Read NextLevel
(github.com/NextLevel/NextLevel) for buffer-processing patterns; don't fork it whole.

MVP FEATURES (all in scope, do not cut): live split-view passthrough w/ IPD slider;
record button (clean .mov + audio); settings (resolution, 60/120fps, FOV/zoom,
stabilization toggle, IPD slider, center grid line); save to Photos/Files.

INFRA (confirmed, no ambiguity):
- iOS 26 minimum deployment target.
- Bundle ID: com.senulmapa.fpvcam — no DEVELOPMENT_TEAM, CODE_SIGNING_ALLOWED=NO.
  AltStore re-signs on-device with the user's own free Apple ID at install time.
- Zero GitHub Secrets. Public repo is safe because there is nothing to leak.
- Distribution: GitHub Actions builds unsigned .ipa → attaches to GitHub Release.
  AltStore source is a source.json at repo root, served from:
    https://raw.githubusercontent.com/SenulMapa/fpv-cam/main/source.json
- 120 fps: gate at runtime via AVCaptureDevice format capability check —
  show the option only if the device supports it.
- XcodeGen for project generation (same pattern as Hermes Native / Tani Native).

REPO: https://github.com/SenulMapa/fpv-cam (public, already created, spec committed).
Local path: /home/senul/fpv-cam

WORKFLOW: use superpowers skills — invoke writing-plans to turn the spec into an
implementation plan, then test-driven-development for the build. Must test on a real
device (Simulator has no camera).

Start by reading the spec, then propose the implementation plan.
