import SwiftUI
import TilerCore

/// Aspect preset, custom W:H, tile count and the native tile size read-out.
struct TileSection: View {
    @Bindable var model: AppModel

    @State private var widthText = ""
    @State private var heightText = ""

    var body: some View {
        Section("Tiles") {
            Picker("Aspect", selection: $model.aspectPreset) {
                ForEach(AspectPreset.allCases, id: \.self) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }

            if model.aspectPreset == .custom {
                HStack(spacing: 6) {
                    TextField("W", text: $widthText)
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                    Text(":")
                    TextField("H", text: $heightText)
                        .labelsHidden()
                }
                .onChange(of: widthText) { _, _ in commitCustom() }
                .onChange(of: heightText) { _, _ in commitCustom() }
                if !customInputIsValid {
                    Label("Use positive numbers with a ratio between 1:5 and 5:1.",
                          systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Text("Count")
                Spacer()
                TextField("Count", value: $model.tileCount, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 44)
                Stepper("Count", value: $model.tileCount, in: TileSpec.countRange)
                    .labelsHidden()
            }

            if model.hasImage {
                let size = model.nativeTileSize
                Text("Each tile: \(size.width) × \(size.height) px (native)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if size.width < 1080 {
                    Label("Tiles are narrower than 1080 px; Instagram will upscale them.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .onAppear(perform: syncFromModel)
        .onChange(of: model.aspectPreset) { _, _ in syncFromModel() }
    }

    // MARK: Custom aspect input

    private var parsedInput: (w: Double, h: Double)? {
        guard let w = Double(widthText.trimmingCharacters(in: .whitespaces)),
              let h = Double(heightText.trimmingCharacters(in: .whitespaces))
        else { return nil }
        return (w, h)
    }

    private var customInputIsValid: Bool {
        guard let p = parsedInput else { return false }
        return AppModel.customAspect(width: p.w, height: p.h) != nil
    }

    private func commitCustom() {
        guard let p = parsedInput else { return }
        model.setCustomAspect(width: p.w, height: p.h)
    }

    private func syncFromModel() {
        widthText = Self.format(model.customAspect.width)
        heightText = Self.format(model.customAspect.height)
    }

    private static func format(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...3)).grouping(.never))
    }
}
