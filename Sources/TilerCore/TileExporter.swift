import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Errors thrown while rendering or writing tiles.
public enum TileExportError: Error, LocalizedError, Equatable {
    /// The strip is smaller than one pixel per tile, so there is nothing to render.
    case emptyTile
    /// Core Image couldn't render tile `index` (0-based).
    case renderFailed(index: Int)
    /// ImageIO couldn't create or finish the JPEG at this URL.
    case writeFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .emptyTile:
            return "The selected area is too small to export."
        case .renderFailed(let index):
            return "Couldn't render tile \(index + 1)."
        case .writeFailed(let url):
            return "Couldn't write \"\(url.lastPathComponent)\"."
        }
    }
}

/// Renders tiles with Core Image and writes them as sRGB JPEGs with ImageIO.
///
/// Pipeline for tile `i` (all stock Core Image / ImageIO calls; the geometry comes from
/// `CropGeometry` and `CIBridge`):
/// 1. full-resolution oriented source → quarter turns (re-origined to (0, 0)) = S-space image;
/// 2. flatten alpha over white (P14), then `clampedToExtent()` so edge sampling never pulls in
///    transparent or dark pixels;
/// 3. map S-space → tile with `sToTile(…, outputSize: native)` at the integer native size (T17);
/// 4. when the output is smaller, downscale with Lanczos;
/// 5. render to RGBA8 sRGB (P11) and write a JPEG with cleaned metadata (P12), atomically.
///
/// The exporter never decides about overwriting: callers resolve collisions first.
public final class TileExporter: @unchecked Sendable {
    /// Upper bound on tiles rendered at the same time.
    public static let maxConcurrentTiles = 3

