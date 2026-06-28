import SwiftUI
import MetalKit

// Bridges MTKView into SwiftUI. makeUIView is where the renderer gets bound to the view —
// this is the single point of MTKView ownership, fixing the disconnected-view bug.
struct MetalViewHost: UIViewRepresentable {
    let renderer: MetalSplitRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        renderer.configure(mtkView: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
