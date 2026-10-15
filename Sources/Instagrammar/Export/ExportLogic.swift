import Foundation
import TilerCore

/// Everything an export needs, captured on the main actor so the exporter can run off it.
struct ExportJob: @unchecked Sendable {
    let source: SourceImage
    let quarterTurns: QuarterTurns
    let crop: CropState
    let spec: TileSpec
    let settings: ExportSettings

    /// The files this job will write, in tile order.
    var outputs: [TileOutput] {
        plan(state: crop, spec: spec, quarterTurns: quarterTurns, settings: settings, stem: source.stem)
    }
}

/// Non-UI export logic, kept free of AppKit so it can be exercised without panels or alerts.
enum ExportLogic {
    /// File names in `outputs` that already exist in `folder`, in tile order.
    static func collidingFileNames(
        outputs: [TileOutput], in folder: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [String] {
        outputs.map(\.fileName).filter { fileExists(folder.appendingPathComponent($0)) }
    }

    /// Where the folder panel should open (P8): the last export folder if it still exists, else
    /// the folder containing the source image.
    static func panelDirectory(
        lastExportFolderPath: String?, sourceURL: URL?,
        directoryExists: (String) -> Bool = {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
        }
    ) -> URL? {
        if let path = lastExportFolderPath, !path.isEmpty, directoryExists(path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return sourceURL?.deletingLastPathComponent()
    }

    /// Runs the exporter into `folder`. If the export is cancelled or fails, every planned file
    /// written during this run is deleted (a replaced file counts as written: its old contents
    /// are already gone, and a half-new set is worse than none), then the error is rethrown.
    /// A cancellation that arrives after the last tile was written still deletes the tiles.
    static func run(job: ExportJob, to folder: URL, exporter: TileExporter,
                    progress: @Sendable (Int, Int) -> Void) async throws -> [URL] {
        let planned = job.outputs.map { folder.appendingPathComponent($0.fileName) }
        let before = modificationDates(of: planned)
        do {
            let urls = try await exporter.export(
                source: job.source, quarterTurns: job.quarterTurns, state: job.crop,
                spec: job.spec, settings: job.settings, to: folder, progress: progress)
            try Task.checkCancellation()
            return urls
        } catch {
            let after = modificationDates(of: planned)
            for url in planned {
                if let now = after[url], now != before[url] {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            throw error
        }
    }

    /// Modification dates of the files that exist (missing files are absent from the result).
    private static func modificationDates(of urls: [URL]) -> [URL: Date] {
        var result: [URL: Date] = [:]
        for url in urls {
            if let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date {
                result[url] = date
            }
        }
        return result
    }

    // MARK: Strings

    static func collisionTitle(count: Int, folderName: String) -> String {
        count == 1 ? "1 file already exists in \u{2018}\(folderName)\u{2019}. Replace it?"
                   : "\(count) files already exist in \u{2018}\(folderName)\u{2019}. Replace them?"
    }

    static func successMessage(count: Int) -> String {
        count == 1 ? "Exported 1 tile" : "Exported \(count) tiles"
    }

    /// "Exporting tile 2 of 3…" while `done` tiles are finished.
    static func progressMessage(done: Int, total: Int) -> String {
        "Exporting tile \(min(done + 1, max(total, 1))) of \(total)\u{2026}"
    }
}
