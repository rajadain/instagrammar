import AppKit
import Observation
import TilerCore

/// A snapshot of the document taken when the carousel preview opens.
struct CarouselPreviewJob {
    var preview: CGImage
    var quarterTurns: QuarterTurns
    var orientedSize: CGSize
    var crop: CropState
    var spec: TileSpec
}

extension AppModel {
    /// Preview needs a loaded image (menu, toolbar and ⌘P are disabled otherwise).
    var canPreviewCarousel: Bool { hasImage }

    func makeCarouselPreviewJob() -> CarouselPreviewJob? {
        guard let source, let preview else { return nil }
        return CarouselPreviewJob(preview: preview, quarterTurns: quarterTurns,
                                  orientedSize: source.orientedSize, crop: crop, spec: spec)
    }

    func showCarouselPreview() {
        if canPreviewCarousel { isShowingCarouselPreview = true }
    }
}

/// Renders every tile of the carousel at phone size and tracks the visible one.
@Observable
@MainActor
final class CarouselPreviewModel {
    /// Phone-like display width of a tile, in points.
    static let displayWidth: CGFloat = 390
    /// Tall custom aspects are shrunk so the sheet stays on screen.
    static let maxDisplayHeight: CGFloat = 640
    /// Tiles rendered at once.
    static let maxConcurrentRenders = 3

    let job: CarouselPreviewJob
    let backingScale: CGFloat
    /// Tile size in points.
    let displaySize: CGSize
    /// Tile size in pixels.
    let pixelSize: CGSize
    private(set) var tiles: [CGImage?]
    var index = 0

    @ObservationIgnored private var renderTask: Task<Void, Never>?
    nonisolated private static let renderer = PreviewTileRenderer()

    var count: Int { job.spec.count }

    init(job: CarouselPreviewJob, backingScale: CGFloat? = nil) {
        self.job = job
        let scale = backingScale ?? NSScreen.main?.backingScaleFactor ?? 2
        self.backingScale = scale
        let aspect = job.spec.aspect
        let ratio = CGFloat(aspect.width / aspect.height)
        let width = min(Self.displayWidth, Self.maxDisplayHeight * ratio)
        // Whole pixels, so the rendered image fills its frame exactly.
        let pixels = PreviewTileRenderer.tilePixelSize(pixelWidth: Int((width * scale).rounded()), aspect: aspect)
        pixelSize = pixels
        displaySize = CGSize(width: pixels.width / scale, height: pixels.height / scale)
        tiles = Array(repeating: nil, count: job.spec.count)
    }

    // MARK: Navigation

    var canGoPrevious: Bool { index > 0 }
    var canGoNext: Bool { index < count - 1 }
    func previous() { if canGoPrevious { index -= 1 } }
    func next() { if canGoNext { index += 1 } }

    // MARK: Rendering

    /// Renders all tiles in the background, a few at a time. Safe to call once.
    func start() {
        guard renderTask == nil else { return }
        renderTask = Task { [job, pixelSize] in
            let total = job.spec.count
            await withTaskGroup(of: (Int, CGImage?).self) { group in
                var nextIndex = 0
                func submit() {
                    guard nextIndex < total else { return }
                    let i = nextIndex
                    nextIndex += 1
                    group.addTask(priority: .userInitiated) {
                        (i, Self.renderTile(job: job, index: i, pixelSize: pixelSize))
                    }
                }
                for _ in 0..<Self.maxConcurrentRenders { submit() }
                while let (i, image) = await group.next() {
                    if Task.isCancelled { group.cancelAll(); break }
                    tiles[i] = image
                    submit()
                }
            }
        }
    }

    /// Waits until every tile has been rendered (or the task was cancelled).
    func waitUntilRendered() async {
        start()
        await renderTask?.value
    }

    func cancel() {
        renderTask?.cancel()
        renderTask = nil
    }

    nonisolated private static func renderTile(job: CarouselPreviewJob, index: Int, pixelSize: CGSize) -> CGImage? {
        renderer.render(preview: job.preview, quarterTurns: job.quarterTurns,
                        orientedSize: job.orientedSize, state: job.crop, spec: job.spec,
                        index: index, outputSize: pixelSize)
    }
}
