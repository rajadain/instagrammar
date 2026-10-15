import Foundation

/// A width:height ratio, e.g. 4:5. Both components must be positive.
public struct AspectRatio: Hashable, Codable, Sendable {
    /// Width component, e.g. `4` for 4:5.
    public var width: Double
    /// Height component, e.g. `5` for 4:5.
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// The ratio as a single number, `width / height` (e.g. 0.8 for 4:5).
    public var value: Double { width / height }

    /// True when both components are finite and positive.
    public var isValid: Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0
    }

    /// Portrait 4:5 (Instagram's tallest feed aspect; the default).
    public static let portrait4x5 = AspectRatio(width: 4, height: 5)
    /// Portrait 3:4.
    public static let portrait3x4 = AspectRatio(width: 3, height: 4)
    /// Square 1:1.
    public static let square = AspectRatio(width: 1, height: 1)
    /// Landscape 1.91:1.
    public static let landscape191 = AspectRatio(width: 1.91, height: 1)
}

/// The tile aspect choices offered in the UI.
public enum AspectPreset: String, CaseIterable, Codable, Sendable {
    case portrait4x5, portrait3x4, square, landscape191, custom

    /// Human-readable name, e.g. "Portrait 4:5".
    public var displayName: String {
        switch self {
        case .portrait4x5: return "Portrait 4:5"
        case .portrait3x4: return "Portrait 3:4"
        case .square: return "Square 1:1"
        case .landscape191: return "Landscape 1.91:1"
        case .custom: return "Custom"
        }
    }

    /// The ratio for this preset. `.custom` returns `custom`, which the caller stores separately;
    /// every other preset ignores it.
    public func aspect(custom: AspectRatio) -> AspectRatio {
        switch self {
        case .portrait4x5: return .portrait4x5
        case .portrait3x4: return .portrait3x4
        case .square: return .square
        case .landscape191: return .landscape191
        case .custom: return custom
        }
    }
}

/// What to produce: `count` tiles, each with aspect `aspect`, laid side by side as one strip.
public struct TileSpec: Hashable, Codable, Sendable {
    /// Allowed tile counts (Instagram carousel maximum is 20).
    public static let countRange: ClosedRange<Int> = 1...20

    /// Aspect of each individual tile.
    public var aspect: AspectRatio
    /// Number of tiles, expected to be within `countRange`.
    public var count: Int

    /// Creates a spec. `count` is clamped into `countRange`.
    public init(aspect: AspectRatio, count: Int) {
        self.aspect = aspect
        self.count = min(max(count, Self.countRange.lowerBound), Self.countRange.upperBound)
    }

    /// Aspect (width / height) of the whole strip, "A" = count × aspect.value.
    public var stripAspect: Double { Double(count) * aspect.value }
}
