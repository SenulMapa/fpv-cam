@preconcurrency import AVFoundation
import CoreMedia

actor CaptureService {

    private(set) var isRunning = false
    private(set) var isAuthorized = false

    private let session = AVCaptureSession()
    let videoOutput = AVCaptureVideoDataOutput()
    let audioOutput = AVCaptureAudioDataOutput()
    let photoOutput = AVCapturePhotoOutput()
    private let outputQueue = DispatchQueue(label: "com.senulmapa.fpvcam.capture", qos: .userInteractive)

    /// Retained for all subsequent device-mutation calls (must stay inside this actor).
    private var videoDevice: AVCaptureDevice?

    // MARK: - Configure

    /// Sets up the capture session and populates `lens` / `video.supportedFrameRates` / exposure
    /// limits from the chosen device so the UI reflects actual hardware.
    func configure(video: VideoSettings, lens: LensSettings, exposure: ExposureSettings) async throws {
        guard await requestPermissions() else { return }
        isAuthorized = true

        session.beginConfiguration()
        // inputPriority lets us drive format selection ourselves (P0-C).
        session.sessionPreset = .inputPriority
        let device = try addVideoInput()
        try addAudioInput()
        setupVideoOutput()
        setupAudioOutput()
        setupPhotoOutput()
        session.commitConfiguration()

        videoDevice = device
        populateLensInfo(device: device, lens: lens)
        populateSupportedFormats(device: device, video: video)
        populateExposureLimits(device: device, exposure: exposure)
    }

    private func requestPermissions() async -> Bool {
        let video = await AVCaptureDevice.requestAccess(for: .video)
        let audio = await AVCaptureDevice.requestAccess(for: .audio)
        return video && audio
    }

    @discardableResult
    private func addVideoInput() throws -> AVCaptureDevice {
        let device = preferredVideoDevice()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
        session.addInput(input)
        return device
    }

    /// P0-B: prefer the widest virtual multi-lens device for optical zoom and lens switching.
    private func preferredVideoDevice() -> AVCaptureDevice {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInTripleCamera,
                .builtInDualWideCamera,
                .builtInDualCamera,
                .builtInWideAngleCamera,
            ],
            mediaType: .video,
            position: .back
        )
        if let found = discovery.devices.first { return found }
        if let fb = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) { return fb }
        return AVCaptureDevice.default(for: .video)!  // should never reach here
    }

    private func addAudioInput() throws {
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
    }

    private func setupVideoOutput() {
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(videoOutput) else { return }
        session.addOutput(videoOutput)
        // P0-A: set stabilization .off explicitly on the connection at session setup time.
        if let conn = videoOutput.connection(with: .video) {
            conn.videoRotationAngle = 0
            if conn.isVideoStabilizationSupported {
                conn.preferredVideoStabilizationMode = .off
            }
        }
    }

    private func setupAudioOutput() {
        guard session.canAddOutput(audioOutput) else { return }
        session.addOutput(audioOutput)
    }

    private func setupPhotoOutput() {
        guard session.canAddOutput(photoOutput) else { return }
        session.addOutput(photoOutput)
        photoOutput.isHighResolutionCaptureEnabled = true
    }

    // MARK: - Device-info population (called once after configure)

    private func populateLensInfo(device: AVCaptureDevice, lens: LensSettings) {
        let minZ = device.minAvailableVideoZoomFactor
        let maxZ = device.maxAvailableVideoZoomFactor
        lens.minZoomFactor = minZ
        lens.maxZoomFactor = maxZ
        lens.hasTorch = device.hasTorch

        // Discrete zoom levels: show 0.5× / 1× / 2× / 5× that fall within device range.
        let candidates: [CGFloat] = [0.5, 1.0, 2.0, 5.0]
        let available = candidates.filter { $0 >= minZ - 0.01 && $0 <= maxZ + 0.01 }
        lens.availableZoomFactors = available.isEmpty ? [1.0] : available
    }

    private func populateSupportedFormats(device: AVCaptureDevice, video: VideoSettings) {
        var matrix: [VideoSettings.Resolution: [VideoSettings.FrameRate]] = [:]
        for res in VideoSettings.Resolution.allCases {
            let supported = VideoSettings.FrameRate.allCases.filter { fps in
                bestFormat(for: device, fps: fps.rawValue, resolution: res) != nil
            }
            matrix[res] = supported.isEmpty ? [.fps30] : supported
        }
        video.supportedFrameRates = matrix
    }

    private func populateExposureLimits(device: AVCaptureDevice, exposure: ExposureSettings) {
        exposure.minExposureBias = device.minExposureTargetBias
        exposure.maxExposureBias = device.maxExposureTargetBias
        let fmt = device.activeFormat
        exposure.manualISOMin = fmt.minISO
        exposure.manualISOMax = fmt.maxISO
        exposure.manualShutterMinSeconds = fmt.minExposureDuration.seconds
        exposure.manualShutterMaxSeconds = fmt.maxExposureDuration.seconds
    }

    // MARK: - Delegates

    func setVideoDelegate(_ d: (any AVCaptureVideoDataOutputSampleBufferDelegate)?) {
        videoOutput.setSampleBufferDelegate(d, queue: outputQueue)
    }

    func setAudioDelegate(_ d: (any AVCaptureAudioDataOutputSampleBufferDelegate)?) {
        audioOutput.setSampleBufferDelegate(d, queue: outputQueue)
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        session.startRunning()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        session.stopRunning()
        isRunning = false
    }

    // MARK: - Bulk settings apply (P0-A stabilization · P0-B zoom · P0-C format/fps)

    /// Call after the settings sheet closes.  One lockForConfiguration covers format, fps,
    /// zoom, stabilization, and (optionally) Apple Log color space atomically.
    func apply(video: VideoSettings, lens: LensSettings) throws {
        guard let device = videoDevice else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        // P0-C: switch to the format that covers the chosen resolution + fps.
        if let fmt = bestFormat(for: device, fps: video.frameRate.rawValue, resolution: video.resolution) {
            device.activeFormat = fmt
        }

        let dur = CMTime(value: 1, timescale: CMTimeScale(video.frameRate.rawValue))
        if device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameDuration <= dur && $0.maxFrameDuration >= dur
        }) {
            device.activeVideoMinFrameDuration = dur
            device.activeVideoMaxFrameDuration = dur
        }

        // P0-B: zoom (clamp to current format limits)
        device.videoZoomFactor = max(device.minAvailableVideoZoomFactor,
                                     min(lens.zoomFactor, device.maxAvailableVideoZoomFactor))

        // P0-A: stabilization OFF for live passthrough (spec default); set explicitly.
        if let conn = videoOutput.connection(with: .video), conn.isVideoStabilizationSupported {
            conn.preferredVideoStabilizationMode = video.stabilizationEnabled ? .auto : .off
        }

        // P2: Apple Log color space when that codec is selected.
        applyColorSpaceIfNeeded(device: device, codec: video.codec)
    }

    // MARK: - Format selection (P0-C)

    private func bestFormat(for device: AVCaptureDevice,
                            fps: Int,
                            resolution: VideoSettings.Resolution) -> AVCaptureDevice.Format? {
        let (tw, th) = resolution.sensorDimensions

        // First: exact dimension + fps match.
        let exact = device.formats.filter { fmt in
            let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            guard d.width == tw, d.height == th else { return false }
            return fmt.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= Double(fps) - 0.1 }
        }
        if let f = exact.first { return f }

        // Fallback: any fps-matching format, closest area.
        let targetArea = Int(tw) * Int(th)
        return device.formats
            .filter { fmt in
                fmt.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= Double(fps) - 0.1 }
            }
            .min { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                return abs(Int(da.width) * Int(da.height) - targetArea)
                     < abs(Int(db.width) * Int(db.height) - targetArea)
            }
    }

    // MARK: - P0-B + P1: Zoom

    /// Discrete lens button — hard jump.
    func setZoomFactor(_ factor: CGFloat) throws {
        guard let device = videoDevice else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.videoZoomFactor = max(device.minAvailableVideoZoomFactor,
                                     min(factor, device.maxAvailableVideoZoomFactor))
    }

    /// Pinch gesture — smooth ramp.
    func rampZoom(to factor: CGFloat, rate: Float = 8.0) throws {
        guard let device = videoDevice else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        let clamped = max(device.minAvailableVideoZoomFactor,
                         min(factor, device.maxAvailableVideoZoomFactor))
        device.ramp(toVideoZoomFactor: clamped, withRate: rate)
    }

    // MARK: - P1: Tap-to-focus & expose

    /// `devicePoint` is in AVFoundation coordinate space: (0,0) = top-left, (1,1) = bottom-right.
    /// `lock: true` skips to .locked mode (long-press behaviour).
    func focusAndExpose(at devicePoint: CGPoint, lock: Bool) throws {
        guard let device = videoDevice else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = devicePoint
            if lock {
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
            } else {
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            }
        }
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = devicePoint
            if lock {
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            } else {
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            }
        }
    }

    func unlockFocusAndExposure() throws {
        guard let device = videoDevice else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
    }

    // MARK: - P1: Exposure bias

    func setExposureBias(_ bias: Float) throws {
        guard let device = videoDevice else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.setExposureTargetBias(max(device.minExposureTargetBias,
                                        min(bias, device.maxExposureTargetBias)))
    }

    // MARK: - P1: Torch

    func setTorch(on: Bool, level: Float = 1.0) throws {
        guard let device = videoDevice, device.hasTorch else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if on {
            try device.setTorchModeOn(level: min(1.0, max(0.0, level)))
        } else {
            device.torchMode = .off
        }
    }

    // MARK: - P1: Photo capture

    /// Captures a full-resolution JPEG still; AVFoundation retains the delegate.
    func capturePhoto() async throws -> Data {
        guard videoDevice != nil else { throw CaptureError.noCameraAvailable }
        let output = photoOutput   // local copy avoids crossing actor isolation in @Sendable closure
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = PhotoDelegate(continuation: continuation)
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
        }
    }

    // MARK: - P2: Manual exposure

    func setManualExposure(iso: Float, durationSeconds: Double) throws {
        guard let device = videoDevice else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        let fmt = device.activeFormat
        let clampedISO = max(fmt.minISO, min(iso, fmt.maxISO))
        let raw = CMTime(seconds: durationSeconds, preferredTimescale: 1_000_000)
        let dur: CMTime = raw < fmt.minExposureDuration ? fmt.minExposureDuration
                        : raw > fmt.maxExposureDuration ? fmt.maxExposureDuration : raw
        device.setExposureModeCustom(duration: dur, iso: clampedISO)
    }

    func setAutoExposure() throws {
        guard let device = videoDevice else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
    }

    // MARK: - P2: Manual focus

    func setManualFocus(lensPosition: Float) throws {
        guard let device = videoDevice else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.setFocusModeLocked(lensPosition: max(0.0, min(lensPosition, 1.0)))
    }

    // MARK: - P2: White balance

    func setManualWhiteBalance(temp: Float, tint: Float) throws {
        guard let device = videoDevice, device.isWhiteBalanceModeSupported(.locked) else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        let ttv = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temp, tint: tint)
        var g = device.deviceWhiteBalanceGains(for: ttv)
        let m = device.maxWhiteBalanceGain
        g.redGain   = max(1.0, min(g.redGain,   m))
        g.greenGain = max(1.0, min(g.greenGain, m))
        g.blueGain  = max(1.0, min(g.blueGain,  m))
        device.setWhiteBalanceModeLocked(with: g)
    }

    func setAutoWhiteBalance() throws {
        guard let device = videoDevice else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
    }

    // MARK: - P2: Apple Log color space

    private func applyColorSpaceIfNeeded(device: AVCaptureDevice, codec: VideoSettings.Codec) {
        let target: AVCaptureColorSpace = (codec == .appleLog) ? .appleLog : .sRGB
        guard device.activeFormat.supportedColorSpaces.contains(target) else { return }
        device.activeColorSpace = target
    }
}

// MARK: - Photo delegate

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let continuation: CheckedContinuation<Data, Error>

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
        super.init()
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error { continuation.resume(throwing: error); return }
        guard let data = photo.fileDataRepresentation() else {
            continuation.resume(throwing: CaptureError.photoDataUnavailable); return
        }
        continuation.resume(returning: data)
    }
}

// MARK: - Errors

enum CaptureError: Error {
    case noCameraAvailable
    case cannotAddInput
    case photoDataUnavailable
}
