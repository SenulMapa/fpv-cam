import AVFoundation
import Observation

/// Resolution / frame-rate / codec / headset display settings.
/// Kept in a separate file to stay focused; `LensSettings` and `ExposureSettings` hold the rest.
@Observable
final class VideoSettings {

    // MARK: - Session settings

    var resolution: Resolution = .hd1080p
    var frameRate: FrameRate = .fps60
    /// P0-A: default OFF — stabilization buffers a window of frames, adding 150–300 ms latency.
    /// For live FPV passthrough the dominant lag source; leave post-process stabilization to editing.
    var stabilizationEnabled: Bool = false
    var codec: Codec = .hevc

    // MARK: - Headset display

    var ipd: Float = 0.064       // metres; default 64 mm
    var showCenterGrid: Bool = false

    // MARK: - Latency HUD (toggleable; default on so we can measure out-of-box)

    /// When true, a rolling-average capture-to-draw latency estimate is shown as a small badge.
    /// This measures the software pipeline portion (capture queue → Metal draw call start);
    /// it does NOT include sensor exposure time or display scan-out delay.
    var showLatencyHUD: Bool = true

    // MARK: - Constraint matrix (populated by CaptureService.configure after device discovery)

    /// Maps each resolution to the frame-rate options the device actually supports for that resolution.
    var supportedFrameRates: [Resolution: [FrameRate]] = [
        .hd1080p: FrameRate.allCases,
        .uhd4K:   [.fps24, .fps30, .fps60],
    ]

    // MARK: - Resolution

    enum Resolution: String, CaseIterable, Identifiable {
        case hd1080p = "1080p"
        case uhd4K   = "4K"
        var id: String { rawValue }

        var sessionPreset: AVCaptureSession.Preset {
            switch self {
            case .hd1080p: .hd1920x1080
            case .uhd4K:   .hd4K3840x2160
            }
        }

        var recordingSize: CGSize {
            switch self {
            case .hd1080p: CGSize(width: 1920, height: 1080)
            case .uhd4K:   CGSize(width: 3840, height: 2160)
            }
        }

        /// 4K is ~3× heavier Metal work per frame → higher latency on the live preview.
        var isHigherLatency: Bool { self == .uhd4K }

        var sensorDimensions: (width: Int32, height: Int32) {
            switch self {
            case .hd1080p: (1920, 1080)
            case .uhd4K:   (3840, 2160)
            }
        }
    }

    // MARK: - Frame rate

    enum FrameRate: Int, CaseIterable, Identifiable {
        case fps24  = 24
        case fps30  = 30
        case fps60  = 60
        case fps120 = 120
        case fps240 = 240
        var id: Int { rawValue }
        var label: String { "\(rawValue) fps" }
        /// 120 / 240 fps require a single physical lens and are only available at 1080p on most devices.
        var requiresSingleLens: Bool { self == .fps120 || self == .fps240 }
    }

    // MARK: - Codec

    enum Codec: String, CaseIterable, Identifiable {
        case hevc      = "HEVC"
        case proRes422 = "ProRes 422"
        case appleLog  = "Apple Log"
        var id: String { rawValue }
    }
}

extension VideoSettings: @unchecked Sendable {}
