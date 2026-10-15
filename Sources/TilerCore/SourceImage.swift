import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Errors thrown while opening or decoding a source image.
public enum SourceImageError: Error, LocalizedError, Equatable {
    case unreadable(URL)
    case previewFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return "Couldn't read \"\(url.lastPathComponent)\" as an image."
        case .previewFailed(let url):
            return "Couldn't decode a preview of \"\(url.lastPathComponent)\"."
        }
    }
}

/// User-applied 90° turns, clockwise.
public enum QuarterTurns: Int, Codable, Sendable, CaseIterable {
    case r0, r90, r180, r270

    /// One more clockwise quarter turn.
    public var rotatedRight: QuarterTurns { QuarterTurns(rawValue: (rawValue + 1) % 4)! }
    /// One more counter-clockwise quarter turn.
    public var rotatedLeft: QuarterTurns { QuarterTurns(rawValue: (rawValue + 3) % 4)! }
}

/// Size of the working S-space image: the oriented size with width/height swapped for 90°/270°.
public func workingSize(_ oriented: CGSize, _ q: QuarterTurns) -> CGSize {
    switch q {
    case .r0, .r180: return oriented
    case .r90, .r270: return CGSize(width: oriented.height, height: oriented.width)
    }
}

/// y-down transform mapping oriented-image pixel coordinates to working S-space (the oriented
/// image turned clockwise by `q`). The turned image's top-left is at (0, 0).
public func quarterTurnTransform(_ q: QuarterTurns, orientedSize: CGSize) -> CGAffineTransform {
    let w = orientedSize.width, h = orientedSize.height
    switch q {
    case .r0:
        return .identity
    case .r90:   // (x, y) -> (h - y, x)
        return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
    case .r180:  // (x, y) -> (w - x, h - y)
        return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
    case .r270:  // (x, y) -> (y, w - x)
        return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
    }
}

/// An image file opened with ImageIO. Loading reads the header and metadata only; pixels are
/// decoded by `makePreview` or lazily by Core Image.
public final class SourceImage: @unchecked Sendable {
    public let url: URL
    /// File name without extension.
    public let stem: String
    /// Pixel size after EXIF orientation, before the user's quarter turns.
    public let orientedSize: CGSize
    /// `CGImageSourceCopyPropertiesAtIndex(…, 0, nil)`.
    public let properties: [CFString: Any]

    private init(url: URL, orientedSize: CGSize, properties: [CFString: Any]) {
        self.url = url
        self.stem = url.deletingPathExtension().lastPathComponent
        self.orientedSize = orientedSize
        self.properties = properties
    }

    /// UTIs that ImageIO can read.
    public static var readableTypeIdentifiers: [String] {
        (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
    }

    /// Cheap: reads header and metadata only, no pixel decode.
    public static func load(url: URL) throws -> SourceImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pw = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let ph = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              pw > 0, ph > 0
        else { throw SourceImageError.unreadable(url) }

        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let size = (5...8).contains(orientation)
            ? CGSize(width: ph, height: pw)
            : CGSize(width: pw, height: ph)
        return SourceImage(url: url, orientedSize: size, properties: props)
    }

    /// Decodes a downsampled, orientation-applied preview. Blocking; call off the main thread.
    public func makePreview(maxPixelSize: Int = 6144) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw SourceImageError.unreadable(url)
        }
        let longEdge = Int(max(orientedSize.width, orientedSize.height).rounded())
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(maxPixelSize, longEdge)),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw SourceImageError.previewFailed(url)
        }
        return image
    }

    /// Lazy full-resolution image (EXIF orientation applied, origin at (0, 0)); decoded by Core
    /// Image at render time. For RAW files this is Apple's default RAW render.
    public func fullResolutionCIImage() -> CIImage {
        CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
            ?? CIImage.empty()
    }
}
