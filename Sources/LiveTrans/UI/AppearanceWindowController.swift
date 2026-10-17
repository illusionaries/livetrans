import AppKit
import SwiftUI

@MainActor
final class AppearanceWindowController {

    private let settings: AppearanceSettings
    private let audio: AudioSettings
    private var window: NSWindow?

    init(settings: AppearanceSettings, audio: AudioSettings) {
        self.settings = settings
        self.audio = audio
    }

    func show() {
        if window == nil {
            createWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func createWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 760),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.t("settings.title")
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(
            rootView: AppearanceSettingsView(settings: settings, audio: audio)
        )
        window.setFrameAutosaveName("LiveTransAppearance")
        self.window = window
    }
}
