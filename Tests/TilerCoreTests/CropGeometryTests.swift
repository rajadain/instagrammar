import CoreGraphics
import Foundation
import Testing
@testable import TilerCore

// MARK: - Helpers

/// Deterministic RNG (SplitMix64) so the property test is reproducible.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func close(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool {
    abs(a - b) <= tol
}

private func close(_ p: CGPoint, _ q: CGPoint, _ tol: Double = 1e-6) -> Bool {
    abs(Double(p.x - q.x)) <= tol && abs(Double(p.y - q.y)) <= tol
}

private func allInside(_ pts: [CGPoint], _ size: CGSize, tol: Double = 1e-6) -> Bool {
    pts.allSatisfy {
        Double($0.x) >= -tol && Double($0.x) <= Double(size.width) + tol
            && Double($0.y) >= -tol && Double($0.y) <= Double(size.height) + tol
    }
}

private func degrees(_ d: Double) -> Double { d * .pi / 180 }

private let spec3x45 = TileSpec(aspect: .portrait4x5, count: 3)   // A = 2.4
private let wide = CGSize(width: 6000, height: 2000)

// MARK: - Tests

@Suite struct CropGeometryTests {

    // MARK: fit / maxWidth / minWidth

    @Test func fitWideImageIsHeightLimited() {
        let s = CropGeometry.fit(spec: spec3x45, imageSize: wide)
        #expect(close(s.height(for: spec3x45), 2000, 1e-9))
        #expect(close(s.width, 4800, 1e-9))
        #expect(s.center == CGPoint(x: 3000, y: 1000))
        #expect(s.angle == 0)
    }

    @Test func fitNarrowImageIsWidthLimited() {
        let size = CGSize(width: 3000, height: 3000)
        let s = CropGeometry.fit(spec: spec3x45, imageSize: size)
        #expect(close(s.width, 3000, 1e-9))
        #expect(close(s.height(for: spec3x45), 1250, 1e-9))
        #expect(s.center == CGPoint(x: 1500, y: 1500))
    }

