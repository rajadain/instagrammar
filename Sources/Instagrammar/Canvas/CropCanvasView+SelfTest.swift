#if DEBUG
import AppKit
import ImageIO
import TilerCore
import UniformTypeIdentifiers

/// DEBUG-only canvas self-check, for agents that can't drive gestures or see the window.
///
/// Run a debug build with `INSTAGRAMMAR_CANVAS_SELFTEST=1 .build/debug/Instagrammar <image>`.
/// Once the image is on screen the canvas drives its own handlers (and synthesized mouse and
/// key events), checks the results against `CropGeometry`, logs `PASS`/`FAIL` lines to stderr
/// and exits with status 0 (all passed) or 1. Set `INSTAGRAMMAR_CANVAS_SNAPSHOT_DIR` to also
/// save PNG captures of the app's own window at a few stages.
extension CropCanvasView {
    static let selfTestRequested =
        ProcessInfo.processInfo.environment["INSTAGRAMMAR_CANVAS_SELFTEST"] == "1"

    func startSelfTestIfRequested() {
        guard Self.selfTestRequested || Self.undoSelfTestRequested,
              !selfTestStarted, mapping != nil, window != nil else { return }
        if Self.undoSelfTestRequested { return startUndoSelfTest() }
        selfTestStarted = true
        Task { @MainActor in
            let ok = await CanvasSelfTest(view: self).run()
            FileHandle.standardError.write(Data("CANVAS SELFTEST \(ok ? "PASS" : "FAIL")\n".utf8))
            exit(ok ? 0 : 1)
        }
    }
}

@MainActor
private final class CanvasSelfTest {
    let view: CropCanvasView
    var failures = 0

    init(view: CropCanvasView) { self.view = view }

    func log(_ s: String) { FileHandle.standardError.write(Data("[selftest] \(s)\n".utf8)) }

    func check(_ ok: Bool, _ what: String) {
        log("\(ok ? "PASS" : "FAIL"): \(what)")
        if !ok { failures += 1 }
    }

    func close(_ a: CGPoint, _ b: CGPoint, _ tol: Double = 0.01) -> Bool {
        abs(Double(a.x - b.x)) <= tol && abs(Double(a.y - b.y)) <= tol
    }

    func fmt(_ p: CGPoint) -> String { String(format: "(%.3f, %.3f)", Double(p.x), Double(p.y)) }

    var m: CropGeometry.ViewMapping { view.mapping! }

    /// All strip corners inside the image and the crop is a fixed point of `clamp` (P6).
    func checkValid(_ label: String) {
        let size = view.imageSize, c = view.crop, tol = 1e-6
        let corners = CropGeometry.stripCorners(state: c, spec: view.spec)
        let inside = corners.allSatisfy {
            Double($0.x) >= -tol && Double($0.x) <= Double(size.width) + tol
                && Double($0.y) >= -tol && Double($0.y) <= Double(size.height) + tol
        }
        let clamped = CropGeometry.clamp(c, spec: view.spec, imageSize: size)
        let fixed = abs(clamped.width - c.width) < 1e-6
            && close(clamped.center, c.center, 1e-6) && clamped.angle == c.angle
        check(inside && fixed && abs(c.straightenDegrees) <= 45 + 1e-9,
              "\(label): crop valid (corners inside \(Int(size.width))×\(Int(size.height)), clamp fixed point, |σ| ≤ 45; σ=\(String(format: "%.3f", c.straightenDegrees)) w=\(String(format: "%.1f", c.width)))")
    }

