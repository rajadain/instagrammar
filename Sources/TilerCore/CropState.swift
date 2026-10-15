import CoreGraphics
import Foundation

/// Where the tile strip sits on the working source image.
///
/// All values live in **S-space**: pixel coordinates of the working source image (after EXIF
/// orientation and the user's quarter turns), origin at the top-left, y pointing down, units are
/// source pixels.
///
/// The strip is a `width × height(for:)` rectangle centred at `center` and rotated by `angle`
/// about it: strip-local `(u, v)` maps to `center + R(angle)·(u, v)` with
/// `R(θ) = [[cos θ, −sin θ], [sin θ, cos θ]]`. On screen the strip is drawn axis-aligned, so the
/// image appears rotated by `−angle`.
public struct CropState: Hashable, Codable, Sendable {
    /// Strip centre in S-space (source pixels, y-down).
    public var center: CGPoint
    /// Strip width in source pixels. Smaller means zoomed in.
    public var width: Double
    /// Strip rotation in S-space, in radians. The UI "Straighten" value is σ = −angle in degrees.
    public var angle: Double

    public init(center: CGPoint, width: Double, angle: Double = 0) {
        self.center = center
        self.width = width
        self.angle = angle
    }

    /// Strip height in source pixels: `width / spec.stripAspect`.
    public func height(for spec: TileSpec) -> Double { width / spec.stripAspect }

    /// The UI "Straighten" value in degrees (σ = −angle·180/π). Positive σ turns the image
    /// clockwise on screen.
    public var straightenDegrees: Double {
        get { CropState.straightenDegrees(forAngle: angle) }
        set { angle = CropState.angle(forStraightenDegrees: newValue) }
    }

    /// Converts a Straighten value σ (degrees) to `angle` (radians): `angle = −σ·π/180`.
    public static func angle(forStraightenDegrees sigma: Double) -> Double {
        -sigma * .pi / 180
    }

    /// Converts `angle` (radians) to a Straighten value σ (degrees): `σ = −angle·180/π`.
    public static func straightenDegrees(forAngle angle: Double) -> Double {
        // `+ 0` normalises −0.0 to 0.0 so the UI never shows "-0 °".
        -angle * 180 / .pi + 0
    }

    // CGPoint's Hashable conformance isn't guaranteed on every SDK, so hash explicitly.
    public static func == (lhs: CropState, rhs: CropState) -> Bool {
        lhs.center.x == rhs.center.x && lhs.center.y == rhs.center.y
            && lhs.width == rhs.width && lhs.angle == rhs.angle
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(Double(center.x))
        hasher.combine(Double(center.y))
        hasher.combine(width)
        hasher.combine(angle)
    }
}
