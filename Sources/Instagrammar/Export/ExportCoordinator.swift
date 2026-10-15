import AppKit
import Observation
import TilerCore

/// A transient "Exported N tiles" notice with a Show in Finder button.
struct ExportBanner: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let urls: [URL]
}

/// Drives an export from the user's point of view: folder panel, overwrite check, progress,
/// cancellation, success banner and errors. Owns the single `TileExporter`.
@Observable
@MainActor
final class ExportCoordinator {
    /// True from the moment the user asks to export until the run (or the user) finishes.
    private(set) var isExporting = false
    /// True once a run has been going long enough that the progress sheet should show.
    private(set) var showsProgress = false
    private(set) var tilesDone = 0
    private(set) var tilesTotal = 1
    private(set) var banner: ExportBanner?

    @ObservationIgnored private let exporter = TileExporter()
    @ObservationIgnored private var runTask: Task<[URL], Error>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var progressTask: Task<Void, Never>?

    var fractionDone: Double { tilesTotal > 0 ? Double(tilesDone) / Double(tilesTotal) : 0 }
    var progressMessage: String { ExportLogic.progressMessage(done: tilesDone, total: tilesTotal) }

    /// How long a run takes before the progress sheet appears (fast exports never flash it).
    private static let progressDelay: Duration = .milliseconds(350)
    private static let bannerDuration: Duration = .seconds(4)

    // MARK: Entry points

    /// ⌘E / toolbar / inspector button. Asks for a folder, resolves collisions, then exports.
    func begin(model: AppModel) {
        guard !isExporting, let job = model.makeExportJob() else { return }
        isExporting = true
        dismissBanner()
        Task { await runFlow(job: job, model: model) }
    }

    /// Cancel button of the progress sheet.
    func cancel() { runTask?.cancel() }

    func dismissBanner() {
        bannerTask?.cancel()
        banner = nil
    }

    func showInFinder(_ banner: ExportBanner) {
        NSWorkspace.shared.activateFileViewerSelecting(banner.urls)
        dismissBanner()
    }

    // MARK: Flow

    private func runFlow(job: ExportJob, model: AppModel) async {
        defer { isExporting = false }
        guard let folder = chooseFolder(job: job, model: model) else { return }
        model.lastExportFolderPath = folder.path

        let collisions = ExportLogic.collidingFileNames(outputs: job.outputs, in: folder)
        if !collisions.isEmpty {
            guard await confirmReplace(count: collisions.count, folder: folder) else { return }
        }
        await export(job: job, to: folder, onError: { model.alert = $0 })
    }

    /// Runs the export with progress state, the banner and error reporting. No panels, so the
    /// self-test can call it directly. Returns the written files (nil if cancelled or failed).
    @discardableResult
    func export(job: ExportJob, to folder: URL, onError: (ModelAlert) -> Void) async -> [URL]? {
        tilesDone = 0
        tilesTotal = job.spec.count
        showsProgress = false
        progressTask = Task { [weak self] in
            try? await Task.sleep(for: Self.progressDelay)
            guard !Task.isCancelled else { return }
            self?.showsProgress = true
        }
        let exporter = self.exporter
        let report: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in self?.record(done: done, total: total) }
        }
        let task = Task.detached(priority: .userInitiated) { () -> [URL] in
            try await ExportLogic.run(job: job, to: folder, exporter: exporter, progress: report)
        }
        runTask = task
        defer {
            runTask = nil
            progressTask?.cancel()
            showsProgress = false
        }
        do {
            let urls = try await task.value
            show(ExportBanner(message: ExportLogic.successMessage(count: urls.count), urls: urls))
            return urls
        } catch is CancellationError {
            // User cancelled; tiles written during this run were already deleted.
        } catch {
            onError(ModelAlert(
                title: "Export failed",
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
        return nil
    }

    private func record(done: Int, total: Int) {
        tilesTotal = total
        tilesDone = max(tilesDone, done)   // hops can arrive out of order
    }

    private func show(_ new: ExportBanner) {
        bannerTask?.cancel()
        banner = new
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: Self.bannerDuration)
            guard !Task.isCancelled else { return }
            if self?.banner?.id == new.id { self?.banner = nil }
        }
    }

    // MARK: Panels

    private func chooseFolder(job: ExportJob, model: AppModel) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Export Tiles"
        panel.message = "Choose a folder for the \(job.spec.count) tile\(job.spec.count == 1 ? "" : "s")."
        panel.prompt = "Export Here"
        panel.directoryURL = ExportLogic.panelDirectory(
            lastExportFolderPath: model.lastExportFolderPath, sourceURL: job.source.url)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Replace / Cancel alert; Cancel is the default button (Return).
    private func confirmReplace(count: Int, folder: URL) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = ExportLogic.collisionTitle(count: count, folderName: folder.lastPathComponent)
        alert.informativeText = "Replacing overwrites the existing files."
        alert.addButton(withTitle: "Cancel")    // first button = default
        let replace = alert.addButton(withTitle: "Replace")
        replace.hasDestructiveAction = true
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return response == .alertSecondButtonReturn
    }
}
