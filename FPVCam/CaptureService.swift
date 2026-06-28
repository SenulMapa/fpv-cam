@preconcurrency import AVFoundation
import CoreMedia

actor CaptureService {

    private(set) var isRunning = false
    private(set) var isAuthorized = false

    private let session = AVCaptureSession()
    let videoOutput = AVCaptureVideoDataOutput()
    let audioOutput = AVCaptureAudioDataOutput()
    private let outputQueue = DispatchQueue(label: "com.senulmapa.fpvcam.capture", qos: .userInteractive)

    // MARK: - Configure

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
        videoOutput.connection(with: .video)?.videoRotationAngle = 0
    }

    private func setupAudioOutput() {
        guard session.canAddOutput(audioOutput) else { return }
        session.addOutput(audioOutput)
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

    // MARK: - Device tuning

    func apply(settings: SettingsStore) throws {
        guard let device = session.inputs
            .compactMap({ $0 as? AVCaptureDeviceInput })
            .first?.device else { return }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        device.videoZoomFactor = max(device.minAvailableVideoZoomFactor,
                                     min(settings.zoomFactor, device.maxAvailableVideoZoomFactor))

        let targetDuration = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate.rawValue))
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        if ranges.contains(where: { $0.minFrameDuration <= targetDuration && $0.maxFrameDuration >= targetDuration }) {
            device.activeVideoMinFrameDuration = targetDuration
            device.activeVideoMaxFrameDuration = targetDuration
        }

        if let conn = videoOutput.connection(with: .video), conn.isVideoStabilizationSupported {
            conn.preferredVideoStabilizationMode = settings.stabilizationEnabled ? .auto : .off
        }
    }
}

enum CaptureError: Error {
    case noCameraAvailable
    case cannotAddInput
}
