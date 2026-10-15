import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

extension CropGeometry {
    /// Maps pixels of the downsampled, orientation-applied preview (y-down, origin top-left) to
    /// pixels of tile `index` rendered at an integer `outputSize` (y-down). It composes, in order:
    /// preview → oriented-image pixels (`orientedSize / previewSize` per axis), the user's quarter
    /// turns (T20) and `sToTile(…, outputSize:)`. Used by the carousel preview, which renders from
    /// the preview image instead of decoding the full-resolution file.
    public static func previewToTile(state: CropState, spec: TileSpec, index: Int,
                                     quarterTurns: QuarterTurns, orientedSize: CGSize,
                                     previewSize: CGSize, outputSize: CGSize) -> CGAffineTransform {
        guard previewSize.width > 0, previewSize.height > 0 else { return .identity }
        return previewToS(previewSize: previewSize, orientedSize: orientedSize, quarterTurns: quarterTurns)
            .concatenating(sToTile(state: state, spec: spec, index: index, outputSize: outputSize))
    }
}

/// Renders small carousel preview tiles from the preview image with Core Image. Owns one
/// `CIContext`; share an instance and call `render` from any thread.
public final class PreviewTileRenderer: @unchecked Sendable {
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .cacheIntermediates: false,
    ])
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    public init() {}

    /// Pixel size of a tile `pixelWidth` wide for `aspect` (height rounded, at least 1).
    public static func tilePixelSize(pixelWidth: Int, aspect: AspectRatio) -> CGSize {
        let w = max(1, pixelWidth)
        let h = max(1, Int((Double(w) * aspect.height / aspect.width).rounded()))
        return CGSize(width: w, height: h)
    }

    /// Renders tile `index` as an sRGB image of exactly `outputSize` pixels. Returns nil if Core
    /// Image fails.
    public func render(preview: CGImage, quarterTurns: QuarterTurns, orientedSize: CGSize,
                       state: CropState, spec: TileSpec, index: Int,
                       outputSize: CGSize) -> CGImage? {
        let ow = Int(outputSize.width), oh = Int(outputSize.height)
        guard ow > 0, oh > 0 else { return nil }
        let previewSize = CGSize(width: preview.width, height: preview.height)

        var base = CIImage(cgImage: preview)
        // Flatten alpha over white (P14), as the exporter does.
        base = base.composited(over: CIImage(color: .white).cropped(to: base.extent))

        // Pre-shrink with Lanczos when the tile is much smaller than its source area, so the
        // final (bilinear) affine step never samples at less than ~0.5 output px per input px.
        let tileWidthInPreview = state.width / Double(spec.count)
            * Double(previewSize.width / max(orientedSize.width, 1))
        let k = Double(ow) / max(tileWidthInPreview, 1)
        var source = base
        var sourceSize = previewSize
        if k < 0.5 {
            let f = min(1, 2 * k)
            let lanczos = CIFilter.lanczosScaleTransform()
            lanczos.inputImage = base
            lanczos.scale = Float(f)
            lanczos.aspectRatio = 1
            if let scaled = lanczos.outputImage {
                let e = scaled.extent
                source = scaled.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                sourceSize = e.size
            }
        }

        let t = CropGeometry.previewToTile(
            state: state, spec: spec, index: index, quarterTurns: quarterTurns,
            orientedSize: orientedSize, previewSize: sourceSize, outputSize: outputSize)
        let ci = CIBridge.toCI(t, srcHeight: sourceSize.height, dstHeight: outputSize.height)
        let rect = CGRect(x: 0, y: 0, width: ow, height: oh)
        return context.createCGImage(source.clampedToExtent().transformed(by: ci).cropped(to: rect),
                                     from: rect, format: .RGBA8, colorSpace: sRGB)
    }
}
