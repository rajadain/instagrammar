import SwiftUI
import TilerCore

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            canvasArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            InspectorView(model: model)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 4)
                    .background(Color.accentColor.opacity(0.08))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.isFileURL }) else { return false }
            model.openInBackground(url: url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .toolbar { toolbarContent }
        .exportPresentation(model.exportCoordinator)
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message),
                  dismissButton: .default(Text("OK")))
        }
    }

    @ViewBuilder
    private var canvasArea: some View {
        if let source = model.source, let preview = model.preview {
            CropCanvas(preview: preview,
                       quarterTurns: model.quarterTurns,
                       crop: model.crop,
                       spec: model.spec,
                       orientedSize: source.orientedSize,
                       onCropChange: { model.update(crop: $0) })
                .overlay {
                    if model.isLoading { ProgressView().controlSize(.large) }
                }
        } else if model.isLoading {
            ProgressView("Opening…").controlSize(.large)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Drop a photo here or press ⌘O")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Button("Open…") { model.presentOpenPanel() }
                    .controlSize(.large)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.presentOpenPanel() } label: {
                Label("Open", systemImage: "folder")
            }
            .help("Open a photo (⌘O)")
        }
        ToolbarItemGroup(placement: .principal) {
            Button { model.rotateLeft() } label: {
                Label("Rotate Left", systemImage: "rotate.left")
            }
            .help("Rotate left (⌘[)")
            Button { model.rotateRight() } label: {
                Label("Rotate Right", systemImage: "rotate.right")
            }
            .help("Rotate right (⌘])")
            Button { model.resetCrop() } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .help("Reset crop (⌘0)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.requestExport() } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canExport)
            .help("Export tiles (⌘E)")
        }
    }
}
