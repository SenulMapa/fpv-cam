import SwiftUI
import AVFoundation

struct ContentView: View {
    @State private var settings = SettingsStore()
    @State private var capture = CaptureService()
    @State private var recorder = Recorder()
    @State private var renderer: MetalSplitRenderer?

    @State private var isRecording = false
    @State private var showSettings = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let renderer {
                MetalViewHost(renderer: renderer)
                    .ignoresSafeArea()
            }

            // Center divider — pure SwiftUI overlay, no Metal involvement
            if settings.showCenterGrid {
                Rectangle()
                    .fill(Color.white.opacity(0.5))
                    .frame(width: 1)
                    .ignoresSafeArea()
            }

            // HUD
            VStack {
                Spacer()
                HStack(spacing: 44) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(14)
                            .background(.ultraThinMaterial, in: Circle())
                    }

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

                    // Balanced spacer
                    Color.clear.frame(width: 52, height: 52)
                }
                .padding(.bottom, 40)
            }

            if let msg = errorMessage {
                Text(msg)
                    .foregroundStyle(.red)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings)
                .onDisappear { syncRendererSettings() }
        }
        .task { await startCapture() }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    // MARK: - Camera startup

    private func startCapture() async {
        guard let r = MetalSplitRenderer(settings: settings) else {
            errorMessage = "Metal is not available on this device."
            return
        }
        r.recorder = recorder
        renderer = r   // triggers MetalViewHost to appear → r.configure(mtkView:) is called

        do {
            try await capture.configure(settings: settings)
            await capture.setVideoDelegate(r)
            await capture.setAudioDelegate(recorder)
            await capture.start()
            try await capture.apply(settings: settings)
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
            let size: CGSize = settings.resolution == .hd1080p
                ? CGSize(width: 1920, height: 1080)
                : CGSize(width: 3840, height: 2160)
            do {
                try recorder.startRecording(outputURL: Recorder.tempURL(), videoSize: size)
                isRecording = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // Push changed settings into renderer rendering params and re-apply device config
    private func syncRendererSettings() {
        renderer?.ipd = settings.ipd
        renderer?.showCenterGrid = settings.showCenterGrid
        Task { try? await capture.apply(settings: settings) }
    }
}
