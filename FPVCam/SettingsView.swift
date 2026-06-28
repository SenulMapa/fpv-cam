import SwiftUI
import AVFoundation

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    // Runtime check: does this device support 120 fps?
    private var supports120fps: Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return false
        }
        return device.activeFormat.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 120 }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Video") {
                    Picker("Resolution", selection: $settings.resolution) {
                        ForEach(SettingsStore.Resolution.allCases) { r in
                            Text(r.rawValue).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)

                    if supports120fps {
                        Picker("Frame Rate", selection: $settings.frameRate) {
                            ForEach(SettingsStore.FrameRate.allCases) { fps in
                                Text(fps.label).tag(fps)
                            }
                        }
                        .pickerStyle(.segmented)
                    } else {
                        LabeledContent("Frame Rate", value: "60 fps (120 not supported)")
                    }

                    Toggle("Stabilization", isOn: $settings.stabilizationEnabled)

                    LabeledContent("Zoom") {
                        Slider(value: $settings.zoomFactor, in: 1.0...5.0, step: 0.1)
                    }
                }

                Section("Headset") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("IPD — \(Int(settings.ipd * 1000)) mm")
                            .font(.subheadline)
                        Slider(value: $settings.ipd, in: 0.055...0.075, step: 0.001)
                    }
                }

                Section("Overlay") {
                    Toggle("Center Grid Line", isOn: $settings.showCenterGrid)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
