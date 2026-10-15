import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import TilerCore

private func expectColor(_ p: Fixtures.RGBA, _ expected: Fixtures.RGBA, _ label: String,
                         sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(Fixtures.isClose(p, to: expected), "\(label): got \(p), expected \(expected)", sourceLocation: sourceLocation)
}

private func apply(_ t: CGAffineTransform, _ x: Double, _ y: Double) -> CGPoint {
    CGPoint(x: x, y: y).applying(t)
}

private func expectPoint(_ p: CGPoint, _ x: Double, _ y: Double,
                         sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(abs(p.x - x) < 1e-9 && abs(p.y - y) < 1e-9, "got \(p), expected (\(x), \(y))", sourceLocation: sourceLocation)
}

// MARK: - Loading

@Suite struct SourceImageLoadTests {
    @Test func loadReadsSizeStemAndProperties() throws {
        let url = try Fixtures.writeJPEG(width: 400, height: 300, includeGPS: true, name: "my-photo 1")
        let src = try SourceImage.load(url: url)
        #expect(src.stem == "my-photo 1")
        #expect(src.url == url)
        #expect(src.orientedSize == CGSize(width: 400, height: 300))
        #expect((src.properties[kCGImagePropertyPixelWidth] as? Int) == 400)
        let exif = src.properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect((exif?[kCGImagePropertyExifLensModel] as? String) == "Test Lens 35mm")
        #expect((exif?[kCGImagePropertyExifDateTimeOriginal] as? String) == "2024:05:17 13:45:00")
        #expect(src.properties[kCGImagePropertyGPSDictionary] != nil)
    }

    @Test(arguments: [(6, true), (8, true), (3, false), (1, false)])
    func orientedSizeSwapsForQuarterTurnOrientations(orientation: Int, swaps: Bool) throws {
        // Displayed 400x300; stored pixels are 300x400 for orientations 6 and 8.
        let url = try Fixtures.writeJPEG(width: 400, height: 300, orientation: orientation)
        let src = try SourceImage.load(url: url)
        let stored = (src.properties[kCGImagePropertyPixelWidth] as? Int, src.properties[kCGImagePropertyPixelHeight] as? Int)
        #expect(stored == (swaps ? 300 : 400, swaps ? 400 : 300))
        #expect((src.properties[kCGImagePropertyOrientation] as? Int) == orientation)
        #expect(src.orientedSize == CGSize(width: 400, height: 300))
    }

    @Test func unreadableFileThrows() throws {
        let url = try Fixtures.writeGarbage()
        #expect(throws: SourceImageError.self) { try SourceImage.load(url: url) }
        let missing = url.deletingLastPathComponent().appendingPathComponent("nope.jpg")
        #expect(throws: SourceImageError.self) { try SourceImage.load(url: missing) }
        #expect(SourceImageError.unreadable(url).errorDescription?.contains("garbage.jpg") == true)
    }

    @Test func readableTypesIncludeCommonFormats() {
        let types = SourceImage.readableTypeIdentifiers
        for id in ["public.jpeg", "public.png", "public.heic", "public.tiff"] {
            #expect(types.contains(id), "missing \(id)")
        }
    }
}

// MARK: - Preview

@Suite struct SourceImagePreviewTests {
    @Test func previewOfPlainQuadrants() throws {
        let src = try SourceImage.load(url: try Fixtures.writeJPEG(width: 400, height: 300))
        let img = try src.makePreview()
        #expect(img.width == 400 && img.height == 300)
        expectColor(Fixtures.pixel(img, x: 10, y: 10), Fixtures.red, "TL")
        expectColor(Fixtures.pixel(img, x: 390, y: 10), Fixtures.green, "TR")
        expectColor(Fixtures.pixel(img, x: 10, y: 290), Fixtures.blue, "BL")
        expectColor(Fixtures.pixel(img, x: 390, y: 290), Fixtures.white, "BR")
    }

