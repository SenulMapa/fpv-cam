import SwiftUI

struct SettingsView: View {
    let settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    // Shorthand
    private var video:    VideoSettings    { settings.video    }
    private var lens:     LensSettings     { settings.lens     }
    private var exposure: ExposureSettings { settings.exposure }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Video
                Section {
                    // Resolution
                    Picker("Resolution", selection: Binding(get: { video.resolution },
                                                           set: { video.resolution = $0 })) {
                        ForEach(VideoSettings.Resolution.allCases) { r in
                            Text(r.rawValue + (r.isHigherLatency ? " ↑ latency" : "")).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)

                    // Frame rate — only show options the device supports for the chosen resolution
                    let supportedFps = video.supportedFrameRates[video.resolution] ?? VideoSettings.FrameRate.allCases
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Frame Rate")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(VideoSettings.FrameRate.allCases) { fps in
                                    let supported = supportedFps.contains(fps)
                                    Button {
                                        guard supported else { return }
                                        video.frameRate = fps
                                        // If high fps requires 1080p, auto-downgrade resolution.
                                        if fps.requiresSingleLens, video.resolution == .uhd4K {
                                            video.resolution = .hd1080p
                                        }
                                    } label: {
                                        Text(fps.label)
                                            .font(.caption.bold())
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(video.frameRate == fps ? Color.accentColor
                                                        : supported ? Color.secondary.opacity(0.2)
                                                        : Color.secondary.opacity(0.08),
                                                        in: Capsule())
                                            .foregroundStyle(supported ? .primary : .tertiary)
                                    }
                                    .disabled(!supported)
                                }
                            }
                        }
                        if video.frameRate.requiresSingleLens {
                            Text("120/240 fps requires 1080p and may disable multi-lens switching.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("Stabilization (adds ~150–300 ms)",
                           isOn: Binding(get: { video.stabilizationEnabled },
                                         set: { video.stabilizationEnabled = $0 }))

                } header: { Text("Video") }

                // MARK: - Pro / Codec (P2)
                Section {
                    Toggle("Pro Mode",
                           isOn: Binding(get: { exposure.isProMode },
                                         set: { exposure.isProMode = $0 }))

                    if exposure.isProMode {
                        Picker("Codec", selection: Binding(get: { video.codec },
                                                           set: { video.codec = $0 })) {
                            ForEach(VideoSettings.Codec.allCases) { c in
                                Text(c.rawValue).tag(c)
                            }
                        }
                        if video.codec == .proRes422 {
                            Text("ProRes 422 files are large; requires iPhone 13 Pro or later and fast storage.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if video.codec == .appleLog {
                            Text("Apple Log uses a flat color profile for grading. Capture color space is set to Apple Log where supported; codec remains HEVC.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Pro") }

                // MARK: - Headset
                Section("Headset") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("IPD — \(Int(video.ipd * 1000)) mm")
                            .font(.subheadline)
                        Slider(
                            value: Binding(get: { video.ipd }, set: { video.ipd = $0 }),
                            in: 0.055...0.075,
                            step: 0.001
                        )
                    }
                }

                // MARK: - Overlay
                Section("Overlay") {
                    Toggle("Center Grid Line",
                           isOn: Binding(get: { video.showCenterGrid },
                                         set: { video.showCenterGrid = $0 }))
                    Toggle("Latency HUD",
                           isOn: Binding(get: { video.showLatencyHUD },
                                         set: { video.showLatencyHUD = $0 }))
                    if video.showLatencyHUD {
                        Text("Shows a rolling-average estimate of the software pipeline latency (capture→draw). Excludes sensor exposure time and display scan-out delay.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // MARK: - Latency note
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("About latency")
                            .font(.subheadline.bold())
                        Text("""
                            The inherent ~3-frame motion-to-photon floor is unavoidable — the camera \
                            sensor, ISP pipeline, and display refresh stack up. \
                            Stabilization adds another 150–300 ms and is OFF by default. \
                            4K is heavier GPU work and adds more latency than 1080p.
                            """)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
