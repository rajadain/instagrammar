import AppKit
import SwiftUI
import TilerCore

/// The crop canvas: wraps `CropCanvasView` (AppKit + CALayers) for SwiftUI.
///
/// Inputs: the preview (orientation applied, long edge <= 6144), the user's quarter turns, the
/// current (clamped) crop, the tile spec, and the source's oriented size (pixels, before quarter
/// turns). Output: `onCropChange`, called with a *proposed* crop that the receiver clamps (the
/// model's `update(crop:)`); the clamped value flows back in through `updateNSView`.
struct CropCanvas: NSViewRepresentable {
    var preview: CGImage
    var quarterTurns: QuarterTurns
    var crop: CropState
    var spec: TileSpec
    var orientedSize: CGSize
    var onCropChange: (CropState) -> Void = { _ in }
    /// A user interaction (drag, pinch, rotate, scroll or key burst) is starting. Optional.
    var onInteractionBegan: () -> Void = {}
    /// The interaction ended; the argument is its undo action name ("Pan", "Zoom", …). Optional.
    var onInteractionEnded: (String) -> Void = { _ in }

    func makeNSView(context: Context) -> CropCanvasView {
        CropCanvasView(frame: .zero)
    }

    func updateNSView(_ view: CropCanvasView, context: Context) {
        view.onCropChange = onCropChange
        view.onInteractionBegan = onInteractionBegan
        view.onInteractionEnded = onInteractionEnded
        // The view compares every input and only re-lays its layers when something changed.
        view.update(preview: preview, quarterTurns: quarterTurns, crop: crop, spec: spec,
                    orientedSize: orientedSize)
    }
}
