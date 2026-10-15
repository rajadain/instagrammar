#if DEBUG
import AppKit
import Foundation
import TilerCore

/// Headless check of the non-UI export path. Run the debug binary as
/// `INSTAGRAMMAR_EXPORT_SELFTEST=<existing folder> .build/debug/Instagrammar <image>`: it opens
/// the image, exports with the default settings into the folder (no panels), checks collision
/// detection, panel-directory choice and cancel cleanup, prints PASS/FAIL and the file list to
/// stderr, then quits.
@MainActor
enum ExportSelfTest {
    static let variable = "INSTAGRAMMAR_EXPORT_SELFTEST"

    /// Returns true when the self-test was requested (and started).
    static func runIfRequested(url: URL) -> Bool {
        guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty else { return false }
        Task { @MainActor in
            let ok = await run(image: url, folder: URL(fileURLWithPath: path, isDirectory: true))
            FileHandle.standardError.write(Data((ok ? "SELFTEST PASS\n" : "SELFTEST FAIL\n").utf8))
            exit(ok ? 0 : 1)
        }
        return true
    }

    private final class TaskBox: @unchecked Sendable { var task: Task<[URL], Error>? }

    private static func run(image: URL, folder: URL) async -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ what: String) {
            log((condition ? "  ok   " : "  FAIL ") + what)
            if !condition { failures.append(what) }
        }

        let model = AppModel.shared
        await model.open(url: image)
        guard let job = model.makeExportJob() else {
            log("FAIL: image did not load")
            return false
        }
        let outputs = job.outputs
        let names = outputs.map(\.fileName)
        log("planned: \(names.joined(separator: ", "))")

        // 1. Collision detection: none before, all after.
        check(ExportLogic.collidingFileNames(outputs: outputs, in: folder).isEmpty, "no collisions in empty folder")

        // 2. Export through the coordinator (everything but the panel and alerts).
        var alerts: [ModelAlert] = []
        let written = await model.exportCoordinator.export(job: job, to: folder) { alerts.append($0) }
        check(alerts.isEmpty, "no error alert")
        check(written?.map(\.lastPathComponent) == names, "returned URLs match the plan")
        check(model.exportCoordinator.banner?.message == ExportLogic.successMessage(count: names.count),
              "success banner set (\(model.exportCoordinator.banner?.message ?? "nil"))")
        check(model.exportCoordinator.tilesDone == names.count, "progress reached \(names.count)/\(names.count)")
        check(ExportLogic.collidingFileNames(outputs: outputs, in: folder) == names, "all tiles collide after export")
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.sorted() ?? []
        log("files in folder: \(listing.joined(separator: ", "))")
        check(listing == names.sorted(), "folder holds exactly the tiles (no temp files)")
        let attrs = names.map { (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent($0).path))?[.size] as? Int ?? 0 }
        check(attrs.allSatisfy { $0 > 0 }, "tiles are non-empty")

        // 3. Panel directory choice.
        check(ExportLogic.panelDirectory(lastExportFolderPath: folder.path, sourceURL: image)?.path == folder.path,
              "panel opens at last folder when it exists")
        check(ExportLogic.panelDirectory(lastExportFolderPath: folder.appendingPathComponent("gone").path, sourceURL: image)?.path
                == image.deletingLastPathComponent().path, "panel falls back to the source folder")
        check(ExportLogic.panelDirectory(lastExportFolderPath: nil, sourceURL: image)?.path
                == image.deletingLastPathComponent().path, "panel uses the source folder with no history")

        // 4. Cancel cleanup: cancel as soon as the first tile is done; no tiles may remain,
        //    unrelated files must stay.
        let cancelFolder = folder.appendingPathComponent("cancel-test", isDirectory: true)
        try? FileManager.default.createDirectory(at: cancelFolder, withIntermediateDirectories: true)
        let keep = cancelFolder.appendingPathComponent("keep.txt")
        try? Data("keep".utf8).write(to: keep)
        let box = TaskBox()
        let exporter = TileExporter()
        box.task = Task.detached {
            try await ExportLogic.run(job: job, to: cancelFolder, exporter: exporter) { done, _ in
                if done >= 1 { box.task?.cancel() }
            }
        }
        var cancelled = false
        do { _ = try await box.task!.value } catch is CancellationError { cancelled = true } catch {
            log("unexpected error: \(error)")
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: cancelFolder.path))?.sorted() ?? []
        log("after cancel: \(left.joined(separator: ", "))")
        check(cancelled, "cancelled export throws CancellationError")
        check(left == ["keep.txt"], "cancel deleted the tiles and left other files")

        if !failures.isEmpty { log("failures: \(failures.joined(separator: "; "))") }
        return failures.isEmpty
    }

    private static func log(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
#endif
