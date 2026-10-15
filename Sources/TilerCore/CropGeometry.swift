import CoreGraphics
import Foundation

/// The single source of crop geometry for the canvas and the exporter.
///
/// Conventions (see `CropState`): everything is in y-down spaces. S-space is the working source
/// image in source pixels with the origin at the top-left. The strip is centred at
/// `state.center` and rotated by `state.angle` (radians); strip-local `(u, v)` maps to
/// `center + R(angle)·(u, v)`. Tile `i` (0-based) covers strip-local
/// `u ∈ [−w/2 + i·w/N, −w/2 + (i+1)·w/N]`, `v ∈ [−h/2, h/2]`.
///
/// `CGAffineTransform` note: `a.concatenating(b)` applies `a` first, then `b`.
public enum CropGeometry {
    /// Smallest allowed tile width in source pixels; caps how far the user can zoom in.
    public static let minTileSourceWidth: Double = 100

    // MARK: - Rotation helper

    /// Rotates a vector by `angle` radians: `R(θ)·(x, y) = (x cos θ − y sin θ, x sin θ + y cos θ)`.
    /// In a y-down space a positive angle turns clockwise on screen.
    public static func rotate(_ v: CGPoint, by angle: Double) -> CGPoint {
        let c = cos(angle), s = sin(angle)
        let x = Double(v.x), y = Double(v.y)
        return CGPoint(x: x * c - y * s, y: x * s + y * c)
    }

    /// Maps a strip-local point `(u, v)` (origin at the strip centre, axes along the strip) to
    /// S-space: `center + R(angle)·(u, v)`.
    public static func stripToS(_ local: CGPoint, state: CropState) -> CGPoint {
        let r = rotate(local, by: state.angle)
        return CGPoint(x: state.center.x + r.x, y: state.center.y + r.y)
    }

    // MARK: - Size limits

    /// Largest strip width whose rotated rectangle fits inside the image when centred:
    /// `min(W / (c + s/A), H / (s + c/A))` with `c = |cos angle|`, `s = |sin angle|`.
    public static func maxWidth(spec: TileSpec, angle: Double, imageSize: CGSize) -> Double {
        let a = spec.stripAspect
        let c = abs(cos(angle)), s = abs(sin(angle))
        let w = Double(imageSize.width), h = Double(imageSize.height)
        return max(0, min(w / (c + s / a), h / (s + c / a)))
    }

    /// Smallest strip width: `min(maxWidth at 0°, N × minTileSourceWidth)`, so each tile covers
    /// at least 100 source pixels (or as much as an unrotated image allows).
    public static func minWidth(spec: TileSpec, imageSize: CGSize) -> Double {
        min(maxWidth(spec: spec, angle: 0, imageSize: imageSize),
            Double(spec.count) * minTileSourceWidth)
    }

    /// Half extents of the strip's axis-aligned bounding box in S-space:
    /// `ex = (w·c + h·s)/2`, `ey = (w·s + h·c)/2`.
    public static func halfExtents(state: CropState, spec: TileSpec) -> (ex: Double, ey: Double) {
        let w = state.width, h = state.height(for: spec)
        let c = abs(cos(state.angle)), s = abs(sin(state.angle))
        return ((w * c + h * s) / 2, (w * s + h * c) / 2)
    }

    // MARK: - Clamping and fitting

    /// Forces `state` to keep the strip fully inside the image (decision P6).
    ///
    /// The width is clamped to `[minWidth, maxWidth(angle)]` (the max wins if they cross, so
    /// rotating auto-zooms in), then the centre is clamped so the strip's bounding box lies in
    /// `[0, W] × [0, H]`. The angle is left unchanged. Idempotent.
    public static func clamp(_ state: CropState, spec: TileSpec, imageSize: CGSize) -> CropState {
        var out = state
        let lo = minWidth(spec: spec, imageSize: imageSize)
        let hi = maxWidth(spec: spec, angle: state.angle, imageSize: imageSize)
        out.width = min(max(state.width, lo), hi)
        let (ex, ey) = halfExtents(state: out, spec: spec)
        out.center = CGPoint(
            x: clampValue(Double(state.center.x), ex, Double(imageSize.width) - ex),
            y: clampValue(Double(state.center.y), ey, Double(imageSize.height) - ey))
        return out
    }