    private let context: CIContext
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Owns one `CIContext` (linear working space); reuse the exporter across exports.
    public init() {
        context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .cacheIntermediates: false,
        ])
    }

    // MARK: - Export

    /// Renders and writes every tile of `plan(...)` into `folder`, at most
    /// `maxConcurrentTiles` at a time. `progress(done, total)` is called with `(0, total)` first
    /// and then after each finished tile. Checks for cancellation before each tile; tiles
    /// already written stay on disk. Returns the written URLs in tile order.
    public func export(source: SourceImage, quarterTurns: QuarterTurns, state: CropState,
                       spec: TileSpec, settings: ExportSettings, to folder: URL,
                       progress: @Sendable (Int, Int) -> Void) async throws -> [URL] {
        let outputs = plan(state: state, spec: spec, quarterTurns: quarterTurns,
                           settings: settings, stem: source.stem)
        let job = try Job(exporter: self, source: source, quarterTurns: quarterTurns,
                          state: state, spec: spec, settings: settings)
        try Task.checkCancellation()

        let total = outputs.count
        var urls = [URL?](repeating: nil, count: total)
        progress(0, total)

        try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            var next = 0
            var done = 0
            while next < total || done < total {
                while next < total && next - done < Self.maxConcurrentTiles {
                    let output = outputs[next]
                    let url = folder.appendingPathComponent(output.fileName)
                    group.addTask {
                        try Task.checkCancellation()
                        let image = try job.render(index: output.index)
                        try Task.checkCancellation()
                        try job.write(image, to: url)
                        return (output.index, url)
                    }
                    next += 1
                }
                guard let (index, url) = try await group.next() else { break }
                urls[index] = url
                done += 1
                progress(done, total)
            }
        }
        return urls.compactMap { $0 }
    }

    /// Renders tile `index` (0-based) exactly as `export` would, without writing it. The image
    /// is RGBA8 in sRGB, sized as `plan(...)` says.
    public func renderTile(source: SourceImage, quarterTurns: QuarterTurns, state: CropState,
                           spec: TileSpec, settings: ExportSettings, index: Int) throws -> CGImage {
        try Job(exporter: self, source: source, quarterTurns: quarterTurns,
                state: state, spec: spec, settings: settings).render(index: index)
    }

    // MARK: - Job

    /// Everything shared by the tiles of one export, computed once.
    private struct Job: @unchecked Sendable {
        let exporter: TileExporter
        /// Flattened, edge-clamped S-space image in Core Image coordinates (infinite extent).
        let prepared: CIImage
        let workingHeight: CGFloat
        let state: CropState
        let spec: TileSpec
        let native: (width: Int, height: Int)
        let output: (width: Int, height: Int)
        let properties: [CFString: Any]

        init(exporter: TileExporter, source: SourceImage, quarterTurns: QuarterTurns,
             state: CropState, spec: TileSpec, settings: ExportSettings) throws {
            native = CropGeometry.nativeTilePixelSize(state: state, spec: spec)
            guard native.width > 0, native.height > 0 else { throw TileExportError.emptyTile }
            output = settings.size.pixelSize(native: native, aspect: spec.aspect)

            // 1. Oriented source → S-space (T20); the result's extent starts at (0, 0).
            let oriented = source.orientedSize
            let working = workingSize(oriented, quarterTurns)
            let turn = CIBridge.toCI(quarterTurnTransform(quarterTurns, orientedSize: oriented),
                                     srcHeight: oriented.height, dstHeight: working.height)
            let base = source.fullResolutionCIImage().transformed(by: turn)
            // 2. Flatten alpha over white (P14) before clamping the edges.
            let flat = base.composited(over: CIImage(color: .white).cropped(to: base.extent))

            self.exporter = exporter
            self.prepared = flat.clampedToExtent()
            self.workingHeight = working.height
            self.state = state
            self.spec = spec
            self.properties = TileExporter.outputProperties(
                from: source.properties, width: output.width, height: output.height,
                quality: settings.quality)
        }

        func render(index: Int) throws -> CGImage {
            // 3. S-space → tile pixels at the integer native size (T17).
            let nativeSize = CGSize(width: native.width, height: native.height)
            let t = CIBridge.toCI(
                CropGeometry.sToTile(state: state, spec: spec, index: index, outputSize: nativeSize),
                srcHeight: workingHeight, dstHeight: nativeSize.height)
            var tile = prepared.transformed(by: t)

            // 4. Lanczos downscale when the output is smaller than native. The input is still
            //    unbounded (clamped), so the filter never sees an edge.
            if output.width < native.width || output.height < native.height {
                let sy = Double(output.height) / Double(native.height)
                let sx = Double(output.width) / Double(native.width)
                let lanczos = CIFilter.lanczosScaleTransform()
                lanczos.inputImage = tile
                lanczos.scale = Float(sy)
                lanczos.aspectRatio = Float(sx / sy)
                guard let scaled = lanczos.outputImage else {
                    throw TileExportError.renderFailed(index: index)
                }
                tile = scaled
            }

            // 5. Render the integer output rect, converting to sRGB (P11).
            let rect = CGRect(x: 0, y: 0, width: output.width, height: output.height)
            guard let image = exporter.context.createCGImage(
                tile.cropped(to: rect), from: rect, format: .RGBA8, colorSpace: exporter.sRGB)
            else { throw TileExportError.renderFailed(index: index) }
            return image
        }

        /// 6. Writes a JPEG to a temp file in the destination folder, then renames it over
        ///    `url` (atomic replace: never a half-written tile).
        func write(_ image: CGImage, to url: URL) throws {
            let temp = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
            guard let dest = CGImageDestinationCreateWithURL(
                temp as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw TileExportError.writeFailed(url) }
            CGImageDestinationAddImage(dest, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(dest), rename(temp.path, url.path) == 0 else {
                try? FileManager.default.removeItem(at: temp)
                throw TileExportError.writeFailed(url)
            }
        }
    }

    // MARK: - Metadata

    /// Top-level keys copied from the source. Everything else is dropped: `{GPS}` (P12),
    /// `{MakerApple}` and other maker notes, container dictionaries (`{HEICS}`, `{PNG}`,
    /// `{JFIF}`, `{8BIM}`, …) and pixel-format keys (size, depth, colour model, profile name,
    /// alpha, HDR headroom), so the output's own size and sRGB profile win.
    static let keptTopLevelKeys: [CFString] = [
        kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary,
        kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary,
        kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight,
    ]

    /// `{TIFF}` keys that describe the photo rather than the old pixel encoding. Structural and
    /// colorimetric tags (tile size, compression, primaries, transfer function, …) are dropped.
    static let keptTIFFKeys: [CFString] = [
        kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware,
        kCGImagePropertyTIFFDateTime, kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright,
        kCGImagePropertyTIFFHostComputer, kCGImagePropertyTIFFImageDescription,
        kCGImagePropertyTIFFDocumentName, kCGImagePropertyTIFFXResolution,
        kCGImagePropertyTIFFYResolution, kCGImagePropertyTIFFResolutionUnit,
    ]

    /// `{Exif}` keys dropped because they describe the old pixels or point into them.
    static let droppedExifKeys: [CFString] = [
        kCGImagePropertyExifSubjectArea, kCGImagePropertyExifSubjectLocation,
        kCGImagePropertyExifComponentsConfiguration, kCGImagePropertyExifCompressedBitsPerPixel,
        kCGImagePropertyExifGamma,
    ]

    /// The JPEG properties for one output tile (decision P12): keep EXIF/ExifAux/TIFF/IPTC,
    /// strip GPS and maker notes, set Orientation = 1, fix the pixel dimensions, mark the
    /// colour space as sRGB and set the JPEG quality.
    static func outputProperties(from source: [CFString: Any], width: Int, height: Int,
                                 quality: Double) -> [CFString: Any] {
        var out: [CFString: Any] = [:]
        for key in keptTopLevelKeys {
            if let value = source[key] { out[key] = value }
        }

        var exif = source[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        for key in droppedExifKeys { exif.removeValue(forKey: key) }
        exif[kCGImagePropertyExifPixelXDimension] = width
        exif[kCGImagePropertyExifPixelYDimension] = height
        if exif[kCGImagePropertyExifColorSpace] != nil {
            exif[kCGImagePropertyExifColorSpace] = 1   // sRGB (was e.g. 0xFFFF for Display P3)
        }
        out[kCGImagePropertyExifDictionary] = exif

        let sourceTIFF = source[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var tiff: [CFString: Any] = [:]
        for key in keptTIFFKeys {
            if let value = sourceTIFF[key] { tiff[key] = value }
        }
        tiff[kCGImagePropertyTIFFOrientation] = 1
        out[kCGImagePropertyTIFFDictionary] = tiff

        if var iptc = source[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
            iptc.removeValue(forKey: kCGImagePropertyIPTCImageOrientation)
            out[kCGImagePropertyIPTCDictionary] = iptc
        }

        out[kCGImagePropertyOrientation] = 1
        out[kCGImageDestinationLossyCompressionQuality] = quality
        return out
    }
}
