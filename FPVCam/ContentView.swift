import SwiftUI
import AVFoundation

struct ContentView: View {
    @State private var settings = SettingsStore()
    @State private var capture = CaptureService()
    @State private var recorder = Recorder()
    @State private var renderer: MetalSplitRenderer?
    @State private var mtkView = MTKViewWrapper()

    @State private var isRecording = false
    @State private var showSettings = false
    @State private var error: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Live split-view passthrough
            if let renderer {
                MetalViewHost(renderer: renderer)
                    .ignoresSafeArea()
            }

            // Center divider line
            if settings.showCenterGrid {
                Rectangle()
                    .fill(Color.white.opacity(0.4))
                    .frame(width: 1)
                    .ignoresSafeArea()
            }

            // HUD overlay
            VStack {
                Spacer()
                HStack(spacing: 40) {
                    // Settings button
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }

                    // Record button
                    Button {
                        Task { await toggleRecording() }
                    } label: {
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

                    // Placeholder for future controls
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.bottom, 40)
            }

            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings)
        }
        .task { await startCapture() }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    // MARK: - Camera startup

    private func startCapture() async {
        let mtkView = MTKView()
        guard let r = MetalSplitRenderer(mtkView: mtkView, settings: settings) else {
            error = "Metal unavailable on this device."
            return
        }
        renderer = r

        do {
            try await capture.configure(settings: settings)
            await capture.setVideoDelegate(r)
            await capture.setAudioDelegate(recorder)
            await capture.start()
            try await capture.apply(settings: settings)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Recording

    private func toggleRecording() async {
        if isRecording {
            isRecording = false
            _ = await recorder.stopRecording()
        } else {
            let url = Recorder.tempURL()
            // Use session preset dimensions as video size
            let size = settings.resolution == .hd1080p
                ? CGSize(width: 1920, height: 1080)
                : CGSize(width: 3840, height: 2160)
            do {
                try recorder.startRecording(outputURL: url, videoSize: size)
                isRecording = true
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// Thin wrapper so we can pass MTKView as a @State without forcing a full re-render
private final class MTKViewWrapper: ObservableObject {}
