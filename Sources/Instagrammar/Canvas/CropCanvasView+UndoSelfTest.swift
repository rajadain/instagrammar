#if DEBUG
import AppKit
import TilerCore

/// DEBUG-only undo/redo self-check: `INSTAGRAMMAR_UNDO_SELFTEST=1 .build/debug/Instagrammar <image>`.
///
/// Drives the real canvas handlers and the model's edit API the way the UI does (synthesized
/// mouse, key and scroll events; a pinch and a rotate gesture through the canvas' interaction
/// boundaries; a slider-style begin/change/end), records the `EditState` before and after
/// every action, then walks the undo stack back and forward and compares exactly. Prints
/// `UNDO SELFTEST PASS`/`FAIL` to stderr and exits 0/1.
extension CropCanvasView {
    static let undoSelfTestRequested =
        ProcessInfo.processInfo.environment["INSTAGRAMMAR_UNDO_SELFTEST"] == "1"

    func startUndoSelfTest() {
        selfTestStarted = true
        Task { @MainActor in
            let ok = await UndoSelfTest(view: self, model: AppModel.shared).run()
            FileHandle.standardError.write(Data("UNDO SELFTEST \(ok ? "PASS" : "FAIL")\n".utf8))
            exit(ok ? 0 : 1)
        }
    }
}

@MainActor
private final class UndoSelfTest {
    let view: CropCanvasView
    let model: AppModel
    var failures = 0

    struct Step {
        var name: String
        var menuTitle: String
        var before: EditState
        var after: EditState
    }
    var steps: [Step] = []

    init(view: CropCanvasView, model: AppModel) { self.view = view; self.model = model }

