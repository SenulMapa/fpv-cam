import SwiftUI
import AVFoundation
import Photos

struct ContentView: View {
    @State private var settings  = SettingsStore()
    @State private var capture   = CaptureService()
    @State private var recorder  = Recorder()
    @State private var renderer: MetalSplitRenderer?

    // UI state
    @State private var isRecording   = false
    @State private var torchOn       = false
    @State private var showSettings  = false
    @State private var errorMessage: String?

    // Shorthand accessors
    private var video:    VideoSettings    { settings.video    }
    private var lens:     LensSettings     { settings.lens     }
    private var exposure: ExposureSettings { settings.exposure }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // MARK: Camera preview (Metal split-view)
            if let renderer {
                MetalViewHost(
                    renderer: renderer,
                    onTap: { pt, size in handleTap(at: pt, viewSize: size) },
                    onLongPress: { handleLongPress() },
                    onPinch: { delta in handlePinch(delta: delta) }
                )
                .ignoresSafeArea()
            }

            // Center divider — pure SwiftUI overlay, no Metal involvement
            if video.showCenterGrid {
                Rectangle()
                    .fill(Color.white.opacity(0.5))
                    .frame(width: 1)
                    .ignoresSafeArea()
            }

            // AF/AE lock indicator
            if exposure.isFocusLocked {
                VStack {
                    HStack {
                        Spacer()
                        Label("AF/AE Locked", systemImage: "lock.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.yellow)
                            .padding(8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding()
                    }
                    Spacer()
                }
            }

            // MARK: HUD
            VStack(spacing: 0) {
                // Top row: lens selector + torch
                HStack {
                    // P0-B: discrete lens buttons
                    HStack(spacing: 4) {
                        ForEach(lens.availableZoomFactors, id: \.self) { factor in
                            Button {
                                lens.zoomFactor = factor
                                Task { try? await capture.setZoomFactor(factor) }
                            } label: {
                                Text(lensLabel(for: factor))
                                    .font(.caption.bold())
                                    .foregroundStyle(abs(lens.zoomFactor - factor) < 0.05 ? .black : .white)
                                    .frame(width: 38, height: 38)
                                    .background(
                                        abs(lens.zoomFactor - factor) < 0.05
                                            ? Color.white : Color.white.opacity(0.15),
                                        in: Circle()
                                    )
                            }
                        }
                    }
                    .padding(.leading, 16)

                    Spacer()

                    // P1: Torch button (only when device has one)
                    if lens.hasTorch {
                        Button {
                            torchOn.toggle()
                            Task { try? await capture.setTorch(on: torchOn) }
                        } label: {
                            Image(systemName: torchOn ? "bolt.fill" : "bolt.slash.fill")
                                .font(.title3)
                                .foregroundStyle(torchOn ? .yellow : .white)
                                .padding(12)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .padding(.trailing, 16)
                    }
                }
                .padding(.top, 16)

                // P1: Exposure compensation slider
                HStack {
                    Image(systemName: "sun.min")
                        .foregroundStyle(.white)
                    Slider(
                        value: Binding(
                            get: { Double(exposure.exposureBias) },
                            set: { v in
                                exposure.exposureBias = Float(v)
                                Task { try? await capture.setExposureBias(Float(v)) }
                            }
                        ),
                        in: Double(exposure.minExposureBias)...Double(max(exposure.maxExposureBias, exposure.minExposureBias + 0.1))
                    )
                    .accentColor(.yellow)
                    Image(systemName: "sun.max")
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)

                Spacer()

                // P2: Pro controls (behind toggle)
                if exposure.isProMode {
                    ProControlsView(exposure: exposure, capture: capture)
                        .padding(.bottom, 8)
                }

                // Bottom row: settings · record · photo
                HStack(spacing: 36) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(14)
                            .background(.ultraThinMaterial, in: Circle())
                    }

                    // Record button
                    Button { Task { await toggleRecording() } } label: {
                        ZStack {
                            Circle()
                                .stroke(Color.white, lineWidth: 3)
                                .frame(width: 72, height: 72)
                            RoundedRectangle(cornerRadius: isRecording ? 6 : 36)
                                .fill(isRecording ? Color.red : Color.white)
                                .frame(width: isRecording ? 28 : 56, height: isRecording ? 28 : 56)
                                .animation(.spring(response: 0.2), value: isRecording)
                        }
                    }

                    // P1: Still photo button
                    Button { Task { await capturePhoto() } } label: {
                        Image(systemName: "camera.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                    }
                }
                .padding(.bottom, 40)
            }

            // Error banner
            if let msg = errorMessage {
                Text(msg)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings)
                .onDisappear { syncSettings() }
        }
        .task { await startCapture() }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    // MARK: - Camera startup

    private func startCapture() async {
        guard let r = MetalSplitRenderer(video: video) else {
            errorMessage = "Metal is not available on this device."
            return
        }
        r.recorder = recorder
        renderer = r   // triggers MetalViewHost.makeUIView → r.configure(mtkView:)

        do {
            try await capture.configure(video: video, lens: lens, exposure: exposure)
            await capture.setVideoDelegate(r)
            await capture.setAudioDelegate(recorder)
            await capture.start()
            try await capture.apply(video: video, lens: lens)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Recording

    private func toggleRecording() async {
        if isRecording {
            isRecording = false
            _ = await recorder.stopRecording()
        } else {
            do {
                try recorder.startRecording(
                    outputURL: Recorder.tempURL(),
                    videoSize: video.resolution.recordingSize,
                    codec: video.codec
                )
                isRecording = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - P1: Photo capture

    private func capturePhoto() async {
        do {
            let data = try await capture.capturePhoto()
            await savePhoto(data: data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func savePhoto(data: Data) async {
        guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, data: data, options: nil)
        }
    }

    // MARK: - P1: Tap-to-focus

    /// Maps an MTKView tap point to an AVFoundation device coordinate and sends it to the actor.
    ///
    /// Coordinate approximation: the split view maps both eye halves to the same camera texture.
    /// We fold the tap into one half's UV ([0,1]²), then pass it directly as the device point.
    /// This skips barrel-distortion inversion — error is small near the centre and acceptable
    /// as a v1 approximation.  A future version should apply the inverse of Shaders.metal:barrelDistort.
    @MainActor
    private func handleTap(at point: CGPoint, viewSize: CGSize) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        let halfW = viewSize.width / 2.0
        let u = (point.x.truncatingRemainder(dividingBy: halfW)) / halfW
        let v = point.y / viewSize.height
        let devicePoint = CGPoint(x: max(0, min(u, 1)), y: max(0, min(v, 1)))

        exposure.isFocusLocked = false
        Task { try? await capture.focusAndExpose(at: devicePoint, lock: false) }
    }

    @MainActor
    private func handleLongPress() {
        // Lock AF/AE at the screen centre (no tap point for long-press — use last tapped point or centre).
        let centrePoint = CGPoint(x: 0.5, y: 0.5)
        exposure.isFocusLocked = true
        Task { try? await capture.focusAndExpose(at: centrePoint, lock: true) }
    }

    // MARK: - P1: Pinch-zoom

    @MainActor
    private func handlePinch(delta: CGFloat) {
        let newZoom = (lens.zoomFactor * delta)
            .clamped(to: lens.minZoomFactor...lens.maxZoomFactor)
        lens.zoomFactor = newZoom
        Task { try? await capture.rampZoom(to: newZoom) }
    }

    // MARK: - Settings sync

    /// Push renderer display params and device configuration after settings sheet closes.
    private func syncSettings() {
        renderer?.ipd = video.ipd
        renderer?.showCenterGrid = video.showCenterGrid
        Task { try? await capture.apply(video: video, lens: lens) }
    }

    // MARK: - Helpers

    private func lensLabel(for factor: CGFloat) -> String {
        if factor == 0.5 { return ".5×" }
        if factor == 1.0 { return "1×"  }
        if factor == 2.0 { return "2×"  }
        if factor == 5.0 { return "5×"  }
        return String(format: "%.1f×", factor)
    }
}

// MARK: - P2: Pro controls sub-view

private struct ProControlsView: View {
    var exposure: ExposureSettings
    var capture: CaptureService

    var body: some View {
        VStack(spacing: 8) {
            // Manual ISO
            HStack {
                Text("ISO").font(.caption).foregroundStyle(.white).frame(width: 36)
                Slider(
                    value: Binding(
                        get: { Double(exposure.manualISO) },
                        set: { v in
                            exposure.manualISO = Float(v)
                            Task { try? await capture.setManualExposure(iso: Float(v),
                                                                        durationSeconds: exposure.manualShutterSeconds) }
                        }
                    ),
                    in: Double(exposure.manualISOMin)...Double(max(exposure.manualISOMax, exposure.manualISOMin + 1))
                )
                Text("\(Int(exposure.manualISO))").font(.caption).foregroundStyle(.white).frame(width: 50)
            }

            // Manual shutter
            HStack {
                Text("1/\(shutterDenominator)").font(.caption).foregroundStyle(.white).frame(width: 36)
                Slider(
                    value: Binding(
                        get: { -log2(max(exposure.manualShutterSeconds, 1e-6)) },
                        set: { v in
                            let dur = pow(2.0, -v)
                            exposure.manualShutterSeconds = dur
                            Task { try? await capture.setManualExposure(iso: exposure.manualISO,
                                                                        durationSeconds: dur) }
                        }
                    ),
                    in: -log2(max(exposure.manualShutterMaxSeconds, 1e-6))...(-log2(max(exposure.manualShutterMinSeconds, 1e-9)))
                )
                Text("1/\(shutterDenominator)s").font(.caption).foregroundStyle(.white).frame(width: 50)
            }

            // Manual focus
            HStack {
                Text("Focus").font(.caption).foregroundStyle(.white).frame(width: 36)
                Slider(
                    value: Binding(
                        get: { Double(exposure.manualFocusPosition) },
                        set: { v in
                            exposure.manualFocusPosition = Float(v)
                            Task { try? await capture.setManualFocus(lensPosition: Float(v)) }
                        }
                    ),
                    in: 0...1
                )
                Image(systemName: "infinity").font(.caption).foregroundStyle(.white).frame(width: 50)
            }

            // White balance temperature
            HStack {
                Text("WB").font(.caption).foregroundStyle(.white).frame(width: 36)
                Slider(
                    value: Binding(
                        get: { Double(exposure.whiteBalanceTemp) },
                        set: { v in
                            exposure.whiteBalanceTemp = Float(v)
                            Task { try? await capture.setManualWhiteBalance(temp: Float(v),
                                                                             tint: exposure.whiteBalanceTint) }
                        }
                    ),
                    in: 2000...8000
                )
                Text("\(Int(exposure.whiteBalanceTemp))K").font(.caption).foregroundStyle(.white).frame(width: 50)
            }

            // Auto-restore button
            Button("Reset to Auto") {
                exposure.isFocusLocked = false
                Task {
                    try? await capture.setAutoExposure()
                    try? await capture.unlockFocusAndExposure()
                    try? await capture.setAutoWhiteBalance()
                }
            }
            .font(.caption)
            .foregroundStyle(.yellow)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    private var shutterDenominator: Int {
        Int(round(1.0 / max(exposure.manualShutterSeconds, 1e-6)))
    }
}

// MARK: - Comparable clamping helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