    @Test func maxWidthAtZeroAnd45Degrees() {
        // 0°: min(W, H·A) = min(6000, 4800).
        #expect(close(CropGeometry.maxWidth(spec: spec3x45, angle: 0, imageSize: wide), 4800, 1e-9))
        // 45°: c = s = √2/2, both terms share the denominator (√2/2)(1 + 1/2.4) = 17√2/24,
        // so the limit is H / that = 48000 / (17√2) ≈ 1996.53.
        let expected45 = 48000 / (17 * 2.0.squareRoot())
        #expect(close(CropGeometry.maxWidth(spec: spec3x45, angle: degrees(45), imageSize: wide),
                      expected45, 1e-9))
        #expect(close(CropGeometry.maxWidth(spec: spec3x45, angle: degrees(-45), imageSize: wide),
                      expected45, 1e-9))
        // Square image, 1 square tile, 45°: the diagonal of the strip equals the side, w = W/√2.
        let sq = TileSpec(aspect: .square, count: 1)
        #expect(close(CropGeometry.maxWidth(spec: sq, angle: degrees(45),
                                            imageSize: CGSize(width: 1000, height: 1000)),
                      1000 / 2.0.squareRoot(), 1e-9))
    }

    @Test func minWidthIs100SourcePixelsPerTile() {
        #expect(CropGeometry.minWidth(spec: spec3x45, imageSize: wide) == 300)
        // Tiny image: the fit width is the floor.
        let tiny = CGSize(width: 200, height: 50)
        #expect(close(CropGeometry.minWidth(spec: spec3x45, imageSize: tiny), 120, 1e-9))
    }

    @Test func halfExtentsMatchCornerBoundingBox() {
        let s = CropState(center: CGPoint(x: 3000, y: 1000), width: 1500, angle: degrees(17))
        let (ex, ey) = CropGeometry.halfExtents(state: s, spec: spec3x45)
        let corners = CropGeometry.stripCorners(state: s, spec: spec3x45)
        let xs = corners.map { Double($0.x) }, ys = corners.map { Double($0.y) }
        #expect(close(xs.max()! - xs.min()!, 2 * ex, 1e-9))
        #expect(close(ys.max()! - ys.min()!, 2 * ey, 1e-9))
    }

    @Test func rotatingShrinksWidthAndKeepsCornersInside() {
        let s0 = CropGeometry.fit(spec: spec3x45, imageSize: wide)
        let s10 = CropGeometry.clamp(CropGeometry.rotated(s0, toAngle: degrees(10)),
                                     spec: spec3x45, imageSize: wide)
        #expect(s10.width < s0.width)
        #expect(close(s10.width, CropGeometry.maxWidth(spec: spec3x45, angle: degrees(10), imageSize: wide)))
        #expect(allInside(CropGeometry.stripCorners(state: s10, spec: spec3x45), wide))
        // Rotating with fit directly agrees.
        let f10 = CropGeometry.fit(spec: spec3x45, imageSize: wide, angle: degrees(10))
        #expect(close(f10.width, s10.width))
    }

    // MARK: clamp

    @Test func clampPullsOutOfBoundsStateInside() {
        let bad = CropState(center: CGPoint(x: -500, y: 9000), width: 99999, angle: degrees(-30))
        let c = CropGeometry.clamp(bad, spec: spec3x45, imageSize: wide)
        #expect(allInside(CropGeometry.stripCorners(state: c, spec: spec3x45), wide))
        #expect(c.angle == bad.angle)
        // Too small a width is raised to the minimum.
        let small = CropState(center: CGPoint(x: 3000, y: 1000), width: 10, angle: 0)
        #expect(CropGeometry.clamp(small, spec: spec3x45, imageSize: wide).width == 300)
    }

    @Test func clampIsIdempotent() {
        let s = CropState(center: CGPoint(x: 5900, y: 50), width: 3000, angle: degrees(22))
        let once = CropGeometry.clamp(s, spec: spec3x45, imageSize: wide)
        let twice = CropGeometry.clamp(once, spec: spec3x45, imageSize: wide)
        #expect(once == twice)
    }

    @Test func clampPropertyRandomStatesStayInside() {
        var rng = SplitMix64(seed: 0xC0FFEE)
        let aspects: [AspectRatio] = [.portrait4x5, .portrait3x4, .square, .landscape191]
        for _ in 0..<1000 {
            let size = CGSize(width: Double.random(in: 150...12000, using: &rng).rounded(),
                              height: Double.random(in: 150...12000, using: &rng).rounded())
            let aspect = Bool.random(using: &rng)
                ? aspects.randomElement(using: &rng)!
                : AspectRatio(width: Double.random(in: 0.3...3, using: &rng), height: 1)
            let spec = TileSpec(aspect: aspect, count: Int.random(in: 1...20, using: &rng))
            let state = CropState(
                center: CGPoint(x: Double.random(in: -size.width...(2 * size.width), using: &rng),
                                y: Double.random(in: -size.height...(2 * size.height), using: &rng)),
                width: Double.random(in: 1...(3 * max(size.width, size.height)), using: &rng),
                angle: degrees(Double.random(in: -45...45, using: &rng)))

            let c = CropGeometry.clamp(state, spec: spec, imageSize: size)
            let corners = CropGeometry.stripCorners(state: c, spec: spec)
            #expect(allInside(corners, size), "state \(state) spec \(spec) size \(size) -> \(c)")
            #expect(CropGeometry.clamp(c, spec: spec, imageSize: size) == c)
            #expect(c.width > 0)
            #expect(c.angle == state.angle)
            for i in 0..<spec.count {
                #expect(allInside(CropGeometry.tileCorners(state: c, spec: spec, index: i), size))
            }
        }
    }

    // MARK: respec

    @Test func respecKeepsHeightWhenItFits() {
        let size = CGSize(width: 9000, height: 2000)
        let s3 = CropGeometry.fit(spec: spec3x45, imageSize: size)
        let spec4 = TileSpec(aspect: .portrait4x5, count: 4)
        let s4 = CropGeometry.respec(s3, from: spec3x45, to: spec4, imageSize: size)
        #expect(close(s4.height(for: spec4), 2000))
        #expect(close(s4.width, 6400))
        #expect(s4.center == s3.center)
        #expect(s4.angle == s3.angle)
    }

    @Test func respecShrinksHeightWhenItDoesNotFit() {
        let s3 = CropGeometry.fit(spec: spec3x45, imageSize: wide)
        let spec4 = TileSpec(aspect: .portrait4x5, count: 4)  // A = 3.2, wants w = 6400 > 6000
        let s4 = CropGeometry.respec(s3, from: spec3x45, to: spec4, imageSize: wide)
        #expect(close(s4.width, 6000))
        #expect(close(s4.height(for: spec4), 1875))
        #expect(allInside(CropGeometry.stripCorners(state: s4, spec: spec4), wide))
    }

    // MARK: sizes

    @Test func nativeTilePixelSize() {
        let s = CropGeometry.fit(spec: spec3x45, imageSize: wide)
        let n = CropGeometry.nativeTilePixelSize(state: s, spec: spec3x45)
        #expect(n.width == 1600 && n.height == 2000)

        let odd = CropState(center: .zero, width: 1000, angle: 0)
        let n2 = CropGeometry.nativeTilePixelSize(state: odd, spec: spec3x45)
        #expect(n2.width == 333 && n2.height == 416)   // floor(333 / 0.8) = 416

        let ls = TileSpec(aspect: .landscape191, count: 2)
        let n3 = CropGeometry.nativeTilePixelSize(state: CropState(center: .zero, width: 3820), spec: ls)
        #expect(n3.width == 1910 && n3.height == 1000)
    }

    // MARK: transforms

    @Test func sToViewMapsStripToStripRect() {
        let state = CropState(center: CGPoint(x: 2800, y: 1100), width: 2500, angle: degrees(7))
        let view = CGSize(width: 1000, height: 700)
        let m = CropGeometry.sToView(state: state, spec: spec3x45, viewSize: view, padding: 24)
        let r = m.stripRect
        let expected = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                        CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        let mapped = CropGeometry.stripCorners(state: state, spec: spec3x45).map { $0.applying(m.transform) }
        for (p, q) in zip(mapped, expected) { #expect(close(p, q)) }

        // Centred, and fills the view minus padding on the limiting axis.
        #expect(close(Double(r.midX), 500) && close(Double(r.midY), 350))
        #expect(close(Double(r.width), 1000 - 48, 1e-9) || close(Double(r.height), 700 - 48, 1e-9))
        #expect(Double(r.width) <= 1000 - 48 + 1e-9 && Double(r.height) <= 700 - 48 + 1e-9)
        #expect(close(m.viewScale, Double(r.width) / state.width))

        // Point round-trip through the inverse.
        let inv = m.transform.inverted()
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 6000, y: 2000), CGPoint(x: 1234.5, y: 77)] {
            #expect(close(p.applying(m.transform).applying(inv), p, 1e-6))
        }
    }

    @Test func sToTileMapsTileCornersToOutputRect() {
        let state = CropState(center: CGPoint(x: 3100, y: 950), width: 3000, angle: degrees(-12))
        let spec = TileSpec(aspect: .portrait4x5, count: 4)
        for k in [1.0, 0.5, 0.37] {
            let outW = k * state.width / 4, outH = k * state.height(for: spec)
            let expected = [CGPoint(x: 0, y: 0), CGPoint(x: outW, y: 0),
                            CGPoint(x: outW, y: outH), CGPoint(x: 0, y: outH)]
            for i in 0..<spec.count {
                let t = CropGeometry.sToTile(state: state, spec: spec, index: i, scale: k)
                let mapped = CropGeometry.tileCorners(state: state, spec: spec, index: i).map { $0.applying(t) }
                for (p, q) in zip(mapped, expected) { #expect(close(p, q, 1e-6)) }
                // Tile centre goes to the output centre.
                let c = CropGeometry.tileCenter(state: state, spec: spec, index: i).applying(t)
                #expect(close(c, CGPoint(x: outW / 2, y: outH / 2), 1e-6))
            }
        }
    }

    @Test func sToTileOutputSizeMapsTileCornersToIntegerRect() {
        let state = CropState(center: CGPoint(x: 3000, y: 1000), width: 4001.7, angle: degrees(3))
        let spec = TileSpec(aspect: .portrait4x5, count: 3)
        let s = CropGeometry.clamp(state, spec: spec, imageSize: wide)
        let n = CropGeometry.nativeTilePixelSize(state: s, spec: spec)
        let out = CGSize(width: n.width, height: n.height)
        let expected = [CGPoint(x: 0, y: 0), CGPoint(x: out.width, y: 0),
                        CGPoint(x: out.width, y: out.height), CGPoint(x: 0, y: out.height)]
        for i in 0..<spec.count {
            let t = CropGeometry.sToTile(state: s, spec: spec, index: i, outputSize: out)
            let mapped = CropGeometry.tileCorners(state: s, spec: spec, index: i).map { $0.applying(t) }
            for (p, q) in zip(mapped, expected) { #expect(close(p, q, 1e-6)) }
        }
    }

    @Test func seamsBetweenAdjacentTilesShareTheSameSourceLine() {
        let state = CropState(center: CGPoint(x: 3000, y: 1000), width: 1700, angle: degrees(31))
        let spec = TileSpec(aspect: .square, count: 5)
        let k = 0.8
        let outW = k * state.width / 5, outH = k * state.height(for: spec)
        for i in 0..<(spec.count - 1) {
            let a = CropGeometry.tileCorners(state: state, spec: spec, index: i)
            let b = CropGeometry.tileCorners(state: state, spec: spec, index: i + 1)
            #expect(close(a[1], b[0]) && close(a[2], b[3]))   // TR == next TL, BR == next BL

            let invA = CropGeometry.sToTile(state: state, spec: spec, index: i, scale: k).inverted()
            let invB = CropGeometry.sToTile(state: state, spec: spec, index: i + 1, scale: k).inverted()
            for f in [0.0, 0.25, 0.5, 0.9, 1.0] {
                let y = f * outH
                let pa = CGPoint(x: outW, y: y).applying(invA)   // right edge of tile i
                let pb = CGPoint(x: 0, y: y).applying(invB)      // left edge of tile i+1
                #expect(close(pa, pb, 1e-6))
            }
        }
    }

    @Test func tileTransformsAgreeWithViewTransform() {
        // A tile pixel and the canvas must show the same source point: the view position of
        // tile i's top-left corner is the strip rect's left edge plus i tile widths.
        let state = CropState(center: CGPoint(x: 2500, y: 900), width: 2000, angle: degrees(-8))
        let m = CropGeometry.sToView(state: state, spec: spec3x45,
                                     viewSize: CGSize(width: 1200, height: 800), padding: 10)
        let tileViewW = Double(m.stripRect.width) / 3
        for i in 0..<3 {
            let tl = CropGeometry.tileCorners(state: state, spec: spec3x45, index: i)[0].applying(m.transform)
            #expect(close(tl, CGPoint(x: Double(m.stripRect.minX) + Double(i) * tileViewW,
                                      y: Double(m.stripRect.minY)), 1e-6))
        }
    }

    // MARK: interaction helpers

    @Test func zoomedKeepsAnchorFixedOnScreen() {
        let state = CropState(center: CGPoint(x: 3000, y: 1000), width: 3000, angle: degrees(14))
        let view = CGSize(width: 1000, height: 600)
        let anchor = CGPoint(x: 3400, y: 820)
        for factor in [1.25, 0.8, 2.0] {
            let z = CropGeometry.zoomed(state, factor: factor, anchorInS: anchor)
            #expect(close(z.width, state.width / factor))
            let before = anchor.applying(CropGeometry.sToView(state: state, spec: spec3x45,
                                                              viewSize: view, padding: 20).transform)
            let after = anchor.applying(CropGeometry.sToView(state: z, spec: spec3x45,
                                                             viewSize: view, padding: 20).transform)
            #expect(close(before, after, 1e-6))
        }
    }

    @Test func pannedMovesCentreOppositeToDragInRotatedFrame() {
        let angle = degrees(20)
        let state = CropState(center: CGPoint(x: 3000, y: 1000), width: 3000, angle: angle)
        let view = CGSize(width: 1000, height: 600)
        let m = CropGeometry.sToView(state: state, spec: spec3x45, viewSize: view, padding: 20)
        let delta = CGVector(dx: 30, dy: -12)
        let p = CropGeometry.panned(state, byViewDelta: delta, viewScale: m.viewScale)

        let expectedShift = CropGeometry.rotate(
            CGPoint(x: -30 / m.viewScale, y: 12 / m.viewScale), by: angle)
        #expect(close(CGPoint(x: p.center.x - state.center.x, y: p.center.y - state.center.y),
                      expectedShift, 1e-9))
        #expect(p.width == state.width && p.angle == state.angle)

        // The image follows the cursor: whatever was under view point v is now under v + Δ.
        let m2 = CropGeometry.sToView(state: p, spec: spec3x45, viewSize: view, padding: 20)
        for s in [CGPoint(x: 2900, y: 1100), CGPoint(x: 100, y: 1900)] {
            let v1 = s.applying(m.transform), v2 = s.applying(m2.transform)
            #expect(close(CGPoint(x: v2.x - v1.x, y: v2.y - v1.y), CGPoint(x: 30, y: -12), 1e-6))
        }
    }

    @Test func rotatedOnlyChangesAngle() {
        let s = CropState(center: CGPoint(x: 10, y: 20), width: 300, angle: 0)
        let r = CropGeometry.rotated(s, toAngle: 0.3)
        #expect(r.center == s.center && r.width == s.width && r.angle == 0.3)
    }

    // MARK: straighten sign convention (PLAN §3.2)

    @Test func straightenConversion() {
        #expect(close(CropState.angle(forStraightenDegrees: 10), -10 * .pi / 180))
        var s = CropState(center: .zero, width: 100, angle: 0)
        s.straightenDegrees = -7.5
        #expect(close(s.angle, 7.5 * .pi / 180))
        #expect(close(s.straightenDegrees, -7.5))
    }

    @Test func positiveStraightenTurnsImageClockwiseOnScreen() {
        let view = CGSize(width: 1200, height: 600)
        let marker = CGPoint(x: 5900, y: 100)         // top-right of the source
        let bottomLeft = CGPoint(x: 100, y: 1900)     // bottom-left of the source

        let s0 = CropGeometry.fit(spec: spec3x45, imageSize: wide)
        let m0 = CropGeometry.sToView(state: s0, spec: spec3x45, viewSize: view, padding: 0)

        // Same strip, only the angle changes (σ = +10°): the top-right marker moves down and the
        // bottom-left marker moves up on screen, i.e. the image turns clockwise.
        let r = CropGeometry.rotated(s0, toAngle: CropState.angle(forStraightenDegrees: 10))
        let mr = CropGeometry.sToView(state: r, spec: spec3x45, viewSize: view, padding: 0)
        #expect(marker.applying(mr.transform).y > marker.applying(m0.transform).y)
        #expect(bottomLeft.applying(mr.transform).y < bottomLeft.applying(m0.transform).y)

        // Still true after clamping (auto-zoom) as the app would do it.
        let c = CropGeometry.clamp(r, spec: spec3x45, imageSize: wide)
        let mc = CropGeometry.sToView(state: c, spec: spec3x45, viewSize: view, padding: 0)
        #expect(marker.applying(mc.transform).y > marker.applying(m0.transform).y)

        // And σ = −10° turns it the other way.
        let l = CropGeometry.rotated(s0, toAngle: CropState.angle(forStraightenDegrees: -10))
        let ml = CropGeometry.sToView(state: l, spec: spec3x45, viewSize: view, padding: 0)
        #expect(marker.applying(ml.transform).y < marker.applying(m0.transform).y)
    }
}