    @Test(arguments: [3, 6, 8])
    func previewAppliesOrientation(orientation: Int) throws {
        let src = try SourceImage.load(url: try Fixtures.writeJPEG(width: 400, height: 300, orientation: orientation))
        let img = try src.makePreview(maxPixelSize: 6144)
        // Correct oriented aspect, and the displayed image is the quadrant pattern.
        #expect(img.width == 400 && img.height == 300)
        expectColor(Fixtures.pixel(img, x: 10, y: 10), Fixtures.red, "TL")
        expectColor(Fixtures.pixel(img, x: 390, y: 10), Fixtures.green, "TR")
        expectColor(Fixtures.pixel(img, x: 10, y: 290), Fixtures.blue, "BL")
        expectColor(Fixtures.pixel(img, x: 390, y: 290), Fixtures.white, "BR")
    }

    @Test func previewDownsamplesToMaxPixelSizeKeepingAspect() throws {
        let src = try SourceImage.load(url: try Fixtures.writeJPEG(width: 1200, height: 800, orientation: 6))
        let img = try src.makePreview(maxPixelSize: 300)
        #expect(max(img.width, img.height) == 300)
        #expect(abs(Double(img.width) / Double(img.height) - 1.5) < 0.01)
        expectColor(Fixtures.pixel(img, x: 5, y: 5), Fixtures.red, "TL")
    }

    @Test func previewNeverUpscales() throws {
        let src = try SourceImage.load(url: try Fixtures.writeJPEG(width: 200, height: 100))
        let img = try src.makePreview(maxPixelSize: 6144)
        #expect(img.width == 200 && img.height == 100)
    }

    @Test func displayP3SourceKeepsColour() throws {
        let src = try SourceImage.load(url: try Fixtures.writeJPEG(width: 200, height: 100, colorSpace: .displayP3))
        let img = try src.makePreview()
        // Saturated P3 primaries clip in sRGB, so only the dominant channel is checked.
        let tl = Fixtures.pixel(img, x: 5, y: 5)
        #expect(tl.r > 200 && tl.g < 60 && tl.b < 60)
    }

    @Test func fullResolutionCIImageIsOrientedWithOriginAtZero() throws {
        let src = try SourceImage.load(url: try Fixtures.writeJPEG(width: 400, height: 300, orientation: 6))
        let ci = src.fullResolutionCIImage()
        #expect(ci.extent == CGRect(x: 0, y: 0, width: 400, height: 300))
        let cg = try #require(CIContext().createCGImage(
            ci, from: ci.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
        expectColor(Fixtures.pixel(cg, x: 10, y: 10), Fixtures.red, "TL")
        expectColor(Fixtures.pixel(cg, x: 390, y: 290), Fixtures.white, "BR")
    }
}

// MARK: - Quarter turns

@Suite struct QuarterTurnTests {
    let size = CGSize(width: 400, height: 300)

    @Test func workingSizeSwapsForOddTurns() {
        #expect(workingSize(size, .r0) == size)
        #expect(workingSize(size, .r90) == CGSize(width: 300, height: 400))
        #expect(workingSize(size, .r180) == size)
        #expect(workingSize(size, .r270) == CGSize(width: 300, height: 400))
    }

    @Test func rotationHelpers() {
        #expect(QuarterTurns.r0.rotatedRight == .r90)
        #expect(QuarterTurns.r270.rotatedRight == .r0)
        #expect(QuarterTurns.r0.rotatedLeft == .r270)
        #expect(QuarterTurns.r90.rotatedLeft == .r0)
        for q in QuarterTurns.allCases {
            #expect(q.rotatedRight.rotatedLeft == q)
            #expect(q.rotatedLeft.rotatedRight == q)
        }
    }

