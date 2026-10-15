import SwiftUI
import TilerCore

/// Output size, JPEG quality and the Export button. The export itself is `ExportCoordinator`.
struct ExportSection: View {
    @Bindable var model: AppModel

    /// True once the user picks "Custom width…" (or a saved size isn't one of the presets).
    @State private var customMode = false
    @State private var customWidthText = ""

    private enum Choice: Hashable {
        case preset(OutputSize)
        case custom
    }

    var body: some View {
        Section("Export") {
            Picker("Size", selection: choice) {
                ForEach(OutputSize.presets, id: \.self) { size in
                    let dims = pixelSize(of: size)
                    Text(label(for: size, dims: dims))
                        .tag(Choice.preset(size))
                        .disabled(dims == nil)
                }
                Divider()
                Text("Custom width…").tag(Choice.custom)
            }

            if customMode {
                HStack {
                    Text("Width")
                    Spacer()
                    TextField("Width", text: $customWidthText)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        .onSubmit(commitCustomWidth)
                    Text("px").foregroundStyle(.secondary)
                }
            }

            if let dims = pixelSize(of: model.exportSettings.size) {
                Text("Each tile: \(dims.width) × \(dims.height) px")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Quality")
                    Spacer()
                    Text("\(Int((model.exportSettings.quality * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: qualityBinding, in: ExportSettings.qualityRange, step: 0.01)
                    .labelsHidden()
            }

            Button("Export Tiles…") { model.requestExport() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canExport)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear(perform: syncCustomState)
    }

    // MARK: Bindings

    private var choice: Binding<Choice> {
        Binding(
            get: {
                if customMode { return .custom }
                return .preset(model.exportSettings.size)
            },
            set: { newValue in
                switch newValue {
                case .preset(let size):
                    customMode = false
                    model.exportSettings.size = size
                case .custom:
                    customMode = true
                    let native = model.nativeTileSize.width
                    let start: Int
                    if case .width(let w) = model.exportSettings.size { start = w } else { start = min(native, 1080) }
                    customWidthText = String(max(start, 1))
                    commitCustomWidth()
                }
            })
    }

    private var qualityBinding: Binding<Double> {
        Binding(get: { model.exportSettings.quality },
                set: { model.exportSettings.quality = $0 })
    }

    // MARK: Helpers

    private func syncCustomState() {
        if case .width(let w) = model.exportSettings.size, !OutputSize.presets.contains(.width(w)) {
            customMode = true
            customWidthText = String(w)
        }
    }

    /// Parses the custom width, clamps it to 1...native (never upscale) and stores it.
    private func commitCustomWidth() {
        guard let w = Int(customWidthText.trimmingCharacters(in: .whitespaces)), w > 0 else { return }
        let native = model.nativeTileSize.width
        let clamped = native > 0 ? min(w, native) : w
        customWidthText = String(clamped)
        model.exportSettings.size = .width(clamped)
    }

    /// Resulting pixel size for `size` at the current native size and aspect, or nil when it
    /// would upscale (or there is no image).
    private func pixelSize(of size: OutputSize) -> (width: Int, height: Int)? {
        let native = model.nativeTileSize
        guard native.width > 0, isAvailable(size, native: native) else { return nil }
        return size.pixelSize(native: native, aspect: model.aspect)
    }

    private func label(for size: OutputSize, dims: (width: Int, height: Int)?) -> String {
        switch size {
        case .native:
            if let d = dims { return "Maximum (\(d.width) × \(d.height))" }
            return "Maximum"
        case .width(let w):
            if let d = dims { return "\(d.width) × \(d.height)" }
            return "\(w) px (larger than native)"
        }
    }
}
