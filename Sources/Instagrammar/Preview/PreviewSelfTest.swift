#if DEBUG
import AppKit
import Foundation
import ImageIO
import TilerCore
import UniformTypeIdentifiers

/// Headless check of the carousel preview renderer. Run the debug binary as
/// `INSTAGRAMMAR_PREVIEW_SELFTEST=<existing folder> .build/debug/Instagrammar <image>`: it opens
/// the image, renders every preview tile at 2x backing scale, writes `preview-tile-<n>.png` files
/// into the folder, prints PASS/FAIL to stderr and quits.
@MainActor
enum PreviewSelfTest {
    static let variable = "INSTAGRAMMAR_PREVIEW_SELFTEST"

    /// Returns true when the self-test was requested (and started).
    static func runIfRequested(url: URL) -> Bool {
        guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty else { return false }
        Task { @MainActor in
            let ok = await run(image: url, folder: URL(fileURLWithPath: path, isDirectory: true))
            FileHandle.standardError.write(Data((ok ? "SELFTEST PASS\n" : "SELFTEST FAIL\n").utf8))
            exit(ok ? 0 : 1)
        }
        return true
    }

    private static func run(image: URL, folder: URL) async -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ what: String) {
            log((condition ? "  ok   " : "  FAIL ") + what)
            if !condition { failures.append(what) }
        }

        let model = AppModel.shared
        await model.open(url: image)
        check(model.canPreviewCarousel, "image loaded; preview enabled")
        guard let job = model.makeCarouselPreviewJob() else { return false }

        let preview = CarouselPreviewModel(job: job, backingScale: 2)
        let start = Date()
        await preview.waitUntilRendered()
        log(String(format: "rendered %d tiles of %.0fx%.0f px in %.0f ms", preview.count,
                   preview.pixelSize.width, preview.pixelSize.height, Date().timeIntervalSince(start) * 1000))

        check(preview.count == job.spec.count, "tile count matches the spec (\(preview.count))")
        check(abs(preview.displaySize.width * preview.backingScale - preview.pixelSize.width) < 0.01,
              "display size is pixel size / backing scale")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (i, tile) in preview.tiles.enumerated() {
            guard let tile else { check(false, "tile \(i + 1) rendered"); continue }
            check(Int(preview.pixelSize.width) == tile.width && Int(preview.pixelSize.height) == tile.height,
                  "tile \(i + 1) has the expected pixel size")
            let url = folder.appendingPathComponent("preview-tile-\(i + 1).png")
            check(write(tile, to: url), "wrote \(url.lastPathComponent)")
        }

        // Navigation bounds.
        preview.index = 0
        preview.previous()
        check(preview.index == 0, "previous stops at the first tile")
        for _ in 0..<(preview.count + 2) { preview.next() }
        check(preview.index == preview.count - 1, "next stops at the last tile")

        if !failures.isEmpty { log("failures: \(failures.joined(separator: "; "))") }
        return failures.isEmpty
    }

    private static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    private static func log(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
#endif
