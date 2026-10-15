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

/// One tile at a time at phone size, with arrows, keys, swipe and a page indicator.
struct CarouselPreviewSheet: View {
    @State private var model: CarouselPreviewModel
    let onDone: () -> Void
    @State private var scrollMonitor: Any?
    @FocusState private var focused: Bool

    init(job: CarouselPreviewJob, onDone: @escaping () -> Void) {
        _model = State(initialValue: CarouselPreviewModel(job: job))
        self.onDone = onDone
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                navButton("chevron.left", label: "Previous tile", enabled: model.canGoPrevious) { model.previous() }
                tileView
                navButton("chevron.right", label: "Next tile", enabled: model.canGoNext) { model.next() }
            }
            indicator
            Button("Done", action: onDone)
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { model.previous(); return .handled }
        .onKeyPress(.rightArrow) { model.next(); return .handled }
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
        return ZStack {
            Rectangle().fill(Color.black.opacity(0.06))
            if let image = model.tiles[model.index] {
                Image(decorative: image, scale: model.backingScale)
                    .resizable()
                    .frame(width: size.width, height: size.height)
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .accessibilityLabel("Tile \(model.index + 1) of \(model.count)")
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

    /// Two-finger horizontal swipe: one tile per gesture once it travels far enough.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        var travelled: CGFloat = 0
        var fired = false
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
            if event.phase.contains(.began) { travelled = 0; fired = false }
            travelled += event.scrollingDeltaX
            if !fired, abs(travelled) > 40 {
                fired = true
                // Natural scrolling: fingers moving left (negative delta) reveal the next tile.
                if travelled < 0 { model.next() } else { model.previous() }
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) { travelled = 0; fired = false }
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }
}
