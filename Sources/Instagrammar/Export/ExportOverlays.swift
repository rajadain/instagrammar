import SwiftUI

/// Progress sheet and success banner, both driven by `ExportCoordinator`.
private struct ExportPresentation: ViewModifier {
    var coordinator: ExportCoordinator

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: .constant(coordinator.showsProgress && coordinator.isExporting)) {
                ExportProgressSheet(coordinator: coordinator)
                    .interactiveDismissDisabled()
            }
            .overlay(alignment: .bottom) {
                if let banner = coordinator.banner {
                    ExportBannerView(banner: banner, coordinator: coordinator)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: coordinator.banner)
    }
}

extension View {
    func exportPresentation(_ coordinator: ExportCoordinator) -> some View {
        modifier(ExportPresentation(coordinator: coordinator))
    }
}

private struct ExportProgressSheet: View {
    var coordinator: ExportCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(coordinator.progressMessage)
                .font(.headline)
            ProgressView(value: coordinator.fractionDone)
            HStack {
                Spacer()
                Button("Cancel") { coordinator.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

private struct ExportBannerView: View {
    let banner: ExportBanner
    var coordinator: ExportCoordinator

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(banner.message)
            Button("Show in Finder") { coordinator.showInFinder(banner) }
            Button { coordinator.dismissBanner() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 8, y: 2)
    }
}
