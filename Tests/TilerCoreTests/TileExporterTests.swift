import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import TilerCore

private func expectColor(_ p: Fixtures.RGBA, _ expected: Fixtures.RGBA, _ label: String,
                         tolerance: Int = 24, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(Fixtures.isClose(p, to: expected, tolerance: tolerance),
            "\(label): got \(p), expected \(expected)", sourceLocation: sourceLocation)
}

/// Collects progress callbacks from the exporter.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(Int, Int)] = []
    func record(_ done: Int, _ total: Int) { lock.withLock { calls.append((done, total)) } }
    var all: [(Int, Int)] { lock.withLock { calls } }
}

private let spec3 = TileSpec(aspect: .portrait4x5, count: 3)

/// Exports with a fresh exporter into a fresh folder.
private func exportTiles(_ src: SourceImage, quarterTurns: QuarterTurns = .r0, state: CropState,
                         spec: TileSpec = spec3, settings: ExportSettings = ExportSettings(),
                         to folder: URL? = nil) async throws -> [URL] {
    let dir = try folder ?? Fixtures.makeTempDirectory()
    return try await TileExporter().export(source: src, quarterTurns: quarterTurns, state: state,
                                           spec: spec, settings: settings, to: dir,
                                           progress: { _, _ in })
}

private func imageSize(_ src: SourceImage, _ q: QuarterTurns = .r0) -> CGSize {
    workingSize(src.orientedSize, q)
}

// MARK: - Sizes, names, progress

@Suite struct TileExporterOutputTests {
    @Test func countSizesAndNamesMatchPlan() async throws {
        let src = try SourceImage.load(url: try Fixtures.writeJPEG(width: 1200, height: 500, name: "my-photo 1"))
        let state = CropGeometry.fit(spec: spec3, imageSize: imageSize(src))
        let dir = try Fixtures.makeTempDirectory()
        let log = ProgressLog()
        let urls = try await TileExporter().export(
            source: src, quarterTurns: .r0, state: state, spec: spec3, settings: ExportSettings(),
            to: dir, progress: { log.record($0, $1) })
        let outputs = plan(state: state, spec: spec3, settings: ExportSettings(), stem: src.stem)

        #expect(urls.map(\.lastPathComponent) == outputs.map(\.fileName))
        #expect(urls.map(\.lastPathComponent) == ["my-photo 1-tile-1.jpg", "my-photo 1-tile-2.jpg", "my-photo 1-tile-3.jpg"])
        for (url, o) in zip(urls, outputs) {
            let (img, props) = try Fixtures.read(url)
            #expect(img.width == o.pixelWidth && img.height == o.pixelHeight)
            #expect((props[kCGImagePropertyPixelWidth] as? Int) == o.pixelWidth)
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
            #expect((exif?[kCGImagePropertyExifPixelXDimension] as? Int) == o.pixelWidth)
            #expect((exif?[kCGImagePropertyExifPixelYDimension] as? Int) == o.pixelHeight)
        }
        #expect(outputs.first.map { ($0.pixelWidth, $0.pixelHeight) }! == (400, 500))
        // Progress starts at 0 and ends at total; no temp files are left behind.
        #expect(log.all.first! == (0, 3) && log.all.last! == (3, 3) && log.all.count == 4)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(left == outputs.map(\.fileName).sorted())
    }

    @Test func manyTilesExportWithPaddedNames() async throws {
        let spec = TileSpec(aspect: .square, count: 12)
        let src = try SourceImage.load(url: try Fixtures.writeJPEG(width: 2400, height: 200, name: "pano"))
        let state = CropGeometry.fit(spec: spec, imageSize: imageSize(src))
        let urls = try await exportTiles(src, state: state, spec: spec)
        #expect(urls.count == 12)
        #expect(urls.first?.lastPathComponent == "pano-tile-01.jpg")
        #expect(urls.last?.lastPathComponent == "pano-tile-12.jpg")
        for url in urls {
            let (img, _) = try Fixtures.read(url)
            #expect(img.width == 200 && img.height == 200)
        }
    }

