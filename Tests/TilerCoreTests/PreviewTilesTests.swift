import CoreGraphics
import Foundation
import Testing
@testable import TilerCore

@Suite struct PreviewTilesTests {
    /// Two 1:1 tiles over a 2:1 image: the strip is the whole (working) image.
    private let spec = TileSpec(aspect: AspectRatio(width: 1, height: 1), count: 2)

    private func render(quarterTurns: QuarterTurns, previewWidth: Int = 600, outputWidth: Int,
                        index: Int) throws -> CGImage {
        // Displayed 2:1 image, 1200x600 "original", 600x300 preview.
        let preview = Fixtures.quadrants(width: previewWidth, height: previewWidth / 2)
        let oriented = CGSize(width: 1200, height: 600)
        let working = workingSize(oriented, quarterTurns)
        let state = CropGeometry.fit(spec: spec, imageSize: working)
        let size = PreviewTileRenderer.tilePixelSize(pixelWidth: outputWidth, aspect: spec.aspect)
        let image = PreviewTileRenderer().render(
            preview: preview, quarterTurns: quarterTurns, orientedSize: oriented,
            state: state, spec: spec, index: index, outputSize: size)
        return try #require(image)
    }

    private func corners(_ img: CGImage, inset: Int = 4) -> [Fixtures.RGBA] {
        [Fixtures.pixel(img, x: inset, y: inset),
         Fixtures.pixel(img, x: img.width - 1 - inset, y: inset),
         Fixtures.pixel(img, x: img.width - 1 - inset, y: img.height - 1 - inset),
         Fixtures.pixel(img, x: inset, y: img.height - 1 - inset)]
    }

    private func expect(_ got: [Fixtures.RGBA], _ want: [Fixtures.RGBA]) {
        for (g, w) in zip(got, want) { #expect(Fixtures.isClose(g, to: w), "got \(g), expected \(w)") }
    }

    @Test func transformMapsPreviewCornersToTileCorners() {
        let oriented = CGSize(width: 1200, height: 600)
        let previewSize = CGSize(width: 600, height: 300)
        let state = CropGeometry.fit(spec: spec, imageSize: oriented)
        let out = CGSize(width: 200, height: 200)
        let t0 = CropGeometry.previewToTile(state: state, spec: spec, index: 0, quarterTurns: .r0,
                                            orientedSize: oriented, previewSize: previewSize, outputSize: out)
        let t1 = CropGeometry.previewToTile(state: state, spec: spec, index: 1, quarterTurns: .r0,
                                            orientedSize: oriented, previewSize: previewSize, outputSize: out)
        func close(_ p: CGPoint, _ x: Double, _ y: Double) -> Bool { abs(p.x - x) < 1e-6 && abs(p.y - y) < 1e-6 }
        #expect(close(CGPoint(x: 0, y: 0).applying(t0), 0, 0))
        #expect(close(CGPoint(x: 300, y: 300).applying(t0), 200, 200))
        #expect(close(CGPoint(x: 300, y: 0).applying(t1), 0, 0))
        #expect(close(CGPoint(x: 600, y: 300).applying(t1), 200, 200))
    }

    @Test func unrotatedTilesShowTheRightQuadrants() throws {
        let left = try render(quarterTurns: .r0, outputWidth: 200, index: 0)
        let right = try render(quarterTurns: .r0, outputWidth: 200, index: 1)
        #expect(left.width == 200 && left.height == 200)
        expect(corners(left), [Fixtures.red, Fixtures.red, Fixtures.blue, Fixtures.blue])
        expect(corners(right), [Fixtures.green, Fixtures.green, Fixtures.white, Fixtures.white])
    }

    @Test func downscaledTilesKeepTheirCorners() throws {
        // Tile is 300 preview px wide, rendered at 60 px: exercises the Lanczos pre-shrink.
        let left = try render(quarterTurns: .r0, outputWidth: 60, index: 0)
        let right = try render(quarterTurns: .r0, outputWidth: 60, index: 1)
        expect(corners(left, inset: 3), [Fixtures.red, Fixtures.red, Fixtures.blue, Fixtures.blue])
        expect(corners(right, inset: 3), [Fixtures.green, Fixtures.green, Fixtures.white, Fixtures.white])
    }

    @Test func quarterTurnIsApplied() throws {
        // Turned 90° clockwise the image reads blue|red over white|green; the strip is the
        // middle band, which crosses the horizontal seam.
        let left = try render(quarterTurns: .r90, outputWidth: 200, index: 0)
        let right = try render(quarterTurns: .r90, outputWidth: 200, index: 1)
        expect(corners(left), [Fixtures.blue, Fixtures.blue, Fixtures.white, Fixtures.white])
        expect(corners(right), [Fixtures.red, Fixtures.red, Fixtures.green, Fixtures.green])
    }
}
