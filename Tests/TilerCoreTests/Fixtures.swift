import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Synthetic test images, written at test time. No binary fixtures are committed.
///
/// All `width`/`height` parameters describe the *displayed* (EXIF-oriented) image. For
/// orientations 5...8 the stored pixel grid is therefore `height x width`.
enum Fixtures {
    enum FixtureColorSpace {
        case sRGB, displayP3

        var cgColorSpace: CGColorSpace {
            switch self {
            case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB)!
            case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)!
            }
        }
    }

    struct RGBA: Equatable {
        var r: UInt8, g: UInt8, b: UInt8, a: UInt8
    }

    static let red = RGBA(r: 255, g: 0, b: 0, a: 255)
    static let green = RGBA(r: 0, g: 255, b: 0, a: 255)
    static let blue = RGBA(r: 0, g: 0, b: 255, a: 255)
    static let white = RGBA(r: 255, g: 255, b: 255, a: 255)

    // MARK: Files

    /// A fresh, unique temp directory (caller may delete it; the OS will otherwise).
    static func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("instagrammar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes the quadrant fixture as a JPEG and returns its URL.
    ///
    /// - Parameters:
    ///   - width, height: size of the displayed image (after `orientation` is applied).
    ///   - orientation: EXIF orientation to store (1, 3, 6 or 8). Pixels are stored pre-rotated so
    ///     that the displayed image is the quadrant pattern.
    ///   - colorSpace: colour space of the pixel data (and embedded profile).
    ///   - includeGPS: adds a `{GPS}` dictionary.
    ///   - includeExif: adds `{Exif}` `LensModel` ("Test Lens 35mm") and `DateTimeOriginal`
    ///     ("2024:05:17 13:45:00"), plus `{TIFF}` Make/Model.
    ///   - grid: draws a 1-px black line every 100 px (x and y).
    static func writeJPEG(
        width: Int,
        height: Int,
        orientation: Int = 1,
        colorSpace: FixtureColorSpace = .sRGB,
        includeGPS: Bool = false,
        includeExif: Bool = true,
        grid: Bool = false,
        quality: Double = 1.0,
        name: String = "fixture",
        in directory: URL? = nil
    ) throws -> URL {
        let dir = try directory ?? makeTempDirectory()
        let url = dir.appendingPathComponent("\(name).jpg")
        let displayed = quadrants(width: width, height: height, grid: grid, colorSpace: colorSpace)
        let stored = storedImage(displayed: displayed, orientation: orientation)

        var props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: orientation,
        ]
        if includeExif {
            props[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifLensModel: "Test Lens 35mm",
                kCGImagePropertyExifDateTimeOriginal: "2024:05:17 13:45:00",
            ]
            props[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFMake: "TestMake",
                kCGImagePropertyTIFFModel: "TestModel",
                kCGImagePropertyTIFFOrientation: orientation,
            ]
        }
        if includeGPS {
            props[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 40.6892,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 74.0445,
                kCGImagePropertyGPSLongitudeRef: "W",
            ]
        }
        try write(stored, as: .jpeg, properties: props, to: url)
        return url
    }

    /// Writes a PNG of the given image (use for alpha fixtures).
    static func writePNG(image: CGImage, name: String = "fixture", in directory: URL? = nil) throws -> URL {
        let dir = try directory ?? makeTempDirectory()
        let url = dir.appendingPathComponent("\(name).png")
        try write(image, as: .png, properties: [:], to: url)
        return url
    }

    /// Writes a file that is not an image.
    static func writeGarbage(name: String = "garbage.jpg", in directory: URL? = nil) throws -> URL {
        let dir = try directory ?? makeTempDirectory()
        let url = dir.appendingPathComponent(name)
        try Data("this is definitely not an image".utf8).write(to: url)
        return url
    }

    static func write(_ image: CGImage, as type: UTType, properties: [CFString: Any], to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw FixtureError.cannotCreateDestination
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw FixtureError.cannotFinalize }
    }

    enum FixtureError: Error { case cannotCreateDestination, cannotFinalize, cannotCreateContext, cannotRead }

    // MARK: Images

    /// TL red, TR green, BL blue, BR white (quadrants split at width/2, height/2).
    /// With `grid`, a 1-px black line is drawn at every x and y that is a multiple of 100.
    static func quadrants(
        width: Int, height: Int, grid: Bool = false, colorSpace: FixtureColorSpace = .sRGB
    ) -> CGImage {
        let ctx = makeContext(width: width, height: height, colorSpace: colorSpace.cgColorSpace)
        let hw = width / 2, hh = height / 2
        func fill(_ c: RGBA, x: Int, y: Int, w: Int, h: Int) {   // y-down rect
            ctx.setFillColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
                             blue: CGFloat(c.b) / 255, alpha: 1)
            ctx.fill(CGRect(x: x, y: height - y - h, width: w, height: h))
        }
        fill(red, x: 0, y: 0, w: hw, h: hh)
        fill(green, x: hw, y: 0, w: width - hw, h: hh)
        fill(blue, x: 0, y: hh, w: hw, h: height - hh)
        fill(white, x: hw, y: hh, w: width - hw, h: height - hh)
        if grid {
            let black = RGBA(r: 0, g: 0, b: 0, a: 255)
            for x in stride(from: 0, to: width, by: 100) { fill(black, x: x, y: 0, w: 1, h: height) }
            for y in stride(from: 0, to: height, by: 100) { fill(black, x: 0, y: y, w: width, h: 1) }
        }
        return ctx.makeImage()!
    }

    /// The pixel grid that, when displayed with the given EXIF orientation, shows `displayed`.
    /// Supports 1 (identity), 3 (180°), 6 (stored = displayed turned 90° counter-clockwise, so a
    /// viewer must turn it 90° clockwise) and 8 (stored = displayed turned 90° clockwise).
    static func storedImage(displayed: CGImage, orientation: Int) -> CGImage {
        let dw = displayed.width, dh = displayed.height
        let rect = CGRect(x: 0, y: 0, width: dw, height: dh)
        switch orientation {
        case 1:
            return displayed
        case 3:
            let ctx = makeContext(width: dw, height: dh, colorSpace: displayed.colorSpace!)
            ctx.translateBy(x: CGFloat(dw), y: CGFloat(dh))
            ctx.rotate(by: .pi)
            ctx.draw(displayed, in: rect)
            return ctx.makeImage()!
        case 6:
            // CGContext is y-up, so +90° is counter-clockwise.
            let ctx = makeContext(width: dh, height: dw, colorSpace: displayed.colorSpace!)
            ctx.translateBy(x: CGFloat(dh), y: 0)
            ctx.rotate(by: .pi / 2)
            ctx.draw(displayed, in: rect)
            return ctx.makeImage()!
        case 8:
            let ctx = makeContext(width: dh, height: dw, colorSpace: displayed.colorSpace!)
            ctx.translateBy(x: 0, y: CGFloat(dw))
            ctx.rotate(by: -.pi / 2)
            ctx.draw(displayed, in: rect)
            return ctx.makeImage()!
        default:
            fatalError("Fixtures: unsupported orientation \(orientation)")
        }
    }

    private static func makeContext(width: Int, height: Int, colorSpace: CGColorSpace) -> CGContext {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    // MARK: Reading pixels back (tests only)

    /// The RGBA8 value at (x, y) in y-down image coordinates (origin top-left), converted to
    /// sRGB and un-premultiplied. No interpolation is applied.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> RGBA {
        precondition(x >= 0 && y >= 0 && x < image.width && y < image.height, "pixel out of bounds")
        var buf = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(
                data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .none
            // Place image so that pixel (x, y) (y-down) lands on the 1x1 context.
            ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        let a = buf[3]
        if a == 0 || a == 255 { return RGBA(r: buf[0], g: buf[1], b: buf[2], a: a) }
        func un(_ v: UInt8) -> UInt8 { UInt8(min(255, (Int(v) * 255 + Int(a) / 2) / Int(a))) }
        return RGBA(r: un(buf[0]), g: un(buf[1]), b: un(buf[2]), a: a)
    }

    /// All pixels of `image` as RGBA8 bytes (sRGB, premultiplied), rows top to bottom.
    static func rgbaBytes(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buf
    }

    /// Mean absolute RGB difference (0…1) between `a` and the `a`-sized window of `b` whose
    /// top-left is at (`bx`, `by`) (y-down).
    static func meanAbsDiff(_ a: CGImage, _ b: CGImage, bx: Int = 0, by: Int = 0) -> Double {
        precondition(bx + a.width <= b.width && by + a.height <= b.height, "window out of bounds")
        let pa = rgbaBytes(a), pb = rgbaBytes(b)
        var sum = 0
        for y in 0..<a.height {
            for x in 0..<a.width {
                let ia = (y * a.width + x) * 4, ib = ((y + by) * b.width + (x + bx)) * 4
                for c in 0..<3 { sum += abs(Int(pa[ia + c]) - Int(pb[ib + c])) }
            }
        }
        return Double(sum) / Double(a.width * a.height * 3) / 255
    }

    /// A solid, opaque image of one colour.
    static func solid(width: Int, height: Int, color: RGBA = white) -> CGImage {
        let ctx = makeContext(width: width, height: height, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        ctx.setFillColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
                         blue: CGFloat(color.b) / 255, alpha: CGFloat(color.a) / 255)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// Left half fully transparent, right half opaque red (for alpha-flattening tests).
    static func halfTransparent(width: Int, height: Int) -> CGImage {
        let ctx = makeContext(width: width, height: height, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return ctx.makeImage()!
    }

    /// Writes any image as a JPEG with the given properties (e.g. a `solid` fixture).
    static func writeJPEG(image: CGImage, properties: [CFString: Any] = [:],
                          name: String = "fixture", in directory: URL? = nil) throws -> URL {
        let dir = try directory ?? makeTempDirectory()
        let url = dir.appendingPathComponent("\(name).jpg")
        try write(image, as: .jpeg, properties: properties, to: url)
        return url
    }

    /// Reads the first image and its properties from a file.
    static func read(_ url: URL) throws -> (image: CGImage, properties: [CFString: Any]) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { throw FixtureError.cannotRead }
        return (image, props)
    }

    /// True when each channel of `p` is within `tolerance` of `expected` (alpha ignored).
    static func isClose(_ p: RGBA, to expected: RGBA, tolerance: Int = 24) -> Bool {
        abs(Int(p.r) - Int(expected.r)) <= tolerance
            && abs(Int(p.g) - Int(expected.g)) <= tolerance
            && abs(Int(p.b) - Int(expected.b)) <= tolerance
    }
}
