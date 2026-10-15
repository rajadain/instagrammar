import AppKit

/// App menu > About Instagrammar: the standard panel with credits and the Info.plist version.
enum AboutPanel {
    @MainActor
    static func show() {
        let info = Bundle.main.infoDictionary ?? [:]
        let credits = NSAttributedString(
            string: "Seamless Instagram carousels from wide photos.",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
            ])
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Instagrammar",
            .credits: credits,
        ]
        if let short = info["CFBundleShortVersionString"] as? String { options[.applicationVersion] = short }
        if let build = info["CFBundleVersion"] as? String { options[.version] = build }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }
}