    @Test func overwritesExistingFilesAtomically() async throws {
        let src = try SourceImage.load(url: try Fixtures.writeJPEG(width: 1200, height: 500))
        let state = CropGeometry.fit(spec: spec3, imageSize: imageSize(src))
        let dir = try Fixtures.makeTempDirectory()
        let first = try await exportTiles(src, state: state, to: dir)
        try Data("old".utf8).write(to: first[0])
        let second = try await exportTiles(src, state: state, to: dir)
        #expect(second == first)
        let (img, _) = try Fixtures.read(second[0])
        #expect(img.width == 400)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 3)
    }

    @Test func cancellationStopsTheExport() async throws {
        let src = try SourceImage.load(url: try Fixtures.writeJPEG(width: 1200, height: 500))
        let state = CropGeometry.fit(spec: spec3, imageSize: imageSize(src))
        let dir = try Fixtures.makeTempDirectory()
        let task = Task {
            try await TileExporter().export(source: src, quarterTurns: .r0, state: state, spec: spec3,
                                            settings: ExportSettings(), to: dir, progress: { _, _ in })
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func emptyStripThrows() async throws {
        let src = try SourceImage.load(url: try Fixtures.writeJPEG(width: 1200, height: 500))
        let tiny = CropState(center: CGPoint(x: 600, y: 250), width: 2, angle: 0)
        await #expect(throws: TileExportError.emptyTile) { try await exportTiles(src, state: tiny) }
    }
}

// MARK: - Pixels

@Suite struct TileExporterPixelTests {
    /// Seamlessness: tile i of N = 3 equals the matching third of one N = 1 render of the same
    /// strip (aspect 3·a), both as rendered images and as exported JPEGs.
    @Test(arguments: [false, true])
    func tilesAreSeamless(straightened: Bool) async throws {
        let src = try SourceImage.load(url: try Fixtures.writeJPEG(width: 1200, height: 500, grid: true))
        let size = imageSize(src)
        let single = TileSpec(aspect: AspectRatio(width: 12, height: 5), count: 1)
        var state = CropGeometry.fit(spec: spec3, imageSize: size)
        if straightened {
            // Rotated 5° and zoomed so the strip width (900) and tile width (300) are integers.
            state = CropState(center: CGPoint(x: 611.3, y: 247.9), width: 900,
                              angle: CropState.angle(forStraightenDegrees: 5))
            #expect(CropGeometry.clamp(state, spec: spec3, imageSize: size) == state)
        }
        let tileW = CropGeometry.nativeTilePixelSize(state: state, spec: spec3).width
        #expect(CropGeometry.nativeTilePixelSize(state: state, spec: single).width == 3 * tileW)

        // Rendered images: virtually identical.
        let exporter = TileExporter()
        let whole = try exporter.renderTile(source: src, quarterTurns: .r0, state: state, spec: single,
                                            settings: ExportSettings(), index: 0)
        for i in 0..<3 {
            let tile = try exporter.renderTile(source: src, quarterTurns: .r0, state: state, spec: spec3,
                                               settings: ExportSettings(), index: i)
            #expect(tile.height == whole.height)
            let d = Fixtures.meanAbsDiff(tile, whole, bx: i * tileW)
            #expect(d < 0.5 / 255, "render tile \(i): mean abs diff \(d * 255)/255")
        }

        // Exported JPEGs: below 2/255.
        let tiles = try await exportTiles(src, state: state)
        let wholeURL = try await exportTiles(src, state: state, spec: single)[0]
        let wholeJPEG = try Fixtures.read(wholeURL).image
        for (i, url) in tiles.enumerated() {
            let d = Fixtures.meanAbsDiff(try Fixtures.read(url).image, wholeJPEG, bx: i * tileW)
            #expect(d < 2.0 / 255, "jpeg tile \(i): mean abs diff \(d * 255)/255")
        }
    }

    @Test func quadrantCornersAtFullFit() async throws {
        let src = try SourceImage.load(url: try Fixtures.writeJPEG(width: 1200, height: 500))
        let state = CropGeometry.fit(spec: spec3, imageSize: imageSize(src))
        let urls = try await exportTiles(src, state: state)
        let first = try Fixtures.read(urls[0]).image, last = try Fixtures.read(urls[2]).image
        expectColor(Fixtures.pixel(first, x: 0, y: 0), Fixtures.red, "tile 0 TL")
        expectColor(Fixtures.pixel(first, x: 0, y: first.height - 1), Fixtures.blue, "tile 0 BL")
        expectColor(Fixtures.pixel(last, x: last.width - 1, y: 0), Fixtures.green, "last TR")
        expectColor(Fixtures.pixel(last, x: last.width - 1, y: last.height - 1), Fixtures.white, "last BR")
    }

    @Test(arguments: [6, 8])
    func exifRotatedSourceIsUprightWithOrientationOne(orientation: Int) async throws {
        let url = try Fixtures.writeJPEG(width: 1200, height: 500, orientation: orientation)
        let src = try SourceImage.load(url: url)
        let state = CropGeometry.fit(spec: spec3, imageSize: imageSize(src))
        let urls = try await exportTiles(src, state: state)
        for u in urls {
            let (img, props) = try Fixtures.read(u)
            #expect(img.width == 400 && img.height == 500)
            #expect((props[kCGImagePropertyOrientation] as? Int) == 1)
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            #expect((tiff?[kCGImagePropertyTIFFOrientation] as? Int) == 1)
        }
        let first = try Fixtures.read(urls[0]).image, last = try Fixtures.read(urls[2]).image
        expectColor(Fixtures.pixel(first, x: 2, y: 2), Fixtures.red, "tile 0 TL")
        expectColor(Fixtures.pixel(first, x: 2, y: first.height - 3), Fixtures.blue, "tile 0 BL")
        expectColor(Fixtures.pixel(last, x: last.width - 3, y: last.height - 3), Fixtures.white, "last BR")
    }

    /// All four user quarter turns (T20): the tile corners show the turned image's corners.
    @Test(arguments: QuarterTurns.allCases)
    func quarterTurnsAreApplied(q: QuarterTurns) async throws {
        let src = try SourceImage.load(url: try Fixtures.writeJPEG(width: 800, height: 600))
        let spec = TileSpec(aspect: .portrait4x5, count: 2)
        let state = CropGeometry.fit(spec: spec, imageSize: imageSize(src, q))
        let urls = try await exportTiles(src, quarterTurns: q, state: state, spec: spec)
        let native = CropGeometry.nativeTilePixelSize(state: state, spec: spec)
        // (TL, TR, BL, BR) of the turned image.
        let expected: [QuarterTurns: (Fixtures.RGBA, Fixtures.RGBA, Fixtures.RGBA, Fixtures.RGBA)] = [
            .r0: (Fixtures.red, Fixtures.green, Fixtures.blue, Fixtures.white),
            .r90: (Fixtures.blue, Fixtures.red, Fixtures.white, Fixtures.green),
            .r180: (Fixtures.white, Fixtures.blue, Fixtures.green, Fixtures.red),
            .r270: (Fixtures.green, Fixtures.white, Fixtures.red, Fixtures.blue),
        ]
        let e = try #require(expected[q])
        let first = try Fixtures.read(urls[0]).image, last = try Fixtures.read(urls[1]).image
        #expect(first.width == native.width && first.height == native.height)
        let w = last.width, h = last.height
        expectColor(Fixtures.pixel(first, x: 1, y: 1), e.0, "\(q) TL")
        expectColor(Fixtures.pixel(last, x: w - 2, y: 1), e.1, "\(q) TR")
        expectColor(Fixtures.pixel(first, x: 1, y: h - 2), e.2, "\(q) BL")
        expectColor(Fixtures.pixel(last, x: w - 2, y: h - 2), e.3, "\(q) BR")
    }

    @Test func downscaledOutput() async throws {
        let src = try SourceImage.load(url: try Fixtures.writeJPEG(width: 1200, height: 500))
        let state = CropGeometry.fit(spec: spec3, imageSize: imageSize(src))
        let urls = try await exportTiles(src, state: state, settings: ExportSettings(size: .width(200)))
        for url in urls {
            let img = try Fixtures.read(url).image
            #expect(img.width == 200 && img.height == 250)
        }
        let first = try Fixtures.read(urls[0]).image, last = try Fixtures.read(urls[2]).image
        expectColor(Fixtures.pixel(first, x: 0, y: 0), Fixtures.red, "tile 0 TL")
        expectColor(Fixtures.pixel(first, x: 0, y: 249), Fixtures.blue, "tile 0 BL")
        expectColor(Fixtures.pixel(last, x: 199, y: 0), Fixtures.green, "last TR")
        expectColor(Fixtures.pixel(last, x: 199, y: 249), Fixtures.white, "last BR")

        // Lanczos output of the whole strip matches the downscaled tiles (seams still exact).
        let exporter = TileExporter()
        let single = TileSpec(aspect: AspectRatio(width: 12, height: 5), count: 1)
        let whole = try exporter.renderTile(source: src, quarterTurns: .r0, state: state, spec: single,
                                            settings: ExportSettings(size: .width(600)), index: 0)
        #expect(whole.width == 600 && whole.height == 250)
        for i in 0..<3 {
            let tile = try exporter.renderTile(source: src, quarterTurns: .r0, state: state, spec: spec3,
                                               settings: ExportSettings(size: .width(200)), index: i)
            let d = Fixtures.meanAbsDiff(tile, whole, bx: i * 200)
            #expect(d < 1.0 / 255, "downscaled tile \(i): \(d * 255)/255")
        }
    }

    /// Straightened (and downscaled) exports have no dark or transparent fringes at the edges.
    @Test(arguments: [OutputSize.native, .width(150)])
    func straightenedExportHasNoEdgeFringes(size: OutputSize) async throws {
        let url = try Fixtures.writeJPEG(image: Fixtures.solid(width: 1200, height: 800))
        let src = try SourceImage.load(url: url)
        for sigma in [7.3, -12.0] {
            let state = CropGeometry.fit(spec: spec3, imageSize: imageSize(src),
                                         angle: CropState.angle(forStraightenDegrees: sigma))
            let urls = try await exportTiles(src, state: state, settings: ExportSettings(size: size))
            for (i, u) in urls.enumerated() {
                let img = try Fixtures.read(u).image
                let w = img.width, h = img.height
                for (x, y) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1), (w / 2, 0), (0, h / 2)] {
                    expectColor(Fixtures.pixel(img, x: x, y: y), Fixtures.white,
                                "σ \(sigma) tile \(i) (\(x), \(y))", tolerance: 3)
                }
            }
        }
    }

