import SwiftUI
import TilerCore

/// Straighten, zoom, 90° rotation and reset.
struct AdjustSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section("Adjust") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Straighten")
                    Spacer()
                    TextField("Straighten", value: straighten, format: .number.precision(.fractionLength(0...1)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 52)
                    Text("°").foregroundStyle(.secondary)
                    Button {
                        model.straightenDegrees = 0
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset straighten")
                    .disabled(model.straightenDegrees == 0)
                }
                Slider(value: straighten, in: AppModel.straightenRange, step: 0.1)
                    .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Zoom")
                    Spacer()
                    Text(model.zoom.formatted(.number.precision(.fractionLength(2))) + "×")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                // Logarithmic: the slider value is ln(zoom).
                Slider(value: logZoom, in: 0...max(log(model.zoomRange.upperBound), 0.0001))
                    .labelsHidden()
                    .disabled(model.zoomRange.upperBound <= 1)
            }

            HStack {
                Button {
                    model.rotateLeft()
                } label: {
                    Label("Rotate Left", systemImage: "rotate.left")
                }
                Button {
                    model.rotateRight()
                } label: {
                    Label("Rotate Right", systemImage: "rotate.right")
                }
                Spacer()
                Button("Reset") { model.resetCrop() }
            }
            .labelStyle(.iconOnly)
            .help("Rotate 90° or reset the crop")
        }
    }

    private var straighten: Binding<Double> {
        Binding(get: { model.straightenDegrees }, set: { model.straightenDegrees = $0 })
    }

    private var logZoom: Binding<Double> {
        Binding(get: { log(model.zoom) }, set: { model.zoom = exp($0) })
    }
}
