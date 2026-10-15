import AppKit
import QuartzCore
import TilerCore

/// The interactive crop canvas (decision T3): an `NSView` whose content is a small CALayer tree,
/// so pan / zoom / rotate only change layer transforms and paths and the GPU composites them.
/// Nothing re-renders pixels during interaction.
///
/// Layer tree (all inside `contentLayer`, whose sublayer geometry is y-down like S-space):
/// 1. `imageLayer`: `contents` = the preview `CGImage`, bounds = preview pixels, anchor and
///    position at the origin, affine transform = `CropGeometry.previewToView` (preview pixels →
///    oriented pixels → quarter turns → S-space → `sToView`).
/// 2. `dimLayer`: even-odd path (view bounds + strip rect) filled with 55% black, so the image
///    outside the strip stays visible as context.
/// 3. `gridLayer`: strip border, tile dividers and per-tile rule-of-thirds lines (interaction only).
/// 4. `labelsLayer`: tile numbers (shown while interacting or when hovering over the strip).
///
/// Every input goes through a `CropGeometry` helper, then `propose(_:)`, which hands the proposed
/// crop to `onCropChange` (the model clamps it) and applies the same clamp locally so the layers
/// follow the gesture immediately; the model's value then comes back through `update(...)` and
/// is a no-op when it matches.
final class CropCanvasView: NSView {
    /// Gap in points between the strip and the canvas edge.
    static let padding: Double = 24
    /// Opacity of the black veil over the image outside the strip.
    static let dimAlpha: CGFloat = 0.55
    /// How long overlays (thirds, tile numbers) stay up after the last discrete input.
    static let overlayLinger: TimeInterval = 0.7

    // MARK: Inputs (pushed by `CropCanvas.updateNSView`)

    private(set) var preview: CGImage?
    private(set) var quarterTurns: QuarterTurns = .r0
    /// The current crop: the model's value, or the locally clamped proposal during a gesture.
    private(set) var crop = CropState(center: .zero, width: 0)
    private(set) var spec = TileSpec(aspect: .portrait4x5, count: 3)
    private(set) var orientedSize: CGSize = .zero
    var onCropChange: (CropState) -> Void = { _ in }

    /// The last crop received from outside (the model). Used by the DEBUG self-test.
    private(set) var lastExternalCrop: CropState?

    /// S-space size: oriented size with the quarter turns applied.
    var imageSize: CGSize { workingSize(orientedSize, quarterTurns) }

    /// The S → view mapping from the most recent layout; nil until there is something to show.
    private(set) var mapping: CropGeometry.ViewMapping?

    // MARK: Layers

    let contentLayer = CALayer()
    let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let gridLayer = CALayer()
    private let borderLayer = CAShapeLayer()
    private let dividerLayer = CAShapeLayer()
    private let thirdsLayer = CAShapeLayer()
    private let labelsLayer = CALayer()
    private var labelLayers: [CALayer] = []

    // MARK: Interaction reporting (undo checkpoints)

    /// Interaction boundaries for the model's undo history: one begin/end pair per pan drag,
    /// pinch, rotate gesture, double-click, or coalesced scroll / key burst.
    var onInteractionBegan: () -> Void = {}
    var onInteractionEnded: (String) -> Void = { _ in }
    /// How long a scroll or key-repeat burst may be silent before it counts as finished.
    static let burstQuietInterval: TimeInterval = 0.5
    /// Shorter wait after a trackpad scroll's finger-lift, in case momentum events follow.
    static let scrollLiftInterval: TimeInterval = 0.2
    /// Action name of the open interaction, nil when none is open.
    private(set) var interactionName: String?
    private var interactionTimer: DispatchWorkItem?

    // MARK: Interaction state

    private var dragLast: CGPoint?
    private var isDragging = false
    private var isHoveringStrip = false
    private(set) var overlaysShown = false
    private var overlayHide: DispatchWorkItem?
    /// Crop at the start of a trackpad rotation (with the accumulated angle). Proposals are made
    /// from it, so rotating back towards the start angle also restores the zoom and position
    /// that clamping took away (Lightroom-style), instead of ratcheting the zoom in.
    private var rotateBase: CropState?
    private var trackingArea: NSTrackingArea?

