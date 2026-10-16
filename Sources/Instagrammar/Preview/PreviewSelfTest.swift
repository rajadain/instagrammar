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

        // Drag settling: a quarter tile moves one tile, never more; resisted past the ends.
        let w = preview.displaySize.width
        preview.index = 1
        check(preview.settledIndex(translation: -w * 0.2, width: w) == 1, "short drag springs back")
        check(preview.settledIndex(translation: -w * 0.3, width: w) == 2, "quarter-tile drag goes to next")
        check(preview.settledIndex(translation: w * 0.3, width: w) == 0, "quarter-tile drag goes to previous")
        check(preview.settledIndex(translation: -w * 5, width: w) == 2, "a long drag still moves one tile")
        preview.index = 0
        check(preview.settledIndex(translation: w, width: w) == 0, "can't drag before the first tile")
        check(preview.resistedTranslation(90, width: w) == 30, "dragging past the first tile is resisted")
        check(preview.resistedTranslation(-w * 3, width: w) == -w, "drag is capped at one tile")

        // The real sheet: open it through the model flag and look for an attached sheet window.
        model.showCarouselPreview()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        check(NSApp.windows.contains { $0.sheetParent != nil }, "⌘P sheet is presented")
        if let sheet = NSApp.windows.first(where: { $0.sheetParent != nil }) {
            // Snapshots at rest, mid-slide (seam visible) and after sliding to tile 2.
            snapshot(sheet, to: folder.appendingPathComponent("sheet-1-rest.png"))
            if let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: sheet.windowNumber, context: nil, characters: "\u{F703}",
                                             charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124) {
                sheet.sendEvent(right)
            }
            try? await Task.sleep(nanoseconds: 90_000_000)
            snapshot(sheet, to: folder.appendingPathComponent("sheet-2-mid-slide.png"))
            try? await Task.sleep(nanoseconds: 900_000_000)
            snapshot(sheet, to: folder.appendingPathComponent("sheet-3-after.png"))
        }
        model.isShowingCarouselPreview = false
        try? await Task.sleep(nanoseconds: 500_000_000)
        check(!NSApp.windows.contains { $0.sheetParent != nil }, "sheet dismissed")

        if !failures.isEmpty { log("failures: \(failures.joined(separator: "; "))") }
        return failures.isEmpty
    }

    /// Captures one of our own windows (no Screen Recording permission needed); see the canvas self-test.
    private static func snapshot(_ window: NSWindow, to url: URL) {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "CGWindowListCreateImage"),
              let image = unsafeBitCast(sym, to: Fn.self)(.null, 8, UInt32(window.windowNumber), 1 | 8)?
                  .takeRetainedValue()
        else { log("snapshot \(url.lastPathComponent): capture failed"); return }
        _ = write(image, to: url)
        log("snapshot \(url.path)")
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