    /// The initial / "Reset" state: centred on the image at the largest width that fits at `angle`.
    public static func fit(spec: TileSpec, imageSize: CGSize, angle: Double = 0) -> CropState {
        let state = CropState(
            center: CGPoint(x: imageSize.width / 2, y: imageSize.height / 2),
            width: maxWidth(spec: spec, angle: angle, imageSize: imageSize),
            angle: angle)
        return clamp(state, spec: spec, imageSize: imageSize)
    }

    /// Adapts `state` to a new tile spec (count or aspect change). Keeps `center`, `angle` and the
    /// strip height, sets `width = h_old · A_new`, then clamps (zooming in if it no longer fits).
    public static func respec(_ state: CropState, from old: TileSpec, to new: TileSpec,
                              imageSize: CGSize) -> CropState {
        var out = state
        out.width = state.height(for: old) * new.stripAspect
        return clamp(out, spec: new, imageSize: imageSize)
    }

    // MARK: - Corners and sizes

    /// The strip's four S-space corners, in the order top-left, top-right, bottom-right,
    /// bottom-left of the strip's own (unrotated, y-down) frame.
    public static func stripCorners(state: CropState, spec: TileSpec) -> [CGPoint] {
        let hw = state.width / 2, hh = state.height(for: spec) / 2
        return [CGPoint(x: -hw, y: -hh), CGPoint(x: hw, y: -hh),
                CGPoint(x: hw, y: hh), CGPoint(x: -hw, y: hh)]
            .map { stripToS($0, state: state) }
    }

    /// Tile `index`'s four S-space corners, ordered top-left, top-right, bottom-right,
    /// bottom-left in the tile's own (y-down) frame.
    public static func tileCorners(state: CropState, spec: TileSpec, index: Int) -> [CGPoint] {
        let tw = state.width / Double(spec.count)
        let u0 = -state.width / 2 + Double(index) * tw, u1 = u0 + tw
        let hh = state.height(for: spec) / 2
        return [CGPoint(x: u0, y: -hh), CGPoint(x: u1, y: -hh),
                CGPoint(x: u1, y: hh), CGPoint(x: u0, y: hh)]
            .map { stripToS($0, state: state) }
    }

    /// Tile `index`'s centre in S-space: `center + R(angle)·(−w/2 + (i + 0.5)·w/N, 0)`.
    public static func tileCenter(state: CropState, spec: TileSpec, index: Int) -> CGPoint {
        let u = -state.width / 2 + (Double(index) + 0.5) * state.width / Double(spec.count)
        return stripToS(CGPoint(x: u, y: 0), state: state)
    }

    /// Exact (fractional) size of one tile in source pixels: `(w/N, h)`.
    public static func tileSourceSize(state: CropState, spec: TileSpec) -> CGSize {
        CGSize(width: state.width / Double(spec.count), height: state.height(for: spec))
    }

    /// The "Maximum" export size: `tw = floor(w/N)`, `th = floor(tw / a)`. A 1e-6 tolerance
    /// absorbs floating-point noise so e.g. 1599.9999999 counts as 1600.
    public static func nativeTilePixelSize(state: CropState, spec: TileSpec) -> (width: Int, height: Int) {
        let eps = 1e-6
        let tw = max(0, Int(floor(state.width / Double(spec.count) + eps)))
        let th = max(0, Int(floor(Double(tw) * spec.aspect.height / spec.aspect.width + eps)))
        return (tw, th)
    }

    // MARK: - Transforms

    /// Result of `sToView`.
    public struct ViewMapping: Equatable, Sendable {
        /// Maps S-space to view points (y-down). The strip appears centred and axis-aligned.
        public var transform: CGAffineTransform
        /// View points per source pixel.
        public var viewScale: Double
        /// The strip's rectangle in view points.
        public var stripRect: CGRect
    }

    /// Maps S-space to canvas points (y-down) so the strip is centred, axis-aligned and fills
    /// the view minus `padding` on every side.
    ///
    /// `viewScale = min((Vw − 2p)/w, (Vh − 2p)/h)` and
    /// `T = translate(Vw/2, Vh/2) · scale(viewScale) · rotate(−angle) · translate(−center)`
    /// (rightmost applied first).
    public static func sToView(state: CropState, spec: TileSpec, viewSize: CGSize,
                               padding: Double) -> ViewMapping {
        let w = state.width, h = state.height(for: spec)
        let vw = Double(viewSize.width), vh = Double(viewSize.height)
        let scale = max(0, min((vw - 2 * padding) / w, (vh - 2 * padding) / h))
        let t = centeredTransform(on: state.center, angle: state.angle,
                                  scaleX: scale, scaleY: scale,
                                  to: CGPoint(x: vw / 2, y: vh / 2))
        let rect = CGRect(x: vw / 2 - w * scale / 2, y: vh / 2 - h * scale / 2,
                          width: w * scale, height: h * scale)
        return ViewMapping(transform: t, viewScale: scale, stripRect: rect)
    }

