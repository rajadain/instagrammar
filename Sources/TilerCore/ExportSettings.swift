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
