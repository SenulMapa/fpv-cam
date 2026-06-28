import CoreGraphics
import Observation

/// Lens selection and zoom state.
/// `availableZoomFactors`, `minZoomFactor`, `maxZoomFactor`, and `hasTorch`
/// are populated by `CaptureService.configure` after device discovery.
@Observable
final class LensSettings {

    /// Active zoom factor — shared state between discrete lens buttons and pinch gesture.
    var zoomFactor: CGFloat = 1.0

    /// Discrete zoom factors this device supports, expressed as the underlying `videoZoomFactor`
    /// values (relative to the chosen virtual device).  On a triple camera these might be
    /// [1.0, 2.0, 6.0] where 1.0 is the ultrawide and 2.0 is the "1×" wide camera.
    /// Populated by `CaptureService.configure`.
    var availableZoomFactors: [CGFloat] = [1.0]

    /// Maps each underlying `videoZoomFactor` → human-readable display label (e.g. ".5×", "1×", "3×").
    /// Populated by `CaptureService.configure` at the same time as `availableZoomFactors`.
    var lensDisplayLabels: [CGFloat: String] = [1.0: "1×"]

    var minZoomFactor: CGFloat = 1.0
    var maxZoomFactor: CGFloat = 1.0

    /// Whether the active device has a torch (populated at startup).
    var hasTorch: Bool = false
}

extension LensSettings: @unchecked Sendable {}
