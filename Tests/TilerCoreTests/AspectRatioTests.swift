import Foundation
import Testing
@testable import TilerCore

@Suite struct AspectRatioTests {
    @Test func presetValues() {
        #expect(AspectRatio.portrait4x5.value == 0.8)
        #expect(AspectRatio.portrait3x4.value == 0.75)
        #expect(AspectRatio.square.value == 1)
        #expect(AspectRatio.landscape191.value == 1.91)
        #expect(AspectRatio.landscape191 == AspectRatio(width: 1.91, height: 1))
    }

    @Test func presetMapping() {
        let custom = AspectRatio(width: 7, height: 3)
        #expect(AspectPreset.portrait4x5.aspect(custom: custom) == .portrait4x5)
        #expect(AspectPreset.portrait3x4.aspect(custom: custom) == .portrait3x4)
        #expect(AspectPreset.square.aspect(custom: custom) == .square)
        #expect(AspectPreset.landscape191.aspect(custom: custom) == .landscape191)
        #expect(AspectPreset.custom.aspect(custom: custom) == custom)
    }

    @Test func displayNames() {
        #expect(AspectPreset.portrait4x5.displayName == "Portrait 4:5")
        #expect(AspectPreset.portrait3x4.displayName == "Portrait 3:4")
        #expect(AspectPreset.square.displayName == "Square 1:1")
        #expect(AspectPreset.landscape191.displayName == "Landscape 1.91:1")
        #expect(AspectPreset.custom.displayName == "Custom")
        #expect(AspectPreset.allCases.count == 5)
        #expect(AspectPreset.allCases.first == .portrait3x4)
    }

    @Test func validity() {
        #expect(AspectRatio.portrait4x5.isValid)
        #expect(!AspectRatio(width: 0, height: 1).isValid)
        #expect(!AspectRatio(width: 1, height: -2).isValid)
        #expect(!AspectRatio(width: .nan, height: 1).isValid)
    }

    @Test func stripAspect() {
        #expect(abs(TileSpec(aspect: .portrait4x5, count: 3).stripAspect - 2.4) < 1e-12)
        #expect(TileSpec(aspect: .square, count: 20).stripAspect == 20)
    }

    @Test func countIsClampedOnInit() {
        #expect(TileSpec(aspect: .square, count: 0).count == 1)
        #expect(TileSpec(aspect: .square, count: 25).count == 20)
        #expect(TileSpec(aspect: .square, count: 7).count == 7)
    }

    @Test func codableRoundTrip() throws {
        let spec = TileSpec(aspect: AspectRatio(width: 2.5, height: 1), count: 4)
        let data = try JSONEncoder().encode(spec)
        #expect(try JSONDecoder().decode(TileSpec.self, from: data) == spec)

        let preset = AspectPreset.landscape191
        let pdata = try JSONEncoder().encode(preset)
        #expect(try JSONDecoder().decode(AspectPreset.self, from: pdata) == preset)
    }
}

@Test func straightenDegreesAtZeroIsPositiveZero() {
    let s = CropState(center: .zero, width: 100, angle: 0)
    #expect(s.straightenDegrees.sign == .plus)
}
