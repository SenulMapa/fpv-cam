import AVFoundation
import Photos

// Wraps AVAssetWriter to record raw CMSampleBuffers from CaptureService.
// The video track gets the undistorted CVPixelBuffer — no split-view baked in.
final class Recorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false

    private(set) var isRecording = false

    // MARK: - Start / Stop

    func startRecording(outputURL: URL, videoSize: CGSize) throws {
        guard !isRecording else { return }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: videoSize.width,
            AVVideoHeightKey: videoSize.height,
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        vInput.transform = CGAffineTransform(rotationAngle: 0)

        let aSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ]
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
        aInput.expectsMediaDataInRealTime = true

        writer.add(vInput)
        writer.add(aInput)

        self.assetWriter = writer
        self.videoInput = vInput
        self.audioInput = aInput
        self.sessionStarted = false
        self.isRecording = true

        writer.startWriting()
    }

    func stopRecording() async -> URL? {
        guard isRecording, let writer = assetWriter else { return nil }
        isRecording = false
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        await writer.finishWriting()

        let url = writer.outputURL
        assetWriter = nil
        videoInput = nil
        audioInput = nil
        sessionStarted = false

        await saveToPhotos(url: url)
        return url
    }

    // MARK: - Sample buffer ingestion

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isRecording,
              let writer = assetWriter,
              writer.status == .writing else { return }

        let isVideo = connection.mediaType == .video

        if !sessionStarted {
            let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: ts)
            sessionStarted = true
        }

        if isVideo, let vInput = videoInput, vInput.isReadyForMoreMediaData {
            vInput.append(sampleBuffer)
        } else if !isVideo, let aInput = audioInput, aInput.isReadyForMoreMediaData {
            aInput.append(sampleBuffer)
        }
    }

    // MARK: - Save to Photos

    private func saveToPhotos(url: URL) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
        } catch {
            print("FPVCam: failed to save to Photos — \(error)")
        }
    }
}

extension Recorder {
    static func tempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("fpvcam-\(Int(Date.now.timeIntervalSince1970)).mov")
    }
}