    func sleep(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    // MARK: Synthesized events

    func mouse(_ type: NSEvent.EventType, at p: CGPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: view.window!.windowNumber, context: nil,
                           eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    func key(_ chars: String, keyCode: UInt16, shift: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [],
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: view.window!.windowNumber, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: keyCode)!
    }

    // MARK: Run

    func run() async -> Bool {
        await sleep(600)   // Let the window settle and render once.
        guard let preview = view.preview, view.mapping != nil else {
            check(false, "canvas has a preview and a mapping")
            return false
        }
        log("view \(Int(view.bounds.width))×\(Int(view.bounds.height)) pt, backing scale \(view.window?.backingScaleFactor ?? 0), preview \(preview.width)×\(preview.height), oriented \(Int(view.orientedSize.width))×\(Int(view.orientedSize.height)), quarterTurns \(view.quarterTurns)")
        log("backing layer geometryFlipped=\(view.layer?.isGeometryFlipped ?? false), contentLayer geometryFlipped=\(view.contentLayer.isGeometryFlipped), contentLayer contentsAreFlipped=\(view.contentLayer.contentsAreFlipped())")
        await snapshot("1-initial")
        checkValid("initial")

        // (0) The image layer's real CALayer geometry puts preview pixel corners where
        // CropGeometry says (validates anchor/position/bounds + setAffineTransform).
        checkLayerTransform("initial")

        // (1) Zoom ×1.5 about an off-centre point: the image point under it stays put.
        let q = CGPoint(x: m.stripRect.midX + m.stripRect.width * 0.2,
                        y: m.stripRect.midY + m.stripRect.height * 0.1)
        let sq = q.applying(m.transform.inverted())
        let w0 = view.crop.width
        view.handleZoom(factor: 1.5, atViewPoint: q)
        check(abs(view.crop.width - w0 / 1.5) < 1e-6, "zoom ×1.5: width \(w0) → \(view.crop.width)")
        let qAfter = sq.applying(m.transform)
        check(close(qAfter, q), "zoom keeps anchor under cursor: \(fmt(q)) → \(fmt(qAfter))")
        checkValid("after zoom")

        // (2) Pan by a synthesized mouse drag of Δ: whatever was under the start point is now
        // under start + Δ (exercises the flipped event → view conversion too).
        let p = CGPoint(x: m.stripRect.midX - 40, y: m.stripRect.midY + 15)
        let sp = p.applying(m.transform.inverted())
        let delta = CGVector(dx: 30, dy: -20)
        let mid = CGPoint(x: p.x + delta.dx / 2, y: p.y + delta.dy / 2)
        let end = CGPoint(x: p.x + delta.dx, y: p.y + delta.dy)
        view.mouseDown(with: mouse(.leftMouseDown, at: p))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: mid))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: end))
        view.mouseUp(with: mouse(.leftMouseUp, at: end))
        let spAfter = sp.applying(m.transform)
        check(close(spAfter, end), "drag Δ=(30,−20): point under start now at \(fmt(spAfter)), expected \(fmt(end))")
        checkValid("after pan")
        checkLayerTransform("after pan")

        // (3) Trackpad rotation, fingers counter-clockwise 4 × 5°: the image turns
        // counter-clockwise on screen (σ = −20°), i.e. the image layer's on-screen rotation
        // (atan2(b, a) in y-down = clockwise-positive) is −20° at quarter turn 0.
        let before = view.crop
        let marker = CropGeometry.stripToS(CGPoint(x: before.width * 0.3, y: 0), state: before)
        let markerBefore = marker.applying(m.transform)
        view.beginRotateGesture()
        for _ in 0..<4 { view.handleRotate(counterClockwiseDegrees: 5) }
        check(abs(view.crop.straightenDegrees - (before.straightenDegrees - 20)) < 1e-9,
              "rotate fingers CCW 20°: σ \(before.straightenDegrees) → \(view.crop.straightenDegrees)")
        let t = view.imageLayer.affineTransform()
        let screenDeg = atan2(Double(t.b), Double(t.a)) * 180 / .pi
        let expectedDeg = -20.0 + Double(view.quarterTurns.rawValue) * 90
        var diff = (screenDeg - expectedDeg).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff -= 360 } else if diff < -180 { diff += 360 }
        check(abs(diff) < 1e-6, "image layer on-screen rotation \(String(format: "%.3f", screenDeg))° (expected \(expectedDeg)°, negative = counter-clockwise)")
        let markerAfter = marker.applying(m.transform)
        check(markerAfter.y < markerBefore.y, "marker right of centre moves up on screen: y \(String(format: "%.1f", markerBefore.y)) → \(String(format: "%.1f", markerAfter.y))")
        checkValid("after rotate 20°")
        checkLayerTransform("after rotate")
        await snapshot("2-rotated-ccw20")

        // Past the limit: σ stops at −45.
        for _ in 0..<8 { view.handleRotate(counterClockwiseDegrees: 5) }
        check(abs(view.crop.straightenDegrees + 45) < 1e-9, "rotation stops at σ = −45 (σ = \(view.crop.straightenDegrees))")
        checkValid("at −45°")
        await snapshot("3-rotated-limit")

        // Back to the start angle within the same gesture restores the zoom and position.
        for _ in 0..<9 { view.handleRotate(counterClockwiseDegrees: -5) }
        view.endRotateGesture()
        check(abs(view.crop.straightenDegrees - before.straightenDegrees) < 1e-9
                && abs(view.crop.width - before.width) < 1e-6
                && close(view.crop.center, before.center, 1e-6),
              "rotating back within one gesture restores width/centre (w \(before.width) → \(view.crop.width))")
        checkValid("after rotate back")

        // (4) Keyboard: '.' +0.1°, '>' (⇧.) +1°, ',' −0.1° → σ = +1.0; → arrow pans 1 pt.
        let sigma0 = view.crop.straightenDegrees
        view.keyDown(with: key(".", keyCode: 47))
        view.keyDown(with: key(">", keyCode: 47, shift: true))
        view.keyDown(with: key(",", keyCode: 43))
        check(abs(view.crop.straightenDegrees - (sigma0 + 1)) < 1e-9, "keys . ⇧. , → σ \(sigma0) → \(view.crop.straightenDegrees)")
        let k = CGPoint(x: m.stripRect.midX, y: m.stripRect.midY)
        let sk = k.applying(m.transform.inverted())
        let right = String(Character(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!))
        view.keyDown(with: key(right, keyCode: 124))
        check(close(sk.applying(m.transform), CGPoint(x: k.x + 1, y: k.y)), "→ moves the image 1 pt right")
        let wBeforePlus = view.crop.width
        view.keyDown(with: key("=", keyCode: 24))
        check(abs(view.crop.width - wBeforePlus / 1.1) < 1e-6, "'+' zooms in ×1.1")
        checkValid("after keys")

        // (5) Double-click resets to fit at the current angle.
        let angle = view.crop.angle
        let dc = CGPoint(x: m.stripRect.midX, y: m.stripRect.midY)
        view.mouseDown(with: mouse(.leftMouseDown, at: dc, clicks: 2))
        view.mouseUp(with: mouse(.leftMouseUp, at: dc, clicks: 2))
        let fit = CropGeometry.fit(spec: view.spec, imageSize: view.imageSize, angle: angle)
        check(view.crop == fit, "double-click → fit at current angle (σ \(String(format: "%.3f", view.crop.straightenDegrees)))")

        // (6) The model clamps to the same value and it flows back through updateNSView.
        await sleep(300)
        check(view.lastExternalCrop == view.crop, "model round-trip: updateNSView crop == canvas crop")
        await sleep(900)   // Overlays fade out.
        await snapshot("4-final")

        // (7) Quarter turns through the model: the layer transform still matches CropGeometry
        // and the crop is valid for every turn.
        for i in 1...4 {
            AppModel.shared.rotateRight()
            await sleep(250)
            check(view.quarterTurns.rawValue == i % 4, "quarter turn \(i): canvas received \(view.quarterTurns)")
            checkLayerTransform("quarter turn \(view.quarterTurns)")
            checkValid("quarter turn \(view.quarterTurns)")
            if i == 1 { await snapshot("5-r90") }
        }

        log("\(failures) failure(s)")
        return failures == 0
    }

    func checkLayerTransform(_ label: String) {
        guard let preview = view.preview else { return }
        let pw = CGFloat(preview.width), ph = CGFloat(preview.height)
        let toS = CropGeometry.previewToS(previewSize: CGSize(width: pw, height: ph),
                                          orientedSize: view.orientedSize, quarterTurns: view.quarterTurns)
        var ok = true
        var worst = 0.0
        for c in [CGPoint(x: 0, y: 0), CGPoint(x: pw, y: 0), CGPoint(x: pw, y: ph), CGPoint(x: 0, y: ph),
                  CGPoint(x: pw / 3, y: ph / 4)] {
            let viaLayer = view.imageLayer.convert(c, to: view.contentLayer)
            let expected = c.applying(toS).applying(m.transform)
            worst = max(worst, Double(hypot(viaLayer.x - expected.x, viaLayer.y - expected.y)))
            ok = ok && close(viaLayer, expected, 0.01)
        }
        check(ok, "\(label): CALayer maps preview corners to sToView points (worst error \(String(format: "%.4f", worst)) pt)")
    }

    // MARK: Snapshot of our own window

    /// Captures the app's own window (no Screen Recording permission is needed for that) via
    /// `CGWindowListCreateImage`, looked up at runtime because the macOS 15 SDK marks it obsolete.
    func snapshot(_ name: String) async {
        guard let dir = ProcessInfo.processInfo.environment["INSTAGRAMMAR_CANVAS_SNAPSHOT_DIR"],
              let window = view.window else { return }
        await sleep(250)   // Let Core Animation commit and the window server composite.
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "CGWindowListCreateImage") else {
            log("snapshot \(name): CGWindowListCreateImage unavailable")
            return
        }
        let fn = unsafeBitCast(sym, to: Fn.self)
        // kCGWindowListOptionIncludingWindow = 8; kCGWindowImageBoundsIgnoreFraming | BestResolution = 1 | 8.
        guard let image = fn(.null, 8, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue() else {
            log("snapshot \(name): capture failed")
            return
        }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("canvas-\(name).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        log("snapshot \(name): \(url.path) (\(image.width)×\(image.height))")
    }
}
#endif
