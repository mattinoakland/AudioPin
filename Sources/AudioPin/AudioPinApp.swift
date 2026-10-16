// AudioPinApp.swift
// Entry point. A menu-bar-only app (LSUIElement in Info.plist), so the only
// scene is the MenuBarExtra.

import SwiftUI

@main
struct AudioPinApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra("AudioPin", systemImage: state.enforcePins ? "speaker.wave.2.fill" : "speaker.wave.2") {
            MenuBarView()
                .environmentObject(state)
        }
        .menuBarExtraStyle(.menu)
    }
}