    #if DEBUG
    var selfTestStarted = false
    #endif

    // MARK: Setup

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setUpLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}   // Content comes from sublayers only.

    private func setUpLayers() {
        guard let root = layer else { return }
        contentLayer.masksToBounds = true
        contentLayer.anchorPoint = .zero
        root.addSublayer(contentLayer)

        imageLayer.anchorPoint = .zero
        imageLayer.position = .zero
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        imageLayer.allowsEdgeAntialiasing = true
        imageLayer.contentsGravity = .resize
        contentLayer.addSublayer(imageLayer)

        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(Self.dimAlpha).cgColor
        dimLayer.anchorPoint = .zero
        contentLayer.addSublayer(dimLayer)

        gridLayer.anchorPoint = .zero
        for (shape, alpha) in [(thirdsLayer, 0.25), (dividerLayer, 0.8), (borderLayer, 1.0)] {
            shape.fillColor = nil
            shape.strokeColor = NSColor.white.withAlphaComponent(alpha).cgColor
            shape.lineWidth = 1
            shape.anchorPoint = .zero
            gridLayer.addSublayer(shape)
        }
        thirdsLayer.opacity = 0
        contentLayer.addSublayer(gridLayer)

        labelsLayer.anchorPoint = .zero
        labelsLayer.opacity = 0
        contentLayer.addSublayer(labelsLayer)

        disableImplicitAnimations()
        updateAppearance()
    }

    /// Belt and braces on top of `CATransaction.setDisableActions`: these layers never animate
    /// geometry or paths implicitly.
    private func disableImplicitAnimations() {
        let none: [String: CAAction] = [
            "position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "path": NSNull(),
            "contents": NSNull(), "frame": NSNull(), "hidden": NSNull(), "sublayers": NSNull(),
        ]
        for l in [contentLayer, imageLayer, dimLayer, gridLayer, borderLayer, dividerLayer,
                  thirdsLayer, labelsLayer] {
            l.actions = none
        }
    }

    // MARK: Inputs

    /// Called from `updateNSView`. Re-lays the layers only when an input actually changed, and
    /// sets the image layer's `contents` only when the preview identity changes.
    func update(preview newPreview: CGImage, quarterTurns q: QuarterTurns, crop newCrop: CropState,
                spec newSpec: TileSpec, orientedSize newOriented: CGSize) {
        lastExternalCrop = newCrop
        var changed = false
        if newPreview !== preview {
            preview = newPreview
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contents = newPreview
            CATransaction.commit()
            changed = true
            rotateBase = nil
        }
        if q != quarterTurns { quarterTurns = q; changed = true; rotateBase = nil }
        if newOriented != orientedSize { orientedSize = newOriented; changed = true }
        if newSpec != spec {
            spec = newSpec
            rebuildLabels()
            changed = true
        }
        if newCrop != crop {
            crop = newCrop
            changed = true
            // Something outside the gesture changed the crop: rotate from here on.
            if rotateBase != nil { rotateBase = newCrop }
        }
        if changed { updateLayers() }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        updateLayers()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateLayers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
        updateAppearance()
        updateLayers()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
        updateLayers()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    private func updateContentsScale() {
        let s = backingScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [contentLayer, dimLayer, gridLayer, borderLayer, dividerLayer, thirdsLayer, labelsLayer] {
            l.contentsScale = s
        }
        for pill in labelLayers {
            pill.contentsScale = s
            pill.sublayers?.forEach { $0.contentsScale = s }
        }
        CATransaction.commit()
    }

    private func updateAppearance() {
        var bg = NSColor.underPageBackgroundColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bg = NSColor.underPageBackgroundColor.cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.backgroundColor = bg
        CATransaction.commit()
    }

    /// Recomputes the S → view mapping and pushes it into every layer. Only geometry changes
    /// here: transforms, frames and paths.
    func updateLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        contentLayer.frame = bounds
        // Our sublayers must use y-down geometry like the (flipped) view and S-space. AppKit
        // flips a flipped view's backing layer (observed: geometryFlipped = true), so normally
        // nothing changes here; derive it rather than assume, and only touch it when wrong.
        if !contentLayer.contentsAreFlipped() { contentLayer.isGeometryFlipped.toggle() }

        guard let preview, bounds.width > 0, bounds.height > 0, crop.width > 0,
              orientedSize.width > 0, orientedSize.height > 0 else {
            mapping = nil
            imageLayer.isHidden = true
            dimLayer.path = nil
            [borderLayer, dividerLayer, thirdsLayer].forEach { $0.path = nil }
            labelsLayer.isHidden = true
            return
        }
        imageLayer.isHidden = false
        labelsLayer.isHidden = false

        let m = CropGeometry.sToView(state: crop, spec: spec, viewSize: bounds.size, padding: Self.padding)
        mapping = m

        let previewSize = CGSize(width: preview.width, height: preview.height)
        imageLayer.bounds = CGRect(origin: .zero, size: previewSize)
        imageLayer.anchorPoint = .zero
        imageLayer.position = .zero
        imageLayer.setAffineTransform(CropGeometry.previewToView(
            previewSize: previewSize, orientedSize: orientedSize, quarterTurns: quarterTurns,
            viewTransform: m.transform))

        let full = CGRect(origin: .zero, size: bounds.size)
        dimLayer.frame = full
        let dim = CGMutablePath()
        dim.addRect(full)
        dim.addRect(m.stripRect)
        dimLayer.path = dim

        gridLayer.frame = full
        [borderLayer, dividerLayer, thirdsLayer].forEach { $0.frame = full }
        buildGridPaths(strip: m.stripRect)

        labelsLayer.frame = full
        layoutLabels(strip: m.stripRect)

        #if DEBUG
        startSelfTestIfRequested()
        #endif
    }

    /// Snaps a coordinate so a 1-pt line is centred on whole device pixels (crisp on Retina).
    private func snap(_ v: CGFloat) -> CGFloat {
        let s = backingScale
        let px = (v * s).rounded()
        // A 1-pt line is `s` pixels wide: centre odd widths on half pixels.
        return Int(s.rounded()) % 2 == 0 ? px / s : (px + 0.5) / s
    }

    private func buildGridPaths(strip r: CGRect) {
        let x0 = snap(r.minX), x1 = snap(r.maxX), y0 = snap(r.minY), y1 = snap(r.maxY)
        borderLayer.path = CGPath(rect: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0),
                                  transform: nil)

        let n = max(spec.count, 1)
        let tileW = r.width / CGFloat(n)
        let dividers = CGMutablePath()
        for i in 1..<max(n, 1) {
            let x = snap(r.minX + tileW * CGFloat(i))
            dividers.move(to: CGPoint(x: x, y: y0))
            dividers.addLine(to: CGPoint(x: x, y: y1))
        }
        dividerLayer.path = dividers

        let thirds = CGMutablePath()
        for i in 0..<n {
            let tx = r.minX + tileW * CGFloat(i)
            for f in [1.0 / 3.0, 2.0 / 3.0] {
                let x = snap(tx + tileW * f)
                thirds.move(to: CGPoint(x: x, y: y0))
                thirds.addLine(to: CGPoint(x: x, y: y1))
                let y = snap(r.minY + r.height * f)
                thirds.move(to: CGPoint(x: snap(tx), y: y))
                thirds.addLine(to: CGPoint(x: snap(tx + tileW), y: y))
            }
        }
        thirdsLayer.path = thirds
    }

    // MARK: Tile number labels

    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

    private func rebuildLabels() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        labelLayers.forEach { $0.removeFromSuperlayer() }
        labelLayers = (0..<spec.count).map { i in
            let text = "\(i + 1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.labelFont]
            let size = text.size(withAttributes: attrs)
            let pill = CALayer()
            pill.anchorPoint = .zero
            pill.bounds = CGRect(x: 0, y: 0, width: max(18, ceil(size.width) + 10), height: 18)
            pill.cornerRadius = 5
            pill.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
            pill.contentsScale = backingScale
            let t = CATextLayer()
            t.string = text
            t.font = Self.labelFont
            t.fontSize = Self.labelFont.pointSize
            t.foregroundColor = NSColor.white.cgColor
            t.alignmentMode = .center
            t.contentsScale = backingScale
            t.frame = CGRect(x: 0, y: (18 - ceil(size.height)) / 2,
                             width: pill.bounds.width, height: ceil(size.height))
            t.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
            pill.actions = ["position": NSNull(), "bounds": NSNull()]
            pill.addSublayer(t)
            labelsLayer.addSublayer(pill)
            return pill
        }
    }

    private func layoutLabels(strip r: CGRect) {
        if labelLayers.count != spec.count { rebuildLabels() }
        let tileW = r.width / CGFloat(max(spec.count, 1))
        for (i, pill) in labelLayers.enumerated() {
            pill.position = CGPoint(x: (r.minX + tileW * CGFloat(i) + 6).rounded(),
                                    y: (r.minY + 6).rounded())
        }
    }

    // MARK: Overlays (thirds + tile numbers)

    private func setOverlays(interacting: Bool) {
        overlaysShown = interacting
        let showLabels = interacting || isHoveringStrip
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        thirdsLayer.opacity = interacting ? 1 : 0
        labelsLayer.opacity = showLabels ? 1 : 0
        CATransaction.commit()
    }

    /// Shows the overlays now and hides them `overlayLinger` seconds after the last call (unless a
    /// drag is still going).
    private func noteInteraction() {
        if !overlaysShown { setOverlays(interacting: true) }
        overlayHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isDragging else { return }
            self.setOverlays(interacting: false)
        }
        overlayHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.overlayLinger, execute: work)
    }

    // MARK: Proposals

    /// Sends `proposed` to the model and applies the same limit + clamp locally so the canvas
    /// tracks the gesture within the same event (the model's identical result then arrives via
    /// `update(...)` as a no-op).
    func propose(_ proposed: CropState) {
        guard mapping != nil, imageSize.width > 0 else { return }
        onCropChange(proposed)
        var c = proposed
        c.angle = Self.limitAngle(c.angle)
        let clamped = CropGeometry.clamp(c, spec: spec, imageSize: imageSize)
        if clamped != crop {
            crop = clamped
            updateLayers()
        }
        noteInteraction()
    }

    /// The model's ±45° Straighten limit (AppModel.update(crop:) applies the same).
    static func limitAngle(_ angle: Double) -> Double {
        let limit = AppModel.straightenRange.upperBound * .pi / 180
        return min(max(angle, -limit), limit)
    }

    // MARK: Interaction boundaries

    /// Opens an interaction named `name` (closing a different open one first). Idempotent for
    /// the same name.
    func beginInteraction(_ name: String) {
        if let open = interactionName {
            if open == name { return }
            endInteraction()
        }
        interactionName = name
        onInteractionBegan()
    }

    /// Closes the open interaction, if any, which registers its undo step.
    func endInteraction() {
        interactionTimer?.cancel()
        interactionTimer = nil
        guard let name = interactionName else { return }
        interactionName = nil
        onInteractionEnded(name)
    }

    /// (Re)starts the quiet timer that closes the open interaction: used for scroll and key
    /// bursts, which have no reliable end event.
    private func endInteraction(afterQuiet interval: TimeInterval) {
        interactionTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endInteraction() }
        interactionTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    /// A burst event (key repeat, wheel tick): joins the open burst of the same kind, else
    /// starts one, then waits for quiet.
    private func noteBurst(_ name: String) {
        beginInteraction(name)
        endInteraction(afterQuiet: Self.burstQuietInterval)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        endInteraction()
        super.viewWillMove(toWindow: newWindow)
    }

    override func resignFirstResponder() -> Bool {
        endInteraction()
        return super.resignFirstResponder()
    }

    // MARK: Gesture handlers (pure-ish: event plumbing lives in the NSEvent overrides)

    /// Pans so the image follows the pointer by `delta` view points (y-down).
    func handlePan(viewDelta delta: CGVector) {
        guard let m = mapping, delta.dx != 0 || delta.dy != 0 else { return }
        propose(CropGeometry.panned(crop, byViewDelta: delta, viewScale: m.viewScale))
        if rotateBase != nil { rotateBase = crop }
    }

    /// Zooms by `factor` (> 1 zooms in) keeping the image point under `point` (view) fixed.
    func handleZoom(factor: Double, atViewPoint point: CGPoint) {
        guard let m = mapping, factor.isFinite, factor > 0, factor != 1 else { return }
        let anchor = point.applying(m.transform.inverted())
        propose(CropGeometry.zoomed(crop, factor: factor, anchorInS: anchor))
        if rotateBase != nil { rotateBase = crop }
    }

    /// Turns the image on screen counter-clockwise by `degrees` about the strip centre.
    func handleRotate(counterClockwiseDegrees degrees: Double) {
        guard degrees.isFinite, degrees != 0 else { return }
        var base = rotateBase ?? crop
        base = CropGeometry.rotatedOnScreen(base, counterClockwiseDegrees: degrees)
        base.angle = Self.limitAngle(base.angle)
        if rotateBase != nil { rotateBase = base }
        propose(base)
    }

    func beginRotateGesture() { rotateBase = crop }
    func endRotateGesture() { rotateBase = nil }

    /// Changes Straighten (σ, degrees; positive turns the image clockwise) by `delta`.
    func handleStraighten(byDegrees delta: Double) {
        var c = crop
        c.straightenDegrees = ((c.straightenDegrees + delta) * 1000).rounded() / 1000
        propose(c)
    }

    /// Double-click: fit at the current angle.
    func handleResetFit() {
        guard imageSize.width > 0 else { return }
        propose(CropGeometry.fit(spec: spec, imageSize: imageSize, angle: crop.angle))
    }

    // MARK: Mouse

    private func viewPoint(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        endInteraction()   // A burst (keys, wheel) still waiting for quiet ends here.
        if event.clickCount == 2 {
            beginInteraction("Reset Crop")
            handleResetFit()
            endInteraction()
            return
        }
        beginInteraction("Pan")
        dragLast = viewPoint(event)
        isDragging = true
        NSCursor.closedHand.set()
        noteInteraction()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = dragLast else { return }
        let p = viewPoint(event)
        dragLast = p
        handlePan(viewDelta: CGVector(dx: p.x - last.x, dy: p.y - last.y))
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        dragLast = nil
        isDragging = false
        endInteraction()
        noteInteraction()   // Let the overlays linger briefly, then hide.
        updateHover(at: viewPoint(event))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { updateHover(at: viewPoint(event)) }
    override func mouseEntered(with event: NSEvent) { updateHover(at: viewPoint(event)) }

    override func mouseExited(with event: NSEvent) {
        if isHoveringStrip {
            isHoveringStrip = false
            setOverlays(interacting: overlaysShown)
        }
        if !isDragging { NSCursor.arrow.set() }
    }

    override func cursorUpdate(with event: NSEvent) { updateHover(at: viewPoint(event)) }

    private func updateHover(at p: CGPoint) {
        let over = mapping?.stripRect.contains(p) ?? false
        if over != isHoveringStrip {
            isHoveringStrip = over
            setOverlays(interacting: overlaysShown)
        }
        if isDragging { NSCursor.closedHand.set() } else if over { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
    }

    // MARK: Trackpad and wheel

    override func scrollWheel(with event: NSEvent) {
        guard mapping != nil else { return super.scrollWheel(with: event) }
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
            // Two-finger trackpad scroll pans. `scrollingDelta` already follows the user's
            // natural-scrolling setting, and positive values move content right/down, exactly
            // like NSScrollView, so the image moves with the fingers.
            beginInteraction("Pan")
            handlePan(viewDelta: CGVector(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY))
            noteScrollEnd(event)
        } else {
            // Mouse wheel (line deltas) or ⌘ + scroll zooms about the pointer; scrolling up
            // (positive deltaY) zooms in.
            let dy = Double(event.scrollingDeltaY)
            let factor = event.hasPreciseScrollingDeltas ? pow(1.005, dy) : pow(1.1, dy)
            beginInteraction("Zoom")
            handleZoom(factor: factor, atViewPoint: viewPoint(event))
            noteScrollEnd(event)
        }
    }

    /// One scroll burst = one undo step: it ends when momentum ends, shortly after the fingers
    /// lift (unless momentum follows), or after `burstQuietInterval` without events.
    private func noteScrollEnd(_ event: NSEvent) {
        if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
            endInteraction()
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            endInteraction(afterQuiet: Self.scrollLiftInterval)
        } else {
            endInteraction(afterQuiet: Self.burstQuietInterval)
        }
    }

    override func magnify(with event: NSEvent) {
        // Phased pinch (trackpad): began ... ended. Unphased events fall back to a burst.
        if event.phase.contains(.began) || interactionName != "Zoom" { beginInteraction("Zoom") }
        handleZoom(factor: 1 + Double(event.magnification), atViewPoint: viewPoint(event))
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            endInteraction()
        } else if event.phase.isEmpty {
            endInteraction(afterQuiet: Self.burstQuietInterval)
        }
    }

    /// Trackpad rotation. `NSEvent.rotation` is the per-event change in degrees, positive for
    /// counter-clockwise finger motion (AppKit convention). The image follows the fingers, so a
    /// positive rotation turns the image counter-clockwise on screen: Straighten σ decreases by
    /// `rotation` (σ = −angle in degrees, so `angle += rotation·π/180`).
    override func rotate(with event: NSEvent) {
        switch event.phase {
        case .began: beginRotateGesture()
        default: break
        }
        if event.phase.contains(.began) || interactionName != "Rotate" { beginInteraction("Rotate") }
        handleRotate(counterClockwiseDegrees: Double(event.rotation))
        if event.phase == .ended || event.phase == .cancelled {
            endRotateGesture()
            endInteraction()
        } else if event.phase.isEmpty {
            endInteraction(afterQuiet: Self.burstQuietInterval)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard mapping != nil,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return super.keyDown(with: event)
        }
        let shift = event.modifierFlags.contains(.shift)
        let step: CGFloat = shift ? 10 : 1
        // Arrow keys move the image in the arrow's direction, like dragging it.
        switch event.specialKey {
        case .leftArrow?: return keyPan(CGVector(dx: -step, dy: 0))
        case .rightArrow?: return keyPan(CGVector(dx: step, dy: 0))
        case .upArrow?: return keyPan(CGVector(dx: 0, dy: -step))
        case .downArrow?: return keyPan(CGVector(dx: 0, dy: step))
        default: break
        }
        let centre = CGPoint(x: mapping!.stripRect.midX, y: mapping!.stripRect.midY)
        switch event.charactersIgnoringModifiers {
        case "+", "=": noteBurst("Zoom"); handleZoom(factor: 1.1, atViewPoint: centre)
        case "-", "_": noteBurst("Zoom"); handleZoom(factor: 1 / 1.1, atViewPoint: centre)
        case ",", "<": noteBurst("Straighten"); handleStraighten(byDegrees: shift ? -1 : -0.1)
        case ".", ">": noteBurst("Straighten"); handleStraighten(byDegrees: shift ? 1 : 0.1)
        default: super.keyDown(with: event)
        }
    }

    private func keyPan(_ delta: CGVector) {
        noteBurst("Pan")
        handlePan(viewDelta: delta)
    }
}
