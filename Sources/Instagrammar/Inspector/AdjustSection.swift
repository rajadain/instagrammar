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
                        model.performEdit("Straighten") { model.straightenDegrees = 0 }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset straighten")
                    .disabled(model.straightenDegrees == 0)
                }
                // A drag is one undo step, recorded when it ends. Double-click resets to 0°.
                PlainSlider(label: "Straighten", value: straighten, range: AppModel.straightenRange,
                            onEditingChanged: { editing in
                                if editing { model.beginEdit("Straighten") } else { model.endEdit() }
                            },
                            onReset: { model.performEdit("Straighten") { model.straightenDegrees = 0 } })
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Zoom")
                    Spacer()
                    Text(model.zoom.formatted(.number.precision(.fractionLength(2))) + "×")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                // Logarithmic: the slider value is ln(zoom). Double-click resets to 1×.
                PlainSlider(label: "Zoom", value: logZoom, range: 0...max(log(model.zoomRange.upperBound), 0.0001),
                            onEditingChanged: { editing in
                                if editing { model.beginEdit("Zoom") } else { model.endEdit() }
                            },
                            onReset: { model.performEdit("Zoom") { model.zoom = 1 } })
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
        Binding(get: { model.straightenDegrees },
                set: { v in
                    // Keep the 0.1° resolution the slider used to enforce with `step`.
                    let rounded = (v * 10).rounded() / 10
                    model.performEdit("Straighten") { model.straightenDegrees = rounded }
                })
    }

    private var logZoom: Binding<Double> {
        Binding(get: { log(model.zoom) },
                set: { v in model.performEdit("Zoom") { model.zoom = exp(v) } })
    }
}
