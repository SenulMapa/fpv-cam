@preconcurrency import AVFoundation
import Metal
import MetalKit
import QuartzCore
import CoreVideo

final class MetalSplitRenderer: NSObject, MTKViewDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {

    // MARK: - Metal
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let renderPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var textureCache: CVMetalTextureCache?

    // MARK: - Frame state (guarded by textureLock; accessed from capture queue + MTKView thread)
    private var latestTexture: MTLTexture?
    /// Retained alongside latestTexture to ensure the MTLTexture's backing IOSurface stays alive
    /// between captureOutput and the next draw call.
    private var latestCVTex: CVMetalTexture?
    /// Presentation timestamp of the latest frame in host-clock seconds (CACurrentMediaTime domain).
    private var latestPTSSeconds: Double = 0
    private let textureLock = NSLock()

    // MARK: - Rendering params (written once from main, read from MTKView thread — stale-frame is acceptable)
    nonisolated(unsafe) var ipd: Float = 0.064
    nonisolated(unsafe) var showCenterGrid: Bool = false

    // MARK: - Latency HUD
    /// Rolling-average estimate of the software pipeline latency: from when the frame was captured
    /// (CMSampleBuffer PTS) to when the Metal draw call begins.  This covers the AVFoundation
    /// capture queue → texture upload → draw-call start portion only; it does NOT include sensor
    /// exposure time, ISP processing before the PTS is stamped, or display scan-out delay.
    /// Written only on the MTKView draw thread; safe to read from the main thread at low frequency
    /// (Double read/write on 64-bit ARM is hardware-atomic for this display-only purpose).
    nonisolated(unsafe) var measuredLatencyMs: Double = 0

    // Recorder receives forwarded video frames for clean recording
    weak var recorder: Recorder?

    // MARK: - Init

    init?(video: VideoSettings) {
        guard
            let dev = MTLCreateSystemDefaultDevice(),
            let queue = dev.makeCommandQueue(),
            let lib = dev.makeDefaultLibrary(),
            let vertFn = lib.makeFunction(name: "splitVertex"),
            let fragFn = lib.makeFunction(name: "splitFragment")
        else { return nil }

        device = dev
        commandQueue = queue

        let pipeDesc = MTLRenderPipelineDescriptor()
        pipeDesc.vertexFunction = vertFn
        pipeDesc.fragmentFunction = fragFn
        pipeDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        guard let pipeline = try? dev.makeRenderPipelineState(descriptor: pipeDesc) else { return nil }
        renderPipeline = pipeline

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = dev.makeSamplerState(descriptor: sd)!

        CVMetalTextureCacheCreate(nil, nil, dev, nil, &textureCache)

        super.init()

        ipd = video.ipd
        showCenterGrid = video.showCenterGrid
    }

    // Called by MetalViewHost.makeUIView — binds this renderer to the view that will display it.
    @MainActor func configure(mtkView: MTKView) {
        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        mtkView.backgroundColor = .black
        mtkView.delegate = self
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        // P0-A: reduce Metal drawable buffering from default 3 → 2 to cut up to one frame of lag.
        // maximumDrawableCount lives on CAMetalLayer (the underlying layer of MTKView on iOS).
        (mtkView.layer as? CAMetalLayer)?.maximumDrawableCount = 2
    }

    // MARK: - Frame ingestion (capture queue)

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // INVARIANT: forward the raw, pre-distortion buffer to the recorder first.
        recorder?.appendVideo(sampleBuffer)

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let cache = textureCache else { return }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)

        var cvTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .bgra8Unorm, w, h, 0, &cvTex)

        // P0-A: flush the cache each frame to prevent drift / stale-texture stutter.
        // Safe to do here: cvTex is still retained by the local variable so the newly created
        // texture is not evicted — the flush only discards older unreferenced entries.
        CVMetalTextureCacheFlush(cache, 0)

        guard let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return }

        // Capture the presentation timestamp for latency measurement (same clock as CACurrentMediaTime).
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        textureLock.lock()
        latestTexture = tex
        // Retain the CVMetalTexture so its backing IOSurface (and thus the MTLTexture) stays valid
        // until after the next draw call consumes it.
        latestCVTex   = cvTex
        if pts.isValid { latestPTSSeconds = pts.seconds }
        textureLock.unlock()
    }

    // MARK: - MTKViewDelegate (MTKView display-link thread)

    func draw(in view: MTKView) {
        // Snapshot current frame's texture and capture timestamp atomically.
        let drawTime = CACurrentMediaTime()
        textureLock.lock()
        let tex = latestTexture
        let pts = latestPTSSeconds
        textureLock.unlock()

        // Update rolling-average latency estimate (EMA, α=0.15).
        // Sanity-check: pts > 0 means we've received at least one frame; cap at 2 s to ignore
        // stale values after startup or a format switch.
        if pts > 0 {
            let rawMs = (drawTime - pts) * 1000.0
            if rawMs > 0 && rawMs < 2000 {
                measuredLatencyMs = measuredLatencyMs * 0.85 + rawMs * 0.15
            }
        }

        guard let tex,
              let drawable = view.currentDrawable,
              let passDesc = view.currentRenderPassDescriptor,
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)
        else { return }

        enc.setRenderPipelineState(renderPipeline)
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)

        var params = makeEyeParams()
        enc.setVertexBytes(&params, length: MemoryLayout<EyeParams>.size, index: 0)
        enc.setFragmentBytes(&params, length: MemoryLayout<EyeParams>.size, index: 0)

        // Single draw call, two instances: instance 0 = left eye, instance 1 = right eye
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 2)
        enc.endEncoding()

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    // MARK: - Helpers

    private struct EyeParams {
        var ipd: Float
        var k1: Float = 0.22
        var k2: Float = 0.24
    }

    private func makeEyeParams() -> EyeParams {
        // Convert physical IPD (metres) to NDC offset fraction.
        // Estimated headset screen width ≈ 0.14 m; each eye covers half the NDC range.
        EyeParams(ipd: (ipd / 0.14) * 0.5)
    }
}
