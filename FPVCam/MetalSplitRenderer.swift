import Metal
import MetalKit
import AVFoundation
import CoreVideo

// MTKViewDelegate that renders live camera frames as split-view with barrel distortion.
// Receives CVPixelBuffers from CaptureService via captureOutput(_:didOutput:from:).
final class MetalSplitRenderer: NSObject, MTKViewDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {

    // MARK: - Metal objects
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let renderPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var textureCache: CVMetalTextureCache?

    // MARK: - State
    private var latestTexture: MTLTexture?
    private let textureLock = NSLock()

    var settings: SettingsStore

    // MARK: - Init

    init?(mtkView: MTKView, settings: SettingsStore) {
        guard
            let device = MTLCreateSystemDefaultDevice(),
            let queue = device.makeCommandQueue()
        else { return nil }

        self.device = device
        self.commandQueue = queue
        self.settings = settings

        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true

        // Build render pipeline from Shaders.metal
        let lib = device.makeDefaultLibrary()!
        let vertFn = lib.makeFunction(name: "splitVertex")!
        let fragFn = lib.makeFunction(name: "splitFragment")!

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertFn
        desc.fragmentFunction = fragFn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.renderPipeline = pipeline

        // Sampler: bilinear, clamp
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        self.sampler = device.makeSamplerState(descriptor: sd)!

        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)

        super.init()
        mtkView.delegate = self
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
    }

    // MARK: - Frame ingestion

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let cache = textureCache else { return }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil,
                                                  .bgra8Unorm, w, h, 0, &cvTexture)
        guard let cvTex = cvTexture,
              let tex = CVMetalTextureGetTexture(cvTex) else { return }

        textureLock.lock()
        latestTexture = tex
        textureLock.unlock()
    }

    // MARK: - MTKViewDelegate

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

        var params = eyeParams()
        enc.setVertexBytes(&params, length: MemoryLayout<EyeParams>.size, index: 0)
        enc.setFragmentBytes(&params, length: MemoryLayout<EyeParams>.size, index: 0)

        // Draw 6 verts × 2 instances (left eye + right eye)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 2)

        if settings.showCenterGrid {
            drawCenterLine(encoder: enc, drawable: drawable)
        }

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

    private func eyeParams() -> EyeParams {
        // Convert mm IPD to NDC offset: screen half-width is 1.0 NDC.
        // ipd in settings is in metres; divide by estimated screen width (≈0.14 m) → fraction of half-screen.
        let ipdNDC = (settings.ipd / 0.14) * 0.5
        return EyeParams(ipd: ipdNDC)
    }

    // Simple center vertical line overlay using a passthrough pass
    private func drawCenterLine(encoder: MTLRenderCommandEncoder, drawable: CAMetalDrawable) {
        // Drawn as a thin scissor rect clear — minimal overhead, no extra pipeline needed.
        // Half-width in pixels: drawable.texture.width / 2, ±1 pixel.
        let mid = drawable.texture.width / 2
        encoder.setScissorRect(MTLScissorRect(x: mid - 1, y: 0, width: 2, height: drawable.texture.height))
        // Can't clear in existing encoder; handled by a CPU overlay in SwiftUI instead.
        encoder.setScissorRect(MTLScissorRect(x: 0, y: 0,
                                               width: drawable.texture.width,
                                               height: drawable.texture.height))
    }
}
