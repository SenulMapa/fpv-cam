import AVFoundation
import CoreMedia

// Actor-owned capture session. Drives both Metal preview and AVAssetWriter recording
// from a single AVCaptureVideoDataOutput — never attaches a preview layer.
actor CaptureService: NSObject {

    // MARK: - Published state (main-actor observers poll these)
    private(set) var isRunning = false
    private(set) var isAuthorized = false

    // MARK: - Internals
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let outputQueue = DispatchQueue(label: "com.senulmapa.fpvcam.capture", qos: .userInteractive)

    // Weak refs so actors can receive frames without retain cycles
    weak var videoDelegate: (any AVCaptureVideoDataOutputSampleBufferDelegate)?
    weak var audioDelegate: (any AVCaptureAudioDataOutputSampleBufferDelegate)?

    // MARK: - Setup

    func configure(settings: SettingsStore) async throws {
        guard await requestPermissions() else { return }
        isAuthorized = true

        session.beginConfiguration()
        session.sessionPreset = settings.resolution.sessionPreset

        try addVideoInput()
        try addAudioInput()
        setupVideoOutput()
        setupAudioOutput()

        session.commitConfiguration()
    }

    private func requestPermissions() async -> Bool {
        let video = await AVCaptureDevice.requestAccess(for: .video)
        let audio = await AVCaptureDevice.requestAccess(for: .audio)
        return video && audio
    }

    private func addVideoInput() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CaptureError.noCameraAvailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
        session.addInput(input)
    }

    private func addAudioInput() throws {
        guard let device = AVCaptureDevice.default(for: .audio) else { return }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { return }
        session.addInput(input)
    }

    private func setupVideoOutput() {
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(videoOutput) else { return }
        session.addOutput(videoOutput)
        videoOutput.connection(with: .video)?.videoRotationAngle = 0
    }

    private func setupAudioOutput() {
        guard session.canAddOutput(audioOutput) else { return }
        session.addOutput(audioOutput)
    }

    // MARK: - Delegates (set before start)

    func setVideoDelegate(_ d: any AVCaptureVideoDataOutputSampleBufferDelegate) {
        videoDelegate = d
        videoOutput.setSampleBufferDelegate(d, queue: outputQueue)
    }

    func setAudioDelegate(_ d: any AVCaptureAudioDataOutputSampleBufferDelegate) {
        audioDelegate = d
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

    // MARK: - Device tuning

    func apply(settings: SettingsStore) throws {
        guard let device = (session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.first?.device) else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        // Zoom
        device.videoZoomFactor = max(device.minAvailableVideoZoomFactor,
                                     min(settings.zoomFactor, device.maxAvailableVideoZoomFactor))

        // Frame rate
        let targetFPS = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate.rawValue))
        let supported = device.activeFormat.videoSupportedFrameRateRanges
        if supported.contains(where: { $0.minFrameDuration <= targetFPS && $0.maxFrameDuration >= targetFPS }) {
            device.activeVideoMinFrameDuration = targetFPS
            device.activeVideoMaxFrameDuration = targetFPS
        }

        // Stabilization
        if let conn = videoOutput.connection(with: .video), conn.isVideoStabilizationSupported {
            conn.preferredVideoStabilizationMode = settings.stabilizationEnabled ? .auto : .off
        }
    }
}

enum CaptureError: Error {
    case noCameraAvailable
    case cannotAddInput
}