    /// Maps S-space to the output pixel space of tile `index` (y-down, origin at the tile's
    /// top-left) at `k` output pixels per source pixel:
    /// `translate(outW/2, outH/2) · scale(k) · rotate(−angle) · translate(−tileCenter)`,
    /// with `outW = k·w/N`, `outH = k·h` (generally fractional).
    public static func sToTile(state: CropState, spec: TileSpec, index: Int, scale k: Double) -> CGAffineTransform {
        let size = tileSourceSize(state: state, spec: spec)
        return centeredTransform(on: tileCenter(state: state, spec: spec, index: index),
                                 angle: state.angle, scaleX: k, scaleY: k,
                                 to: CGPoint(x: Double(size.width) * k / 2, y: Double(size.height) * k / 2))
    }

    /// Maps S-space to the pixel space of tile `index` rendered at an exact integer
    /// `outputSize` (y-down, origin at the tile's top-left). The tile's corners land exactly on
    /// `(0,0)…(outW,outH)`, using per-axis scales `outW/(w/N)` and `outH/h`.
    ///
    /// Prefer this for export: with `outputSize = nativeTilePixelSize` the floor rounding is
    /// absorbed as a sub-pixel stretch instead of cropping up to a pixel off each tile's right
    /// and bottom edges, so seams between adjacent tiles stay exact.
    public static func sToTile(state: CropState, spec: TileSpec, index: Int,
                               outputSize: CGSize) -> CGAffineTransform {
        let size = tileSourceSize(state: state, spec: spec)
        let ow = Double(outputSize.width), oh = Double(outputSize.height)
        return centeredTransform(on: tileCenter(state: state, spec: spec, index: index),
                                 angle: state.angle,
                                 scaleX: ow / Double(size.width), scaleY: oh / Double(size.height),
                                 to: CGPoint(x: ow / 2, y: oh / 2))
    }

    /// `translate(target) · scale(sx, sy) · rotate(−angle) · translate(−pivot)`.
    private static func centeredTransform(on pivot: CGPoint, angle: Double,
                                          scaleX: Double, scaleY: Double,
                                          to target: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: -pivot.x, y: -pivot.y)
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(-angle)))
            .concatenating(CGAffineTransform(scaleX: CGFloat(scaleX), y: CGFloat(scaleY)))
            .concatenating(CGAffineTransform(translationX: target.x, y: target.y))
    }

    // MARK: - Interaction helpers (callers clamp afterwards)

    /// Pans so the image follows the cursor: `center −= R(angle)·(Δ / viewScale)`, where `Δ` is
    /// the drag in view points (y-down). Does not clamp.
    public static func panned(_ state: CropState, byViewDelta delta: CGVector, viewScale: Double) -> CropState {
        guard viewScale > 0 else { return state }
        let d = rotate(CGPoint(x: Double(delta.dx) / viewScale, y: Double(delta.dy) / viewScale),
                       by: state.angle)
        var out = state
        out.center = CGPoint(x: state.center.x - d.x, y: state.center.y - d.y)
        return out
    }

    /// Zooms by `factor` (> 1 zooms in) keeping `anchor` (S-space) fixed on screen:
    /// `w' = w / factor`, `center' = anchor + (center − anchor)·(w'/w)`. Does not clamp.
    public static func zoomed(_ state: CropState, factor: Double, anchorInS anchor: CGPoint) -> CropState {
        guard factor > 0, factor.isFinite else { return state }
        var out = state
        out.width = state.width / factor
        let r = 1 / factor
        out.center = CGPoint(x: Double(anchor.x) + Double(state.center.x - anchor.x) * r,
                             y: Double(anchor.y) + Double(state.center.y - anchor.y) * r)
        return out
    }

    /// Rotates the strip about its centre to `angle` (radians). Does not clamp.
    public static func rotated(_ state: CropState, toAngle angle: Double) -> CropState {
        var out = state
        out.angle = angle
        return out
    }

    /// Clamps `x` to `[lo, hi]`; if the interval is empty (floating-point noise), returns its midpoint.
    private static func clampValue(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        lo > hi ? (lo + hi) / 2 : min(max(x, lo), hi)
    }
}
