import SwiftUI
import MetalKit

// Bridges MTKView into SwiftUI. The renderer is created once and retained by the parent.
struct MetalViewHost: UIViewRepresentable {
    let renderer: MetalSplitRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.backgroundColor = .black
        // Renderer sets itself as delegate in its init
        _ = renderer  // already configured
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // Renderer observes SettingsStore directly; no update needed here.
    }

    func makeCoordinator() -> Coordinator { Coordinator(renderer: renderer) }

    final class Coordinator {
        let renderer: MetalSplitRenderer
        init(renderer: MetalSplitRenderer) { self.renderer = renderer }
    }
}
