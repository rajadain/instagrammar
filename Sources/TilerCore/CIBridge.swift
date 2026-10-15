import CoreGraphics

/// The single place where y-down (S-space) transforms are converted to Core Image's y-up space.
public enum CIBridge {
    /// `(x, y) -> (x, height - y)`; its own inverse.
    public static func flip(height: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
    }

    /// Converts a y-down transform `t` (source space of height `srcHeight` to destination space
    /// of height `dstHeight`) into the equivalent Core Image transform:
    /// `flip(dstHeight) · t · flip(srcHeight)`, applied right to left on points.
    public static func toCI(_ t: CGAffineTransform, srcHeight: CGFloat, dstHeight: CGFloat) -> CGAffineTransform {
        // CGAffineTransform.concatenating applies the receiver first, then the argument.
        flip(height: srcHeight).concatenating(t).concatenating(flip(height: dstHeight))
    }
}
