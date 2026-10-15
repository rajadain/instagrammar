import SwiftUI

/// Fixed-width right-hand inspector: tile layout, adjustments and export options.
struct InspectorView: View {
    @Bindable var model: AppModel

    static let width: CGFloat = 280

    var body: some View {
        Form {
            TileSection(model: model)
            AdjustSection(model: model)
                .disabled(!model.hasImage)
            ExportSection(model: model)
                .disabled(!model.hasImage)
        }
        .formStyle(.grouped)
        .frame(width: Self.width)
    }
}
