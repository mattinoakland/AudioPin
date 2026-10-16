// AudioPinApp.swift
// Entry point. A menu-bar-only app (LSUIElement in Info.plist): no windows,
// just the status item that MenuBarController owns.

import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState?
    private var menuBar: MenuBarController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt and braces with LSUIElement: never show a Dock icon.
        NSApplication.shared.setActivationPolicy(.accessory)
        let state = AppState()
        self.state = state
        menuBar = MenuBarController(state: state)
    }
}