    func log(_ s: String) { FileHandle.standardError.write(Data("[undotest] \(s)\n".utf8)) }
    func check(_ ok: Bool, _ what: String) {
        log("\(ok ? "PASS" : "FAIL"): \(what)")
        if !ok { failures += 1 }
    }
    func sleep(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    func mouse(_ type: NSEvent.EventType, at p: CGPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: view.window!.windowNumber, context: nil,
                           eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    func key(_ chars: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: view.window!.windowNumber, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: keyCode)!
    }

    /// Wheel tick (line units): zooms about the pointer, positive = in.
    func wheel(_ lines: Int32) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                         wheel1: lines, wheel2: 0, wheel3: 0)!
        return NSEvent(cgEvent: cg)!
    }

    var stripCentre: CGPoint {
        let r = view.mapping!.stripRect
        return CGPoint(x: r.midX, y: r.midY)
    }

    /// Runs `action`, waits for any burst to settle, and records the before/after snapshots.
    func step(_ name: String, settle: Int = 750, _ action: () async -> Void) async {
        let before = model.editState
        await action()
        await sleep(settle)
        let after = model.editState
        check(before != after, "\(name): the action changed the edit state")
        check(model.pendingEdit == nil, "\(name): nothing left pending after the interaction")
        check(model.undoManager.canUndo, "\(name): undo available")
        steps.append(Step(name: name, menuTitle: model.undoMenuTitle, before: before, after: after))
    }

    func run() async -> Bool {
        await sleep(700)
        guard view.mapping != nil, model.hasImage else { check(false, "image loaded"); return false }
        // Known starting settings (they persist in UserDefaults; the originals are restored at the end).
        let originalPreset = model.aspectPreset, originalCustom = model.customAspect
        let originalCount = model.tileCount
        model.aspectPreset = .portrait4x5
        model.customAspect = .portrait4x5
        model.tileCount = 3
        model.undoManager.removeAllActions()
        model.refreshUndoState()
        check(!model.canUndo && !model.canRedo, "history starts empty")
        let initial = model.editState
        view.window?.makeFirstResponder(view)

        // 1. Pinch (phased trackpad gesture: begin, several magnify events, end).
        await step("pinch") {
            view.beginInteraction("Zoom")
            for _ in 0..<5 { view.handleZoom(factor: 1.15, atViewPoint: stripCentre); await sleep(16) }
            view.endInteraction()
        }
        // 2. Pan drag: mouse down, drags, up.
        await step("pan drag") {
            let p = stripCentre
            view.mouseDown(with: mouse(.leftMouseDown, at: p))
            for i in 1...6 {
                view.mouseDragged(with: mouse(.leftMouseDragged,
                                              at: CGPoint(x: p.x + CGFloat(i) * 6, y: p.y - CGFloat(i) * 4)))
                await sleep(16)
            }
            view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: p.x + 36, y: p.y - 24)))
        }
        // 3. Slider-style change: begin, many value changes, end (as the Straighten slider does).
        await step("straighten slider drag") {
            model.beginEdit("Straighten")
            for i in 1...10 {
                let v = Double(i) * 0.3
                model.performEdit("Straighten") { model.straightenDegrees = v }
                await sleep(10)
            }
            model.endEdit()
        }
        // 4. Rotate gesture.
        await step("rotate gesture") {
            view.beginRotateGesture()
            view.beginInteraction("Rotate")
            for _ in 0..<4 { view.handleRotate(counterClockwiseDegrees: 2); await sleep(16) }
            view.endRotateGesture()
            view.endInteraction()
        }
        // 5. Scroll burst: many wheel ticks 60 ms apart must stay one pending step until quiet.
        await step("scroll-wheel burst", settle: 100) {
            for _ in 0..<6 { view.scrollWheel(with: wheel(2)); await sleep(60) }
            check(model.pendingEdit != nil, "scroll burst: still open 60 ms after the last tick")
            await sleep(750)
        }
        // 6. Key-repeat burst.
        await step("key-repeat burst", settle: 100) {
            for _ in 0..<5 { view.keyDown(with: key("=", keyCode: 24)); await sleep(40) }
            check(model.pendingEdit != nil, "key burst: still open 40 ms after the last key")
            await sleep(750)
        }
        // 7. Double-click reset.
        await step("double-click reset") {
            let p = stripCentre
            view.mouseDown(with: mouse(.leftMouseDown, at: p, clicks: 2))
            view.mouseUp(with: mouse(.leftMouseUp, at: p, clicks: 2))
        }
        // Zoom in again so later steps have something to lose.
        await step("zoom burst (keys)") {
            for _ in 0..<3 { view.keyDown(with: key("=", keyCode: 24)); await sleep(30) }
        }
        // 8. Quarter turn.
        await step("quarter turn") { model.rotateRight() }
        // 9. Reset button (after something to reset).
        await step("arrow-key pan") {
            let down = String(Character(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!))
            for _ in 0..<4 { view.keyDown(with: key(down, keyCode: 125)); await sleep(30) }
        }
        await step("reset button") { model.resetCrop() }
        // 10. Tile count.
        await step("tile count") { model.tileCount = model.tileCount + 1 }
        // 11. Aspect preset.
        await step("aspect preset") { model.aspectPreset = .square }
        // 12. Custom aspect: preset switch, then fast typing = one coalesced step.
        await step("aspect → custom") { model.aspectPreset = .custom }
        await step("custom aspect typing") {
            for (w, h) in [(3.0, 4.0), (5.0, 7.0), (16.0, 9.0)] {
                model.setCustomAspect(width: w, height: h)
                await sleep(80)
            }
        }

        log("\(steps.count) actions performed")
        log("menu titles: " + steps.map(\.menuTitle).joined(separator: ", "))

        // Undo everything: one entry per action, exact previous state each time.
        for s in steps.reversed() {
            check(model.undoMenuTitle == s.menuTitle, "before undoing \(s.name): menu says \"\(model.undoMenuTitle)\"")
            model.undo()
            check(model.editState == s.before, "undo \(s.name): state restored exactly")
            check(model.canRedo, "undo \(s.name): redo available")
        }
        check(!model.canUndo, "exactly \(steps.count) undo steps (stack empty afterwards)")
        check(model.editState == initial, "fully undone == initial state")

        // Redo everything.
        for s in steps {
            check(model.redoMenuTitle.hasPrefix("Redo"), "redo title \"\(model.redoMenuTitle)\"")
            model.redo()
            check(model.editState == s.after, "redo \(s.name): state re-applied exactly")
        }
        check(!model.canRedo, "redo stack empty after redoing everything")
        await sleep(300)
        check(view.lastExternalCrop == view.crop && view.crop == model.crop,
              "canvas follows the model after undo/redo")

        // A new action after an undo drops the redo stack.
        model.undo()
        model.undo()
        check(model.canRedo, "redo available after two undos")
        model.discreteEdit("Reset Crop") {
            model.crop = CropGeometry.fit(spec: model.spec, imageSize: model.workingImageSize, angle: 0.1)
        }
        check(!model.canRedo, "new edit clears the redo stack")

        // Cmd-Z / Shift-Cmd-Z through the real Edit menu with the canvas as first responder.
        // (SwiftUI does not refresh menu enablement/titles on model changes in this headless
        // run, so the Undo/Redo items are never `.disabled`; the model no-ops when empty.)
        view.window?.makeFirstResponder(view)
        await step("pan for menu test") {
            let p = stripCentre
            view.mouseDown(with: mouse(.leftMouseDown, at: p))
            view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: p.x + 20, y: p.y)))
            view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: p.x + 20, y: p.y)))
        }
        let last = steps.last!
        let handledUndo = NSApp.mainMenu?.performKeyEquivalent(with: key("z", keyCode: 6, modifiers: .command)) ?? false
        await sleep(200)
        check(handledUndo && model.editState == last.before,
              "Cmd-Z via the main menu undoes the pan (handled=\(handledUndo))")
        let handledRedo = NSApp.mainMenu?.performKeyEquivalent(with: key("z", keyCode: 6, modifiers: [.command, .shift])) ?? false
        await sleep(200)
        check(handledRedo && model.editState == last.after,
              "Shift-Cmd-Z via the main menu redoes it (handled=\(handledRedo))")

        // Opening an image clears the history.
        if let url = model.source?.url {
            check(model.canUndo, "history non-empty before reopening")
            await model.open(url: url)
            check(!model.canUndo && !model.canRedo, "opening an image clears undo history")
        }

        model.aspectPreset = originalPreset
        model.customAspect = originalCustom
        model.tileCount = originalCount
        log("\(failures) failure(s)")
        return failures == 0
    }
}
#endif
