import CoreGraphics
import Foundation
import Testing
@testable import TilerCore

@Suite struct FileNameTests {
    @Test func unpaddedBelowTen() {
        #expect(fileName(stem: "IMG_1234", index: 0, count: 3) == "IMG_1234-tile-1.jpg")
        #expect(fileName(stem: "IMG_1234", index: 2, count: 3) == "IMG_1234-tile-3.jpg")
        #expect(fileName(stem: "IMG_1234", index: 8, count: 9) == "IMG_1234-tile-9.jpg")
    }

    @Test func paddedFromTen() {
        #expect(fileName(stem: "IMG_1234", index: 0, count: 10) == "IMG_1234-tile-01.jpg")
        #expect(fileName(stem: "IMG_1234", index: 9, count: 10) == "IMG_1234-tile-10.jpg")
        #expect(fileName(stem: "IMG_1234", index: 19, count: 20) == "IMG_1234-tile-20.jpg")
    }

    @Test func stemIsKeptAsIs() {
        #expect(fileName(stem: "my-photo 1", index: 0, count: 2) == "my-photo 1-tile-1.jpg")
        #expect(fileName(stem: "DSCF4669 95", index: 1, count: 3) == "DSCF4669 95-tile-2.jpg")
        #expect(fileName(stem: "a.b-c", index: 4, count: 12) == "a.b-c-tile-05.jpg")
    }

    @Test func paddedNamesSortInTileOrder() {
        let names = (0..<12).map { fileName(stem: "x", index: $0, count: 12) }
        #expect(names.sorted() == names)
    }
}

@Suite struct OutputSizeTests {
    let native = (width: 2000, height: 2500)

    @Test func nativeIsUnchanged() {
        let s = OutputSize.native.pixelSize(native: native, aspect: .portrait4x5)
        #expect(s == (2000, 2500))
    }

    @Test func presetsDeriveHeightFromAspect() {
        let p1440 = OutputSize.width(1440).pixelSize(native: native, aspect: .portrait4x5)
        #expect(p1440 == (1440, 1800))
        let p1080 = OutputSize.width(1080).pixelSize(native: native, aspect: .portrait4x5)
        #expect(p1080 == (1080, 1350))
        let sq = OutputSize.width(1080).pixelSize(native: (3000, 3000), aspect: .square)
        #expect(sq == (1080, 1080))
        let p34 = OutputSize.width(1080).pixelSize(native: (3000, 4000), aspect: .portrait3x4)
        #expect(p34 == (1080, 1440))
        // 1080 / 1.91 = 565.4 → 565.
        let land = OutputSize.width(1080).pixelSize(native: (3000, 1570), aspect: .landscape191)
        #expect(land == (1080, 565))
    }

    @Test func neverUpscales() {
        // 2160 > native 2000: clamps to native exactly.
        let s = OutputSize.width(2160).pixelSize(native: native, aspect: .portrait4x5)
        #expect(s == (2000, 2500))
        // Equal to native width: native exactly (height not re-derived, so floor rounding wins).
        let odd = OutputSize.width(1999).pixelSize(native: (1999, 2498), aspect: .portrait4x5)
        #expect(odd == (1999, 2498))
        // Height never exceeds native height either.
        let tall = OutputSize.width(1998).pixelSize(native: (1999, 2498), aspect: .portrait4x5)
        #expect(tall.width == 1998 && tall.height <= 2498)
        // Nonsense widths stay positive.
        #expect(OutputSize.width(0).pixelSize(native: native, aspect: .portrait4x5).width == 1)
    }

    @Test func availability() {
        #expect(isAvailable(.native, native: native))
        #expect(isAvailable(.width(2000), native: native))
        #expect(!isAvailable(.width(2001), native: native))
        #expect(!isAvailable(.width(2160), native: native))
        #expect(isAvailable(.width(1440), native: native))
        #expect(isAvailable(.width(1080), native: native))
        #expect(!isAvailable(.width(0), native: native))
        let available = OutputSize.presets.filter { isAvailable($0, native: (1200, 1500)) }
        #expect(available == [.native, .width(1080)])
    }

    @Test func settingsClampQuality() {
        #expect(ExportSettings(quality: 0.1).quality == 0.5)
        #expect(ExportSettings(quality: 2).quality == 1.0)
        #expect(ExportSettings().size == .native && ExportSettings().quality == 1.0)
    }
}

@Suite struct PlanTests {
    @Test func planListsEveryTileWithIdenticalSize() {
        let spec = TileSpec(aspect: .portrait4x5, count: 3)
        let state = CropGeometry.fit(spec: spec, imageSize: CGSize(width: 6000, height: 4000))
        let outputs = plan(state: state, spec: spec, quarterTurns: .r0,
                           settings: ExportSettings(), stem: "IMG_1")
        #expect(outputs.count == 3)
        #expect(outputs.map(\.index) == [0, 1, 2])
        #expect(outputs.map(\.fileName) == ["IMG_1-tile-1.jpg", "IMG_1-tile-2.jpg", "IMG_1-tile-3.jpg"])
        let native = CropGeometry.nativeTilePixelSize(state: state, spec: spec)
        for o in outputs {
            #expect(o.pixelWidth == native.width && o.pixelHeight == native.height)
        }
        #expect(native == (2000, 2500))
    }

    @Test func planWithPresetAndPadding() {
        let spec = TileSpec(aspect: .square, count: 12)
        let state = CropGeometry.fit(spec: spec, imageSize: CGSize(width: 24000, height: 2000))
        let outputs = plan(state: state, spec: spec, settings: ExportSettings(size: .width(1080)),
                           stem: "pano")
        #expect(outputs.count == 12)
        #expect(outputs.first?.fileName == "pano-tile-01.jpg")
        #expect(outputs.last?.fileName == "pano-tile-12.jpg")
        #expect(outputs.allSatisfy { $0.pixelWidth == 1080 && $0.pixelHeight == 1080 })
    }

    @Test func planNeverUpscales() {
        let spec = TileSpec(aspect: .portrait4x5, count: 3)
        let state = CropGeometry.fit(spec: spec, imageSize: CGSize(width: 1200, height: 500))
        let outputs = plan(state: state, spec: spec, settings: ExportSettings(size: .width(1080)), stem: "s")
        #expect(outputs.allSatisfy { $0.pixelWidth == 400 && $0.pixelHeight == 500 })
    }
}
