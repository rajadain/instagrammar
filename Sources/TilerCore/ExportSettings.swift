import Foundation

/// Output pixel size for exported tiles. Height always follows the tile aspect; never upscales.
public enum OutputSize: Hashable, Codable, Sendable {
    /// "Maximum": the native source pixels covered by one tile.
    case native
    /// A target tile width in pixels; height is derived as `round(width / aspect)`.
    case width(Int)

    /// Presets offered in the UI, largest first.
    public static let presets: [OutputSize] = [.native, .width(2160), .width(1440), .width(1080)]
}

/// User-chosen export options (persisted by the app).
public struct ExportSettings: Hashable, Codable, Sendable {
    public var size: OutputSize
    /// JPEG lossy compression quality, 0.5...1.0.
    public var quality: Double

    public static let qualityRange: ClosedRange<Double> = 0.5...1.0

    public init(size: OutputSize = .native, quality: Double = 1.0) {
        self.size = size
        self.quality = min(max(quality, Self.qualityRange.lowerBound), Self.qualityRange.upperBound)
    }
}

// MARK: - Output pixel size

extension OutputSize {
    /// The tile pixel size this option produces, given the native ("Maximum") tile size and the
    /// tile aspect. Never larger than `native` (decision P10):
    /// - `.native` returns `native` unchanged;
    /// - `.width(x)` uses `outW = min(x, nativeW)` (at least 1) and
    ///   `outH = min(round(outW / aspect), nativeH)` (at least 1). When `outW == nativeW` the
    ///   result is exactly `native`.
    public func pixelSize(native: (width: Int, height: Int), aspect: AspectRatio) -> (width: Int, height: Int) {
        switch self {
        case .native:
            return native
        case .width(let x):
            let w = max(1, min(x, native.width))
            if w >= native.width { return native }
            let h = Int((Double(w) * aspect.height / aspect.width).rounded())
            return (w, max(1, min(h, native.height)))
        }
    }
}

/// False when `size` would upscale: `.width(x)` with `x > nativeW` (or `x < 1`). `.native` is
/// always available. The UI disables unavailable options.
public func isAvailable(_ size: OutputSize, native: (width: Int, height: Int)) -> Bool {
    switch size {
    case .native: return true
    case .width(let x): return x >= 1 && x <= native.width
    }
}

// MARK: - Plan and naming

/// One file the exporter will write.
public struct TileOutput: Hashable, Sendable {
    /// 0-based tile index (left to right).
    public let index: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// File name only, e.g. `IMG_1234-tile-1.jpg`.
    public let fileName: String

    public init(index: Int, pixelWidth: Int, pixelHeight: Int, fileName: String) {
        self.index = index
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fileName = fileName
    }
}

/// The files an export will produce, in tile order. Every tile has the same pixel size:
/// `settings.size.pixelSize(native: nativeTilePixelSize(state, spec), aspect: spec.aspect)`.
///
/// `quarterTurns` doesn't affect the result (the crop state is already in S-space, after the
/// turns); it is accepted so callers can pass the full export description.
public func plan(state: CropState, spec: TileSpec, quarterTurns: QuarterTurns = .r0,
                 settings: ExportSettings, stem: String) -> [TileOutput] {
    let native = CropGeometry.nativeTilePixelSize(state: state, spec: spec)
    let size = settings.size.pixelSize(native: native, aspect: spec.aspect)
    return (0..<spec.count).map {
        TileOutput(index: $0, pixelWidth: size.width, pixelHeight: size.height,
                   fileName: fileName(stem: stem, index: $0, count: spec.count))
    }
}

/// `<stem>-tile-<n>.jpg` with a 1-based `n` (decision P7). `index` is 0-based. When
/// `count ≥ 10`, `n` is zero-padded to the width of `count` (`-tile-01`) so files sort
/// correctly. The stem is used as is (dashes, spaces and dots are kept).
public func fileName(stem: String, index: Int, count: Int) -> String {
    let n = String(index + 1)
    let width = count >= 10 ? String(count).count : 1
    let padded = String(repeating: "0", count: max(0, width - n.count)) + n
    return "\(stem)-tile-\(padded).jpg"
}
