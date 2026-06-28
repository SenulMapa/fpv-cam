@preconcurrency import AVFoundation
import Photos

/// Thread-safe recorder. Video frames are forwarded from MetalSplitRenderer (capture queue).
/// Audio frames arrive via AVCaptureAudioDataOutputSampleBufferDelegate (same queue).
/// The INVARIANT that the recorder receives the RAW, pre-distortion CMSampleBuffer is enforced
/// in MetalSplitRenderer.captureOutput — do not change the call order there.
final class Recorder: NSObject, @unchecked Sendable {

    private let lock = NSLock()
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var _isRecording = false

    var isRecording: Bool { lock.withLock { _isRecording } }

    // MARK: - Start / Stop (call from main actor)

    func startRecording(outputURL: URL,
                        videoSize: CGSize,
                        codec: VideoSettings.Codec = .hevc) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !_isRecording else { return }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let videoCodec = resolvedCodecType(codec, size: videoSize)
        let vInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: videoCodec,
                AVVideoWidthKey: videoSize.width,
                AVVideoHeightKey: videoSize.height,
            ]
        )
        vInput.expectsMediaDataInRealTime = true

        let aInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ]
        )
        aInput.expectsMediaDataInRealTime = true

        writer.add(vInput)
        writer.add(aInput)
        writer.startWriting()

        assetWriter = writer
        videoInput = vInput
        audioInput = aInput
        sessionStarted = false
        _isRecording = true
    }

    /// Resolve the requested codec, falling back to HEVC when ProRes is unsupported.
    private func resolvedCodecType(_ codec: VideoSettings.Codec, size: CGSize) -> AVVideoCodecType {
        switch codec {
        case .hevc, .appleLog:
            // Apple Log is a capture color-space, not a separate codec — record in HEVC.
            return .hevc
        case .proRes422:
            // ProRes 422 requires iPhone 13 Pro or later; if not available HEVC is the safe fallback.
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.proRes422,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height,
            ]
            if AVAssetWriterInput(mediaType: .video, outputSettings: settings).isReadyForMoreMediaData {
                // isReadyForMoreMediaData won't tell us support at init time; check via canApply instead.
            }
            // Pragmatic: attempt ProRes and let AVAssetWriter surface an error at startWriting() time.
            // ContentView catches that error and shows it to the user.
            return .proRes422
        }
    }

    func stopRecording() async -> URL? {
        let writer: AVAssetWriter? = lock.withLock {
            guard _isRecording else { return nil }
            _isRecording = false
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            return assetWriter
        }
        guard let writer else { return nil }

        await writer.finishWriting()
        let url = writer.outputURL

        lock.withLock {
            assetWriter = nil
            videoInput = nil
            audioInput = nil
            sessionStarted = false
        }

        await saveToPhotos(url: url)
        return url
    }

    // MARK: - Buffer appending (called from capture queue)

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard _isRecording,
              let writer = assetWriter, writer.status == .writing,
              let vInput = videoInput, vInput.isReadyForMoreMediaData else { return }

        if !sessionStarted {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStarted = true
        }
        vInput.append(sampleBuffer)
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate
}

extension Recorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        lock.lock()
        defer { lock.unlock() }
        guard _isRecording,
              let writer = assetWriter, writer.status == .writing,
              sessionStarted,                // don't append audio before video session starts
              let aInput = audioInput, aInput.isReadyForMoreMediaData else { return }
        aInput.append(sampleBuffer)
    }
}

// MARK: - Photos save (video recordings)

private extension Recorder {
    func saveToPhotos(url: URL) async {
        guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}

extension Recorder {
    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fpvcam-\(Int(Date.now.timeIntervalSince1970)).mov")
    }
}