    @Test func cornersMapClockwise() {
        let w = 400.0, h = 300.0
        // r0: identity.
        let t0 = quarterTurnTransform(.r0, orientedSize: size)
        expectPoint(apply(t0, 0, 0), 0, 0)
        expectPoint(apply(t0, w, h), w, h)
        // r90 clockwise: TL -> TR, TR -> BR, BR -> BL, BL -> TL, in a (h x w) frame.
        let t90 = quarterTurnTransform(.r90, orientedSize: size)
        expectPoint(apply(t90, 0, 0), h, 0)
        expectPoint(apply(t90, w, 0), h, w)
        expectPoint(apply(t90, w, h), 0, w)
        expectPoint(apply(t90, 0, h), 0, 0)
        // r180.
        let t180 = quarterTurnTransform(.r180, orientedSize: size)
        expectPoint(apply(t180, 0, 0), w, h)
        expectPoint(apply(t180, w, h), 0, 0)
        expectPoint(apply(t180, w, 0), 0, h)
        // r270 clockwise (= 90° counter-clockwise): TL -> BL, TR -> TL, BR -> TR, BL -> BR.
        let t270 = quarterTurnTransform(.r270, orientedSize: size)
        expectPoint(apply(t270, 0, 0), 0, w)
        expectPoint(apply(t270, w, 0), 0, 0)
        expectPoint(apply(t270, w, h), h, 0)
        expectPoint(apply(t270, 0, h), h, w)
    }

    @Test func transformedBoundsMatchWorkingSizeAtOrigin() {
        for q in QuarterTurns.allCases {
            let t = quarterTurnTransform(q, orientedSize: size)
            let r = CGRect(origin: .zero, size: size).applying(t)
            let ws = workingSize(size, q)
            #expect(abs(r.minX) < 1e-9 && abs(r.minY) < 1e-9, "\(q) origin \(r.origin)")
            #expect(abs(r.width - ws.width) < 1e-9 && abs(r.height - ws.height) < 1e-9, "\(q) size \(r.size)")
        }
    }

    @Test func fourRightTurnsComposeToIdentity() {
        // Apply r90 four times, each time on the freshly turned image.
        var q = QuarterTurns.r0
        var size = self.size
        var t = CGAffineTransform.identity
        for _ in 0..<4 {
            t = t.concatenating(quarterTurnTransform(.r90, orientedSize: size))
            size = workingSize(size, .r90)
            q = q.rotatedRight
        }
        #expect(q == .r0)
        #expect(size == self.size)
        expectPoint(apply(t, 123, 45), 123, 45)
        // Two r90 turns equal one r180.
        let t2 = quarterTurnTransform(.r90, orientedSize: self.size)
            .concatenating(quarterTurnTransform(.r90, orientedSize: CGSize(width: 300, height: 400)))
        let t180 = quarterTurnTransform(.r180, orientedSize: self.size)
        for (x, y) in [(0.0, 0.0), (400.0, 300.0), (123.0, 45.0)] {
            let a = apply(t2, x, y), b = apply(t180, x, y)
            expectPoint(a, b.x, b.y)
        }
    }
}

// MARK: - CIBridge

@Suite struct CIBridgeTests {
    @Test func flipIsAnInvolution() {
        let f = CIBridge.flip(height: 300)
        expectPoint(apply(f, 10, 20), 10, 280)
        expectPoint(apply(f.concatenating(f), 10, 20), 10, 20)
    }

    @Test func toCIMatchesFlipConjugation() {
        let t = CGAffineTransform(translationX: 30, y: 40).rotated(by: 0.3).scaledBy(x: 2, y: 3)
        let ci = CIBridge.toCI(t, srcHeight: 300, dstHeight: 500)
        // Point (x, y) in y-down src -> y-down dst by t. In CI space the same point is (x, H - y).
        for (x, y) in [(0.0, 0.0), (100.0, 50.0), (399.0, 299.0)] {
            let expected = CGPoint(x: x, y: y).applying(t)
            let viaCI = CGPoint(x: x, y: 300 - y).applying(ci)
            expectPoint(CGPoint(x: viaCI.x, y: 500 - viaCI.y), expected.x, expected.y)
        }
    }