    @Test func pngAlphaIsFlattenedOverWhite() async throws {
        let url = try Fixtures.writePNG(image: Fixtures.halfTransparent(width: 600, height: 500))
        let src = try SourceImage.load(url: url)
        let state = CropGeometry.fit(spec: spec3, imageSize: imageSize(src))   // 600 × 250
        let urls = try await exportTiles(src, state: state)
        let first = try Fixtures.read(urls[0]).image, last = try Fixtures.read(urls[2]).image
        let p = Fixtures.pixel(first, x: 0, y: 0)
        expectColor(p, Fixtures.white, "transparent → white", tolerance: 2)
        #expect(p.a == 255)
        expectColor(Fixtures.pixel(last, x: last.width - 1, y: last.height - 1), Fixtures.red, "opaque red")
    }
}

// MARK: - Metadata and quality

@Suite struct TileExporterMetadataTests {
    @Test(arguments: [Fixtures.FixtureColorSpace.sRGB, .displayP3])
    func metadataIsCleanedAndOutputIsSRGB(colorSpace: Fixtures.FixtureColorSpace) async throws {
        let url = try Fixtures.writeJPEG(width: 1200, height: 500, orientation: 6, colorSpace: colorSpace,
                                         includeGPS: true)
        let src = try SourceImage.load(url: url)
        #expect(src.properties[kCGImagePropertyGPSDictionary] != nil)
        let state = CropGeometry.fit(spec: spec3, imageSize: imageSize(src))
        let urls = try await exportTiles(src, state: state)
        for u in urls {
            let (img, props) = try Fixtures.read(u)
            #expect(props[kCGImagePropertyGPSDictionary] == nil)
            let exif = try #require(props[kCGImagePropertyExifDictionary] as? [CFString: Any])
            #expect((exif[kCGImagePropertyExifLensModel] as? String) == "Test Lens 35mm")
            #expect((exif[kCGImagePropertyExifDateTimeOriginal] as? String) == "2024:05:17 13:45:00")
            #expect((exif[kCGImagePropertyExifColorSpace] as? Int) == 1)
            let tiff = try #require(props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
            #expect((tiff[kCGImagePropertyTIFFMake] as? String) == "TestMake")
            #expect((tiff[kCGImagePropertyTIFFModel] as? String) == "TestModel")
            #expect((props[kCGImagePropertyOrientation] as? Int) == 1)
            #expect(img.colorSpace?.name == CGColorSpace.sRGB)
            #expect((props[kCGImagePropertyProfileName] as? String)?.contains("sRGB") == true)
        }
        // Colours survive the P3 → sRGB conversion (saturated P3 red clips to sRGB red).
        let tl = Fixtures.pixel(try Fixtures.read(urls[0]).image, x: 2, y: 2)
        #expect(tl.r > 200 && tl.g < 60 && tl.b < 60, "TL \(tl)")
    }

