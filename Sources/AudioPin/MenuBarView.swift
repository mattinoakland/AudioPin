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
