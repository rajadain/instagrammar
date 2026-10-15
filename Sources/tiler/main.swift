import CoreGraphics
import Foundation
import TilerCore

// Headless export CLI (PLAN.md §5.3). Arguments are parsed by hand; no dependencies.

let usage = """
    usage: tiler <input> --out <dir> [--tiles 3] [--aspect 4:5] [--quarter-turns 0..3]
                 [--straighten <deg>] [--zoom <factor ≥ 1, relative to fit>]
                 [--offset <dx,dy in source px>] [--width <px>|max]
                 [--quality 0.5..1.0] [--force]

    Splits <input> into seamless carousel tiles written to <dir> as
    <stem>-tile-<n>.jpg. Prints each written path. Refuses to overwrite
    existing files unless --force is given.
    """

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

struct Options {
    var input: URL?
    var out: URL?
    var tiles = 3
    var aspect = AspectRatio.portrait4x5
    var quarterTurns = QuarterTurns.r0
    var straighten = 0.0
    var zoom = 1.0
    var offset = CGVector.zero
    var size = OutputSize.native
    var quality = 1.0
    var force = false
}

func parseNumber(_ s: String, _ flag: String) throws -> Double {
    guard let v = Double(s), v.isFinite else { throw CLIError("\(flag): '\(s)' is not a number") }
    return v
}

func parseAspect(_ s: String) throws -> AspectRatio {
    let parts = s.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) else {
        throw CLIError("--aspect: expected W:H, e.g. 4:5, got '\(s)'")
    }
    let a = AspectRatio(width: w, height: h)
    guard a.isValid else { throw CLIError("--aspect: both components must be positive") }
    return a
}

func parse(_ args: [String]) throws -> Options {
    var o = Options()
    var i = 0
    func value(_ flag: String) throws -> String {
        i += 1
        guard i < args.count else { throw CLIError("\(flag) needs a value") }
        return args[i]
    }
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-h", "--help":
            print(usage)
            exit(0)
        case "--out", "-o":
            o.out = URL(fileURLWithPath: try value(arg), isDirectory: true)
        case "--tiles", "-n":
            let s = try value(arg)
            guard let n = Int(s), TileSpec.countRange.contains(n) else {
                throw CLIError("--tiles: expected \(TileSpec.countRange.lowerBound)…\(TileSpec.countRange.upperBound), got '\(s)'")
            }
            o.tiles = n
        case "--aspect":
            o.aspect = try parseAspect(try value(arg))
        case "--quarter-turns":
            let s = try value(arg)
            guard let n = Int(s), let q = QuarterTurns(rawValue: n) else {
                throw CLIError("--quarter-turns: expected 0…3, got '\(s)'")
            }
            o.quarterTurns = q
        case "--straighten":
            o.straighten = try parseNumber(try value(arg), arg)
            guard abs(o.straighten) <= 45 else { throw CLIError("--straighten: must be within ±45°") }
        case "--zoom":
            o.zoom = try parseNumber(try value(arg), arg)
            guard o.zoom >= 1 else { throw CLIError("--zoom: must be ≥ 1") }
        case "--offset":
            let s = try value(arg)
            let parts = s.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 2, let dx = Double(parts[0]), let dy = Double(parts[1]) else {
                throw CLIError("--offset: expected dx,dy, got '\(s)'")
            }
            o.offset = CGVector(dx: dx, dy: dy)
        case "--width":
            let s = try value(arg)
            if s == "max" || s == "native" {
                o.size = .native
            } else if let w = Int(s), w > 0 {
                o.size = .width(w)
            } else {
                throw CLIError("--width: expected a positive integer or 'max', got '\(s)'")
            }
        case "--quality":
            o.quality = try parseNumber(try value(arg), arg)
            guard ExportSettings.qualityRange.contains(o.quality) else {
                throw CLIError("--quality: must be within 0.5…1.0")
            }
        case "--force", "-f":
            o.force = true
        default:
            if arg.hasPrefix("-") { throw CLIError("unknown option \(arg)") }
            guard o.input == nil else { throw CLIError("unexpected argument '\(arg)'") }
            o.input = URL(fileURLWithPath: arg)
        }
        i += 1
    }
    return o
}

func run() async throws {
    let o = try parse(Array(CommandLine.arguments.dropFirst()))
    guard let input = o.input else { throw CLIError("missing <input>\n\n\(usage)") }
    guard let out = o.out else { throw CLIError("missing --out <dir>\n\n\(usage)") }

    let source = try SourceImage.load(url: input)
    let spec = TileSpec(aspect: o.aspect, count: o.tiles)
    let imageSize = workingSize(source.orientedSize, o.quarterTurns)

    // fit → straighten → zoom (about the centre) → offset → clamp.
    var state = CropGeometry.fit(spec: spec, imageSize: imageSize,
                                 angle: CropState.angle(forStraightenDegrees: o.straighten))
    state.width /= o.zoom
    state.center.x += o.offset.dx
    state.center.y += o.offset.dy
    state = CropGeometry.clamp(state, spec: spec, imageSize: imageSize)

    let settings = ExportSettings(size: o.size, quality: o.quality)
    let native = CropGeometry.nativeTilePixelSize(state: state, spec: spec)
    if !isAvailable(o.size, native: native) {
        FileHandle.standardError.write(Data(
            "note: --width exceeds the native tile width \(native.width) px; using \(native.width) px (never upscales)\n".utf8))
    }

    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: out.path, isDirectory: &isDir) {
        guard isDir.boolValue else { throw CLIError("--out: '\(out.path)' is not a directory") }
    } else {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    let outputs = plan(state: state, spec: spec, quarterTurns: o.quarterTurns,
                       settings: settings, stem: source.stem)
    if !o.force {
        let existing = outputs.map { out.appendingPathComponent($0.fileName) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty {
            throw CLIError("refusing to overwrite existing files (use --force):\n"
                + existing.map { "  " + $0.path }.joined(separator: "\n"))
        }
    }

    let urls = try await TileExporter().export(
        source: source, quarterTurns: o.quarterTurns, state: state, spec: spec,
        settings: settings, to: out, progress: { _, _ in })
    for url in urls { print(url.path) }
}

do {
    try await run()
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    FileHandle.standardError.write(Data("tiler: \(message)\n".utf8))
    exit(1)
}