    @Test func outputPropertiesDropGPSMakerNotesAndContainerKeys() {
        let source: [CFString: Any] = [
            kCGImagePropertyPixelWidth: 4032, kCGImagePropertyPixelHeight: 3024,
            kCGImagePropertyDepth: 8, kCGImagePropertyColorModel: "RGB",
            kCGImagePropertyProfileName: "Display P3", kCGImagePropertyOrientation: 6,
            kCGImagePropertyDPIWidth: 72, kCGImagePropertyDPIHeight: 72,
            "Headroom" as CFString: 1, "PrimaryImage" as CFString: 1,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.0],
            kCGImagePropertyMakerAppleDictionary: ["1": 2],
            kCGImagePropertyHEICSDictionary: ["LoopCount": 0],
            kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFVersion: [1, 1]],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifLensModel: "Lens", kCGImagePropertyExifDateTimeOriginal: "2022:08:21 08:40:37",
                kCGImagePropertyExifColorSpace: 65535, kCGImagePropertyExifSubjectArea: [1, 2, 3, 4],
                kCGImagePropertyExifPixelXDimension: 4032, kCGImagePropertyExifPixelYDimension: 3024,
            ],
            kCGImagePropertyExifAuxDictionary: [kCGImagePropertyExifAuxLensModel: "Lens"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCopyrightNotice: "©",
                                             kCGImagePropertyIPTCImageOrientation: 6],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFOrientation: 6,
                kCGImagePropertyTIFFTileWidth: 512, kCGImagePropertyTIFFTileLength: 512,
            ],
        ]
        let out = TileExporter.outputProperties(from: source, width: 1344, height: 1680, quality: 0.8)
        #expect(Set(out.keys.map { $0 as String }) == Set([
            kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary,
            kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary,
            kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight,
            kCGImagePropertyOrientation, kCGImageDestinationLossyCompressionQuality,
        ].map { $0 as String }))
        #expect((out[kCGImagePropertyOrientation] as? Int) == 1)
        #expect((out[kCGImageDestinationLossyCompressionQuality] as? Double) == 0.8)
        let exif = out[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect((exif?[kCGImagePropertyExifPixelXDimension] as? Int) == 1344)
        #expect((exif?[kCGImagePropertyExifPixelYDimension] as? Int) == 1680)
        #expect((exif?[kCGImagePropertyExifColorSpace] as? Int) == 1)
        #expect(exif?[kCGImagePropertyExifSubjectArea] == nil)
        #expect((exif?[kCGImagePropertyExifLensModel] as? String) == "Lens")
        let tiff = out[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect((tiff?[kCGImagePropertyTIFFOrientation] as? Int) == 1)
        #expect((tiff?[kCGImagePropertyTIFFMake] as? String) == "Apple")
        #expect(tiff?[kCGImagePropertyTIFFTileWidth] == nil && tiff?[kCGImagePropertyTIFFTileLength] == nil)
        let iptc = out[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        #expect(iptc?[kCGImagePropertyIPTCImageOrientation] == nil)
        #expect((iptc?[kCGImagePropertyIPTCCopyrightNotice] as? String) == "©")
    }

    @Test func lowerQualityGivesSmallerFiles() async throws {
        let src = try SourceImage.load(url: try Fixtures.writeJPEG(width: 1200, height: 500, grid: true))
        let state = CropGeometry.fit(spec: spec3, imageSize: imageSize(src))
        func totalBytes(_ q: Double) async throws -> Int {
            let urls = try await exportTiles(src, state: state, settings: ExportSettings(quality: q))
            return try urls.reduce(0) {
                $0 + ((try FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int) ?? 0)
            }
        }
        let high = try await totalBytes(1.0), low = try await totalBytes(0.6)
        #expect(low < high, "q0.6 \(low) B vs q1.0 \(high) B")
    }
}
