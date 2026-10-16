// AudioPinApp.swift
// Entry point. A menu-bar-only app (LSUIElement in Info.plist), so the only
// scene is the MenuBarExtra.

import SwiftUI

@main
struct AudioPinApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        // A pushpin, so it isn't mistaken for the system Sound icon.
        // Slashed when "Enforce pins" is off.
        MenuBarExtra("AudioPin", systemImage: state.enforcePins ? "pin.fill" : "pin.slash") {
            MenuBarView()
                .environmentObject(state)
        }
        .menuBarExtraStyle(.menu)
    }
}