    @Test func toCIRoundTripsThroughInverse() {
        let t = CGAffineTransform(translationX: -12, y: 7).rotated(by: -0.7).scaledBy(x: 0.5, y: 0.5)
        let ci = CIBridge.toCI(t, srcHeight: 300, dstHeight: 500)
        let back = CIBridge.toCI(t.inverted(), srcHeight: 500, dstHeight: 300)
        let p = apply(ci.concatenating(back), 77, 33)
        expectPoint(p, 77, 33)
        // And the CI inverse equals the bridged inverse.
        let inv = ci.inverted()
        for (x, y) in [(5.0, 6.0), (250.0, 120.0)] {
            let a = apply(inv, x, y), b = apply(back, x, y)
            expectPoint(a, b.x, b.y)
        }
    }

    /// End to end with an asymmetric fixture: turning the quadrant image 90° clockwise through
    /// Core Image must put blue (was BL) at the top-left.
    @Test func quarterTurnThroughCoreImageIsCorrect() throws {
        let url = try Fixtures.writeJPEG(width: 400, height: 300)
        let src = try SourceImage.load(url: url)
        let base = src.fullResolutionCIImage()
        let ws = workingSize(src.orientedSize, .r90)
        let expectedTL: [QuarterTurns: (Fixtures.RGBA, Fixtures.RGBA, Fixtures.RGBA, Fixtures.RGBA)] = [
            // (TL, TR, BL, BR) of the turned image
            .r0: (Fixtures.red, Fixtures.green, Fixtures.blue, Fixtures.white),
            .r90: (Fixtures.blue, Fixtures.red, Fixtures.white, Fixtures.green),
            .r180: (Fixtures.white, Fixtures.blue, Fixtures.green, Fixtures.red),
            .r270: (Fixtures.green, Fixtures.white, Fixtures.red, Fixtures.blue),
        ]
        _ = ws
        for q in QuarterTurns.allCases {
            let w = workingSize(src.orientedSize, q)
            let t = CIBridge.toCI(
                quarterTurnTransform(q, orientedSize: src.orientedSize),
                srcHeight: src.orientedSize.height, dstHeight: w.height)
            let turned = base.transformed(by: t)
            #expect(turned.extent == CGRect(origin: .zero, size: w), "\(q) extent \(turned.extent)")
            let cg = try #require(CIContext().createCGImage(
                turned, from: turned.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
            let e = try #require(expectedTL[q])
            expectColor(Fixtures.pixel(cg, x: 10, y: 10), e.0, "\(q) TL")
            expectColor(Fixtures.pixel(cg, x: cg.width - 10, y: 10), e.1, "\(q) TR")
            expectColor(Fixtures.pixel(cg, x: 10, y: cg.height - 10), e.2, "\(q) BL")
            expectColor(Fixtures.pixel(cg, x: cg.width - 10, y: cg.height - 10), e.3, "\(q) BR")
        }
    }
}

// MARK: - Real samples

@Suite struct RealSampleTests {
    static let folder = URL(fileURLWithPath: "/Users/rajadain/dev/instagrammar/scratch/samples", isDirectory: true)

    static func isRaw(_ url: URL) -> Bool {
        (UTType(filenameExtension: url.pathExtension))?.conforms(to: .rawImage) ?? false
    }

    @Test func loadsAndPreviewsEverySampleIfPresent() throws {
        guard FileManager.default.fileExists(atPath: Self.folder.path) else { return }  // skip gracefully
        let files = try FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in files {
            let src: SourceImage
            do {
                src = try SourceImage.load(url: url)
            } catch SourceImageError.unreadable where Self.isRaw(url) {
                // The system RAW decoder on this machine can't open this camera file (ImageIO
                // reports no properties). Not a regression in SourceImage; see MEMORY.md.
                print("note: ImageIO cannot read RAW sample \(url.lastPathComponent); skipped")
                continue
            }
            let preview = try src.makePreview(maxPixelSize: 1024)
            #expect(max(preview.width, preview.height) <= 1024, "\(url.lastPathComponent)")
            let want = src.orientedSize.width / src.orientedSize.height
            let got = Double(preview.width) / Double(preview.height)
            #expect(abs(got - want) / want < 0.01, "\(url.lastPathComponent): aspect \(got) vs \(want)")
        }
    }
}
