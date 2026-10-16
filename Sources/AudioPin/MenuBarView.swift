// MenuBarView.swift
// The dropdown under the menu bar icon. Pure presentation; all behavior
// goes through AppState.

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Section("Now playing through") {
            Text("Output: \(state.currentOutput?.name ?? "Unknown")")
            Text("Input: \(state.currentInput?.name ?? "Unknown")")
        }

        Section("Pinned output") {
            ForEach(state.outputDevices) { device in
                Toggle(device.name, isOn: pinBinding(for: device, kind: .output))
            }
            if let name = state.pinnedOutputName, state.pinnedOutputUID != nil, !state.pinnedOutputConnected {
                Text("\(name) (not connected)")
            }
            if state.pinnedOutputUID != nil {
                Button("Clear output pin") { state.pinOutput(nil) }
            }
        }

        Section("Pinned input") {
            ForEach(state.inputDevices) { device in
                Toggle(device.name, isOn: pinBinding(for: device, kind: .input))
            }
            if let name = state.pinnedInputName, state.pinnedInputUID != nil, !state.pinnedInputConnected {
                Text("\(name) (not connected)")
            }
            if state.pinnedInputUID != nil {
                Button("Clear input pin") { state.pinInput(nil) }
            }
        }

        Divider()

        // Phase 2: one submenu per app. Apps with a rule are listed first so
        // the ones you care about are easy to find.
        Menu("App routing") {
            let routed = state.routableApps.filter { state.routeRules[$0.bundleID] != nil }
            let others = state.routableApps.filter { state.routeRules[$0.bundleID] == nil }

            if routed.isEmpty {
                Text("Pick an app below to send its audio to a specific device.")
            } else {
                Section("Routed") {
                    ForEach(routed) { app in appMenu(app) }
                }
            }
            Section("Running apps") {
                ForEach(others) { app in appMenu(app) }
            }
        }

        Divider()

        Toggle("Enforce pins", isOn: $state.enforcePins)

        Toggle("Launch at login", isOn: Binding(
            get: { state.launchAtLogin },
            set: { state.setLaunchAtLogin($0) }
        ))
        if let message = state.launchAtLoginMessage {
            Text(message)
        }

        Divider()

        Button("Refresh devices") { state.refreshAndEnforce() }
        Button("Quit AudioPin") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    // MARK: - Per-app submenu

    @ViewBuilder
    private func appMenu(_ app: RoutableApp) -> some View {
        let rule = state.routeRules[app.bundleID]
        Menu(appTitle(app, rule: rule)) {
            if let rule {
                Text(state.routeStates[app.bundleID]?.text ?? rule.deviceName)
                Divider()
            }
            Toggle("System default", isOn: Binding(
                get: { rule == nil },
                set: { on in if on { state.setRoute(for: app, to: nil) } }
            ))
            ForEach(state.outputDevices) { device in
                Toggle(device.name, isOn: Binding(
                    get: { rule?.deviceUID == device.uid },
                    set: { on in state.setRoute(for: app, to: on ? device : nil) }
                ))
            }
            if let rule, !state.outputDevices.contains(where: { $0.uid == rule.deviceUID }) {
                Text("\(rule.deviceName) (not connected)")
            }
        }
    }

    private func appTitle(_ app: RoutableApp, rule: RouteRule?) -> String {
        var title = app.name
        if let rule { title += " → \(rule.deviceName)" }
        if !app.isRunning { title += " (not running)" }
        return title
    }

    private enum PinKind { case output, input }

    /// A checkmark-style binding: on = this device is the pin.
    private func pinBinding(for device: AudioDevice, kind: PinKind) -> Binding<Bool> {
        switch kind {
        case .output:
            return Binding(
                get: { state.pinnedOutputUID == device.uid },
                set: { on in state.pinOutput(on ? device : nil) }
            )
        case .input:
            return Binding(
                get: { state.pinnedInputUID == device.uid },
                set: { on in state.pinInput(on ? device : nil) }
            )
        }
    }
}
