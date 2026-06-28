import SwiftUI
import MetalKit

/// Bridges MTKView into SwiftUI and installs the gesture recognizers needed for
/// P1 features (tap-to-focus, long-press AF/AE lock, pinch-zoom).
struct MetalViewHost: UIViewRepresentable {
    let renderer: MetalSplitRenderer

    /// Called with (tapPoint, viewSize); caller maps to AVFoundation device coordinates.
    var onTap: ((CGPoint, CGSize) -> Void)?
    /// Called when a long-press begins; caller locks AF/AE.
    var onLongPress: (() -> Void)?
    /// Called each `.changed` event with the incremental scale delta (always relative — reset after each call).
    var onPinch: ((CGFloat) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        renderer.configure(mtkView: view)
        view.isUserInteractionEnabled = true

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        view.addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(target: context.coordinator,
                                                      action: #selector(Coordinator.handleLongPress))
        longPress.minimumPressDuration = 0.6
        view.addGestureRecognizer(longPress)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                              action: #selector(Coordinator.handlePinch))
        view.addGestureRecognizer(pinch)

        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.parent = self
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        var parent: MetalViewHost

        init(_ parent: MetalViewHost) { self.parent = parent }

        @objc func handleTap(_ rec: UITapGestureRecognizer) {
            guard rec.state == .ended, let view = rec.view else { return }
            parent.onTap?(rec.location(in: view), view.bounds.size)
        }

        @objc func handleLongPress(_ rec: UILongPressGestureRecognizer) {
            guard rec.state == .began else { return }
            parent.onLongPress?()
        }

        @objc func handlePinch(_ rec: UIPinchGestureRecognizer) {
            guard rec.state == .changed else { return }
            parent.onPinch?(rec.scale)
            rec.scale = 1.0   // reset so each callback delivers a delta, not an accumulated value
        }
    }
}
