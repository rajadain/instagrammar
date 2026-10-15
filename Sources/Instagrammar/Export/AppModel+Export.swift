import TilerCore

extension AppModel {
    /// An image is loaded and no export is in progress.
    var canExport: Bool { hasImage && !exportCoordinator.isExporting }

    /// Captures the current document state for the exporter (call on the main actor).
    func makeExportJob() -> ExportJob? {
        guard hasImage, let source else { return nil }
        return ExportJob(source: source, quarterTurns: quarterTurns, crop: crop,
                         spec: spec, settings: exportSettings)
    }
}
