import AppKit
import SwiftUI

@main
struct InstagrammarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    init() {
        launchURL = LaunchArguments.takeFileURL()
    }

    var body: some Scene {
        Window("Instagrammar", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.presentOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Export Tiles…") { model.requestExport() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(!model.hasImage)
            }
            CommandMenu("Image") {
                Button("Rotate Left") { model.rotateLeft() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!model.hasImage)
                Button("Rotate Right") { model.rotateRight() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!model.hasImage)
                Divider()
                Button("Reset Crop") { model.resetCrop() }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(!model.hasImage)
            }
        }
    }
}

/// File passed on the command line (`open Instagrammar.app --args /path/img.jpg`), captured in
/// `InstagrammarApp.init` before AppKit starts.
nonisolated(unsafe) private var launchURL: URL?

enum LaunchArguments {
    /// Returns the first existing file path among the process arguments (ignoring `-flag`
    /// arguments) and tells AppKit not to treat bare arguments as documents to open.
    ///
    /// Without `NSTreatUnknownArgumentsAsOpen = NO`, AppKit treats a bare path as a document
    /// opened at launch and SwiftUI then declines to create the main window at all (verified:
    /// even `--args foo` leaves the app windowless). We open the file ourselves instead.
    static func takeFileURL() -> URL? {
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
        return AppModel.launchArgumentURL()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed so a SwiftPM-built binary gets a menu bar and focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // `open Instagrammar.app --args /path/to/img.jpg` (also handy for agents).
        if let url = launchURL {
            Task { @MainActor in AppModel.shared.openInBackground(url: url) }
        }
    }

    /// Dock-icon drops and Finder "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.isFileURL }) else { return }
        Task { @MainActor in AppModel.shared.openInBackground(url: url) }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        Task { @MainActor in AppModel.shared.openInBackground(url: url) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
