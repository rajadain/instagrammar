import AppKit
import SwiftUI
import TilerCore

extension View {
    /// Presents the carousel preview sheet (⌘P) while `model.isShowingCarouselPreview` is set.
    func carouselPreviewSheet(_ model: AppModel) -> some View {
        @Bindable var model = model
        return sheet(isPresented: $model.isShowingCarouselPreview) {
            if let job = model.makeCarouselPreviewJob() {
                CarouselPreviewSheet(job: job) { model.isShowingCarouselPreview = false }
            }
        }
    }
}

/// Toolbar button that opens the carousel preview.
struct CarouselPreviewButton: View {
    var model: AppModel

    var body: some View {
        Button { model.showCarouselPreview() } label: {
            Label("Preview Carousel", systemImage: "rectangle.split.3x1")
        }
        .disabled(!model.canPreviewCarousel)
        .help("Preview the carousel (⌘P)")
    }
}

/// A phone-sized window sliding over the tiles laid edge to edge, like Instagram's carousel, so
/// the seams are visible mid-slide. Arrows, keys, mouse drag and trackpad swipe all slide.
struct CarouselPreviewSheet: View {
    @State private var model: CarouselPreviewModel
    let onDone: () -> Void
    @State private var scrollMonitor: Any?
    @FocusState private var focused: Bool
    /// Live drag/swipe translation in points (negative = towards the next tile).
    @State private var dragOffset: CGFloat = 0

    private static let slide = Animation.spring(response: 0.4, dampingFraction: 0.9)

    init(job: CarouselPreviewJob, onDone: @escaping () -> Void) {
        _model = State(initialValue: CarouselPreviewModel(job: job))
        self.onDone = onDone
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                navButton("chevron.left", label: "Previous tile", enabled: model.canGoPrevious) { slide { model.previous() } }
                tileView
                navButton("chevron.right", label: "Next tile", enabled: model.canGoNext) { slide { model.next() } }
            }
            indicator
            Button("Done", action: onDone)
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { slide { model.previous() }; return .handled }
        .onKeyPress(.rightArrow) { slide { model.next() }; return .handled }
        .onAppear {
            focused = true
            model.start()
            installScrollMonitor()
        }
        .onDisappear {
            model.cancel()
            removeScrollMonitor()
        }
    }

    private var tileView: some View {
        let size = model.displaySize
        return HStack(spacing: 0) {
            ForEach(0..<model.count, id: \.self) { i in
                tileImage(i).frame(width: size.width, height: size.height)
            }
        }
        .fixedSize()
        .offset(x: -CGFloat(model.index) * size.width + dragOffset)
        .frame(width: size.width, height: size.height, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    dragOffset = model.resistedTranslation(value.translation.width, width: size.width)
                }
                .onEnded { value in
                    settle(translation: value.predictedEndTranslation.width)
                }
        )
        .accessibilityLabel("Tile \(model.index + 1) of \(model.count)")
    }

    @ViewBuilder
    private func tileImage(_ i: Int) -> some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.06))
            if let image = model.tiles[i] {
                Image(decorative: image, scale: model.backingScale)
                    .resizable()
            } else {
                ProgressView().controlSize(.large)
            }
        }
    }

    // MARK: Sliding

    private func slide(_ change: () -> Void) {
        withAnimation(Self.slide) {
            change()
            dragOffset = 0
        }
    }

    /// Ends a drag or swipe: slide to the chosen tile, or spring back.
    private func settle(translation: CGFloat) {
        let target = model.settledIndex(translation: translation, width: model.displaySize.width)
        slide { model.index = target }
    }

    private var indicator: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(0..<min(model.count, 20), id: \.self) { i in
                    Circle()
                        .fill(i == model.index ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                }
            }
            Text("\(model.index + 1) / \(model.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func navButton(_ symbol: String, label: String, enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .frame(width: 32, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .accessibilityLabel(label)
    }

    // MARK: Trackpad swipe

    /// Two-finger horizontal swipe drags the strip with the fingers, then settles on release.
    /// A (non-precise) mouse wheel tilt steps one tile.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        var tracking = false
        var raw: CGFloat = 0
        var lastDelta: CGFloat = 0
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Swallow the momentum that follows a swipe; settle() already animates the rest.
            if !event.momentumPhase.isEmpty { return tracking ? event : nil }

            if !event.hasPreciseScrollingDeltas {
                guard event.scrollingDeltaX != 0, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
                slide { event.scrollingDeltaX < 0 ? model.next() : model.previous() }
                return nil
            }

            if event.phase.contains(.began) {
                guard abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) else { return event }
                tracking = true
                raw = 0
            }
            guard tracking else { return event }

            // Natural scrolling: fingers moving left (negative delta) pull the next tile in.
            raw += event.scrollingDeltaX
            lastDelta = event.scrollingDeltaX
            let width = model.displaySize.width
            dragOffset = model.resistedTranslation(raw, width: width)

            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                tracking = false
                // A quick flick counts as a full swipe even if it travelled less than a quarter tile.
                settle(translation: raw + lastDelta * 10)
            }
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }
}
