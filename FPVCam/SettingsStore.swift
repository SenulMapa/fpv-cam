import AVFoundation
import Observation

@Observable
final class SettingsStore {
    var resolution: Resolution = .hd1080p
    var frameRate: FrameRate = .fps60
    var zoomFactor: CGFloat = 1.0
    var stabilizationEnabled: Bool = true
    var ipd: Float = 0.064          // metres; default 64 mm
    var showCenterGrid: Bool = false

    enum Resolution: String, CaseIterable, Identifiable {
        case hd1080p = "1080p"
        case uhd4K   = "4K"
        var id: String { rawValue }

        var sessionPreset: AVCaptureSession.Preset {
            switch self {
            case .hd1080p: return .hd1920x1080
            case .uhd4K:   return .hd4K3840x2160
            }
        }
    }

    enum FrameRate: Int, CaseIterable, Identifiable {
        case fps60  = 60
        case fps120 = 120
        var id: Int { rawValue }
        var label: String { "\(rawValue) fps" }
    }
}
