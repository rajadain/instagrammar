import SwiftUI
import TilerCore

/// PLACEHOLDER canvas (Phase 4): draws the preview with the strip and tile dividers over it,
/// no gestures. Phase 5 replaces the body with an `NSViewRepresentable` wrapping
/// `CropCanvasView`; keep this initialiser signature so `ContentView` doesn't change.
///
/// Inputs: the preview (orientation applied, long edge <= 6144), the user's quarter turns, the
/// current (clamped) crop, the tile spec, and the source's oriented size (pixels, before quarter
/// turns). Output: `onCropChange`, called with a proposed crop that the receiver clamps
/// (the model's `update(crop:)`).
struct CropCanvas: View {
    var preview: CGImage
    var quarterTurns: QuarterTurns
    var crop: CropState
    var spec: TileSpec
    var orientedSize: CGSize
    var onCropChange: (CropState) -> Void = { _ in }

    private let padding: Double = 28

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0, crop.width > 0 else { return }
            let mapping = CropGeometry.sToView(state: crop, spec: spec, viewSize: size, padding: padding)

            // preview pixels -> oriented pixels -> working (S) space -> view.
            let p = CGAffineTransform(scaleX: orientedSize.width / CGFloat(preview.width),
                                      y: orientedSize.height / CGFloat(preview.height))
            let m = p.concatenating(quarterTurnTransform(quarterTurns, orientedSize: orientedSize))
                .concatenating(mapping.transform)
            var imageContext = context
            imageContext.transform = m
            imageContext.draw(Image(decorative: preview, scale: 1),
                              in: CGRect(x: 0, y: 0, width: preview.width, height: preview.height))

            // Dim everything outside the strip.
            var dim = Path(CGRect(origin: .zero, size: size))
            dim.addRect(mapping.stripRect)
            context.fill(dim, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))

            // Strip border and tile dividers.
            context.stroke(Path(mapping.stripRect), with: .color(.white), lineWidth: 1)
            var dividers = Path()
            let r = mapping.stripRect
            for i in 1..<max(spec.count, 1) {
                let x = r.minX + r.width * CGFloat(i) / CGFloat(spec.count)
                dividers.move(to: CGPoint(x: x, y: r.minY))
                dividers.addLine(to: CGPoint(x: x, y: r.maxY))
            }
            context.stroke(dividers, with: .color(.white.opacity(0.8)), lineWidth: 1)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .clipped()
    }
}
