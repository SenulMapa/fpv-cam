@preconcurrency import AVFoundation
import Metal
import MetalKit
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
    private let textureLock = NSLock()

    // MARK: - Rendering params (written once from main, read from MTKView thread — stale-frame is acceptable)
    nonisolated(unsafe) var ipd: Float = 0.064
    nonisolated(unsafe) var showCenterGrid: Bool = false

    // Recorder receives forwarded video frames for clean recording
    weak var recorder: Recorder?

    // MARK: - Init

    init?(settings: SettingsStore) {
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

        ipd = settings.ipd
        showCenterGrid = settings.showCenterGrid
    }

    // Called by MetalViewHost.makeUIView — binds this renderer to the view that will display it
    func configure(mtkView: MTKView) {
        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        mtkView.backgroundColor = .black
        mtkView.delegate = self
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
    }

    // MARK: - Frame ingestion (capture queue)

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Forward raw buffer to recorder BEFORE any distortion — this is the clean single-frame recording
        recorder?.appendVideo(sampleBuffer)

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let cache = textureCache else { return }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)

        var cvTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .bgra8Unorm, w, h, 0, &cvTex)

        guard let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return }

        textureLock.lock()
        latestTexture = tex
        textureLock.unlock()
    }

    // MARK: - MTKViewDelegate (MTKView display-link thread)

    func draw(in view: MTKView) {
        textureLock.lock()
        let tex = latestTexture
        textureLock.unlock()

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
        // Convert physical IPD (metres) to NDC offset fraction
        // Estimated headset screen width ≈ 0.14 m; each eye covers half the NDC range
        EyeParams(ipd: (ipd / 0.14) * 0.5)
    }
}
