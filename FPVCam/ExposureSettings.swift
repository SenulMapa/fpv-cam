import Observation

/// Focus, exposure, and white-balance state.
/// UI-observable counterpart to the device's AVCaptureDevice exposure/focus modes.
@Observable
final class ExposureSettings {

    // MARK: - Auto mode

    /// EV bias applied on top of continuous auto-exposure.
    var exposureBias: Float = 0.0
    /// Clamped to the device's min/max bias; populated by CaptureService.configure.
    var minExposureBias: Float = -2.0
    var maxExposureBias: Float = 2.0

    // MARK: - Lock state (reflects device state; set by CaptureService actions)

    var isFocusLocked: Bool = false

    // MARK: - Pro mode

    var isProMode: Bool = false

    // Manual exposure — bounded by activeFormat.minISO/maxISO and min/maxExposureDuration.
    var manualISO: Float = 100.0
    var manualISOMin: Float = 22.0
    var manualISOMax: Float = 6400.0

    var manualShutterSeconds: Double = 1.0 / 60.0
    var manualShutterMinSeconds: Double = 1.0 / 10_000.0
    var manualShutterMaxSeconds: Double = 1.0 / 3.0

    // Manual focus — 0…1 lens position.
    var manualFocusPosition: Float = 0.5

    // White balance temperature (K) and tint.
    var whiteBalanceTemp: Float = 5500.0
    var whiteBalanceTint: Float = 0.0
}

extension ExposureSettings: @unchecked Sendable {}
