import CoreGraphics
import Observation

/// Lens selection and zoom state.
/// `availableZoomFactors`, `minZoomFactor`, `maxZoomFactor`, and `hasTorch`
/// are populated by `CaptureService.configure` after device discovery.
@Observable
final class LensSettings {

    /// Active zoom factor — shared state between discrete lens buttons and pinch gesture.
    var zoomFactor: CGFloat = 1.0

    /// Discrete zoom factors this device supports, e.g. [0.5, 1.0, 2.0, 5.0] on a triple camera.
    /// Only buttons within [minZoomFactor, maxZoomFactor] are shown in the HUD.
    var availableZoomFactors: [CGFloat] = [1.0]

    var minZoomFactor: CGFloat = 1.0
    var maxZoomFactor: CGFloat = 1.0

    /// Whether the active device has a torch (populated at startup).
    var hasTorch: Bool = false
}

extension LensSettings: @unchecked Sendable {}
