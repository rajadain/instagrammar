import AppKit
import Foundation
import Observation
import TilerCore
import UniformTypeIdentifiers

/// An error or notice shown to the user in an alert.
struct ModelAlert: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}

/// Settings that survive relaunches (stored as JSON in `UserDefaults`).
struct PersistedSettings: Codable, Equatable {
    var aspectPreset: AspectPreset = .portrait4x5
    var customAspect: AspectRatio = .portrait4x5
    var tileCount: Int = 3
    var exportSettings: ExportSettings = ExportSettings()
    var lastExportFolderPath: String?
}

/// Document state, settings and edit operations. The single source of truth for the UI.
@Observable
@MainActor
final class AppModel {
    /// Shared between the SwiftUI `App` and `AppDelegate` (Dock / Finder "Open With").
    static let shared = AppModel()

    // MARK: Limits

    /// Straighten range in degrees (decision P5, enforced here per T18).
    static let straightenRange: ClosedRange<Double> = -45...45
    /// Allowed custom aspect ratio (width / height) range.
    nonisolated static let customAspectValueRange: ClosedRange<Double> = 0.2...5
    static let settingsKey = "InstagrammarSettings.v1"

    // MARK: Document state

    var source: SourceImage?
    /// Downsampled, orientation-applied preview; the canvas applies `quarterTurns` on top.
    var preview: CGImage?
    var isLoading = false
    var quarterTurns: QuarterTurns = .r0
    /// Always clamped; change only through `update(crop:)` (and `AppModel+Undo`, which restores
    /// previously valid snapshots verbatim).
    var crop: CropState = CropState(center: .zero, width: 1)
    var alert: ModelAlert?

    // MARK: Persisted settings

    var aspectPreset: AspectPreset = .portrait4x5 {
        didSet {
            guard aspectPreset != oldValue else { return }
            if !isApplyingEdit {
                let before = editState(preset: oldValue)
                specChanged(old: makeSpec(preset: oldValue), editBefore: before, actionName: "Aspect")
            }
            persist()
        }
    }
    var customAspect: AspectRatio = .portrait4x5 {
        didSet {
            guard customAspect != oldValue else { return }
            if !isApplyingEdit {
                let before = editState(custom: oldValue)
                specChanged(old: makeSpec(custom: oldValue), editBefore: before, actionName: "Aspect",
                            coalesced: true)
            }
            persist()
        }
    }
    var tileCount: Int = 3 {
        didSet {
            let clamped = min(max(tileCount, TileSpec.countRange.lowerBound), TileSpec.countRange.upperBound)
            if clamped != tileCount { tileCount = clamped; return }
            guard tileCount != oldValue else { return }
            if !isApplyingEdit {
                let before = editState(count: oldValue)
                specChanged(old: makeSpec(count: oldValue), editBefore: before, actionName: "Tile Count")
            }
            persist()
        }
    }
    var exportSettings = ExportSettings() {
        didSet { if exportSettings != oldValue { persist() } }
    }
    /// Last folder chosen for export (used by Phase 6).
    var lastExportFolderPath: String? {
        didSet { if lastExportFolderPath != oldValue { persist() } }
    }

    // MARK: Private

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var loadingURL: URL?
    @ObservationIgnored private var isRestoring = true

    // MARK: Undo / redo (logic in AppModel+Undo.swift)

    /// Owned by the model and driven by the Edit menu commands (see `InstagrammarApp`), so ⌘Z
    /// works whichever view has focus. Grouping is explicit: one registration = one undo step.
    @ObservationIgnored let undoManager: UndoManager = {
        let m = UndoManager()
        m.groupsByEvent = false
        m.levelsOfUndo = 200
        return m
    }()
    /// Mirrors of the undo manager's state, for menu items (UndoManager isn't observable).
    var canUndo = false
    var canRedo = false
    var undoMenuTitle = "Undo"
    var redoMenuTitle = "Redo"
    /// An open interaction (`beginEdit`) or coalesced burst waiting to be registered.
    @ObservationIgnored var pendingEdit: PendingEdit?
    /// True while an undo/redo restores a snapshot: suppresses registration and respec.
    @ObservationIgnored var isApplyingEdit = false
    @ObservationIgnored var coalesceGeneration = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.settingsKey),
           let s = try? JSONDecoder().decode(PersistedSettings.self, from: data) {
            aspectPreset = s.aspectPreset
            customAspect = Self.isValidCustom(s.customAspect) ? s.customAspect : .portrait4x5
            tileCount = min(max(s.tileCount, TileSpec.countRange.lowerBound), TileSpec.countRange.upperBound)
            exportSettings = s.exportSettings
            lastExportFolderPath = s.lastExportFolderPath
        }
        isRestoring = false
    }

    // MARK: Derived

    var hasImage: Bool { source != nil && preview != nil }

    /// Aspect of one tile for the current preset.
    var aspect: AspectRatio { aspectPreset.aspect(custom: customAspect) }

    var spec: TileSpec { TileSpec(aspect: aspect, count: tileCount) }

    /// Size of the working (S-space) image; `.zero` with no image.
    var workingImageSize: CGSize {
        guard let source else { return .zero }
        return workingSize(source.orientedSize, quarterTurns)
    }

    /// The "Maximum" tile export size at the current crop; (0, 0) with no image.
    var nativeTileSize: (width: Int, height: Int) {
        guard hasImage else { return (0, 0) }
        return CropGeometry.nativeTilePixelSize(state: crop, spec: spec)
    }

    /// Straighten in degrees (σ = −angle). Setting clamps to ±45° and then clamps the crop.
    var straightenDegrees: Double {
        get { crop.straightenDegrees }
        set {
            guard hasImage, newValue.isFinite else { return }
            let sigma = min(max(newValue, Self.straightenRange.lowerBound), Self.straightenRange.upperBound)
            update(crop: CropGeometry.rotated(crop, toAngle: CropState.angle(forStraightenDegrees: sigma)))
        }
    }

    /// Largest strip width at the current angle (zoom 1×).
    private var maxStripWidth: Double {
        CropGeometry.maxWidth(spec: spec, angle: crop.angle, imageSize: workingImageSize)
    }

    /// Valid zoom range at the current angle and spec: 1× to `maxWidth / minWidth`.
    var zoomRange: ClosedRange<Double> {
        guard hasImage else { return 1...1 }
        let minW = CropGeometry.minWidth(spec: spec, imageSize: workingImageSize)
        guard minW > 0 else { return 1...1 }
        return 1...max(1, maxStripWidth / minW)
    }

    /// Zoom factor `maxWidth / crop.width`. Setting keeps the strip centre and clamps.
    var zoom: Double {
        get {
            guard hasImage, crop.width > 0 else { return 1 }
            return max(1, maxStripWidth / crop.width)
        }
        set {
            guard hasImage, newValue.isFinite, newValue > 0 else { return }
            let z = min(max(newValue, zoomRange.lowerBound), zoomRange.upperBound)
            var c = crop
            c.width = maxStripWidth / z
            update(crop: c)
        }
    }

    // MARK: Crop editing

    /// The single entry point for crop changes. Limits the angle to ±45° and clamps (P6).
    func update(crop newCrop: CropState) {
        guard hasImage else { return }
        var c = newCrop
        let limit = Self.straightenRange.upperBound * .pi / 180
        c.angle = min(max(c.angle, -limit), limit)
        let clamped = CropGeometry.clamp(c, spec: spec, imageSize: workingImageSize)
        if clamped != crop { crop = clamped }
    }

    /// Fit at angle 0, centred. One undo step ("Reset Crop").
    func resetCrop() {
        guard hasImage else { return }
        discreteEdit("Reset Crop") { crop = CropGeometry.fit(spec: spec, imageSize: workingImageSize) }
    }

    func rotateLeft() { setQuarterTurns(quarterTurns.rotatedLeft) }
    func rotateRight() { setQuarterTurns(quarterTurns.rotatedRight) }

    private func setQuarterTurns(_ q: QuarterTurns) {
        guard hasImage else { return }
        discreteEdit("Rotate") {
            quarterTurns = q
            crop = CropGeometry.fit(spec: spec, imageSize: workingImageSize)
        }
    }

    /// Re-fits the crop after a spec change and records it as one undo step.
    private func specChanged(old: TileSpec, editBefore: EditState, actionName: String,
                             coalesced: Bool = false) {
        guard hasImage, !isRestoring else { return }
        if coalesced { beginCoalescedEdit(actionName, from: editBefore) }
        else { commitPendingEdit(endingAt: editBefore) }
        crop = CropGeometry.respec(crop, from: old, to: spec, imageSize: workingImageSize)
        if !coalesced { registerEdit(from: editBefore, to: editState, actionName: actionName) }
    }

    private func makeSpec(preset: AspectPreset? = nil, custom: AspectRatio? = nil, count: Int? = nil) -> TileSpec {
        TileSpec(aspect: (preset ?? aspectPreset).aspect(custom: custom ?? customAspect),
                 count: count ?? tileCount)
    }

    // MARK: Custom aspect validation

    nonisolated static func isValidCustom(_ a: AspectRatio) -> Bool {
        a.isValid && customAspectValueRange.contains(a.value)
    }

    /// Validates user input for a custom aspect: positive, finite, ratio between 0.2 and 5.
    static func customAspect(width: Double, height: Double) -> AspectRatio? {
        let a = AspectRatio(width: width, height: height)
        return isValidCustom(a) ? a : nil
    }

    /// Applies a custom aspect if valid; returns whether it was accepted.
    @discardableResult
    func setCustomAspect(width: Double, height: Double) -> Bool {
        guard let a = Self.customAspect(width: width, height: height) else { return false }
        customAspect = a
        return true
    }

    // MARK: Opening files

    /// Loads `url`, builds its preview off the main actor, then fits the crop. A failed load
    /// leaves the current image untouched and shows an alert.
    func open(url: URL) async {
        if isLoading, loadingURL == url { return }
        loadGeneration += 1
        let generation = loadGeneration
        loadingURL = url
        isLoading = true
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { () -> LoadedImage in
                let source = try SourceImage.load(url: url)
                let preview = try source.makePreview()
                return LoadedImage(source: source, preview: preview)
            }.value
            guard generation == loadGeneration else { return }
            clearUndoHistory()
            source = loaded.source
            preview = loaded.preview
            quarterTurns = .r0
            crop = CropGeometry.fit(spec: spec, imageSize: workingImageSize)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            guard generation == loadGeneration else { return }
            alert = ModelAlert(
                title: "This file can't be read",
                message: (error as? LocalizedError)?.errorDescription
                    ?? "\"\(url.lastPathComponent)\" isn't an image Instagrammar can open.")
        }
        if generation == loadGeneration {
            isLoading = false
            loadingURL = nil
        }
    }

    /// Fire-and-forget wrapper for non-async call sites.
    func openInBackground(url: URL) {
        Task { await open(url: url) }
    }

    /// ⌘O: choose an image with an open panel.
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Open Photo"
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openInBackground(url: url)
    }

    /// First existing file path in the process arguments, ignoring `-flag` arguments.
    nonisolated static func launchArgumentURL(_ args: [String] = CommandLine.arguments) -> URL? {
        for arg in args.dropFirst() where !arg.hasPrefix("-") {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: arg, isDirectory: &isDir), !isDir.boolValue {
                return URL(fileURLWithPath: arg)
            }
        }
        return nil
    }

    // MARK: Export (flow lives in Export/ExportCoordinator.swift)

    let exportCoordinator = ExportCoordinator()

    /// ⌘E / toolbar / inspector button.
    func requestExport() { exportCoordinator.begin(model: self) }

    // MARK: Persistence

    private func persist() {
        guard !isRestoring else { return }
        let s = PersistedSettings(aspectPreset: aspectPreset, customAspect: customAspect,
                                  tileCount: tileCount, exportSettings: exportSettings,
                                  lastExportFolderPath: lastExportFolderPath)
        if let data = try? JSONEncoder().encode(s) {
            defaults.set(data, forKey: Self.settingsKey)
        }
    }
}

/// Carries decoded results out of a detached task.
private struct LoadedImage: @unchecked Sendable {
    let source: SourceImage
    let preview: CGImage
}
