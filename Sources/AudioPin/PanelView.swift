// PanelView.swift
// The contents of the dropdown panel. It lives in a popover (see
// MenuBarController) rather than a real menu so that clicking a row doesn't
// close it: you can pin a device and then drag its slider without reopening.

import SwiftUI

struct PanelView: View {
    @EnvironmentObject private var state: AppState
    /// Reports the content size so the window can grow or shrink with it.
    var onSizeChange: (CGSize) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            section("Now playing through") {
                InfoRow("Output: \(state.currentOutput?.name ?? "Unknown")")
                InfoRow("Input: \(state.currentInput?.name ?? "Unknown")")
            }
            divider

            section("Pinned output") {
                ForEach(state.outputDevices) { device in
                    CheckRow(device.name, checked: state.pinnedOutputUID == device.uid) {
                        state.pinOutput(state.pinnedOutputUID == device.uid ? nil : device)
                    }
                }
                if let name = state.pinnedOutputName, state.pinnedOutputUID != nil, !state.pinnedOutputConnected {
                    InfoRow("\(name) (not connected)")
                }
                LevelRow(symbol: "speaker.wave.2", label: "Volume",
                         device: state.volumeOutputDevice, level: state.outputLevel) {
                    state.setOutputVolume($0)
                }
            }
            divider

            section("Pinned input") {
                ForEach(state.inputDevices) { device in
                    CheckRow(device.name, checked: state.pinnedInputUID == device.uid) {
                        state.pinInput(state.pinnedInputUID == device.uid ? nil : device)
                    }
                }
                if let name = state.pinnedInputName, state.pinnedInputUID != nil, !state.pinnedInputConnected {
                    InfoRow("\(name) (not connected)")
                }
                LevelRow(symbol: "mic", label: "Gain",
                         device: state.volumeInputDevice, level: state.inputLevel) {
                    state.setInputGain($0)
                }
            }
            divider

            routedSection
            divider

            section(nil) {
                CheckRow("Enforce pins", checked: state.enforcePins) { state.enforcePins.toggle() }
                CheckRow("Launch at login", checked: state.launchAtLogin) {
                    state.setLaunchAtLogin(!state.launchAtLogin)
                }
                if let message = state.launchAtLoginMessage {
                    InfoRow(message)
                }
            }
            divider

            section(nil) {
                ActionRow("Refresh devices") { state.refreshAndEnforce() }
                ActionRow("Quit AudioPin", shortcut: "⌘Q") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(.vertical, 6)
        .frame(width: 320)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: PanelSizeKey.self, value: proxy.size)
        })
        .onPreferenceChange(PanelSizeKey.self) { onSizeChange($0) }
    }

    // MARK: - Routed apps

    private var routedSection: some View {
        let routed = state.routableApps.filter { state.routeRules[$0.bundleID] != nil }
        let others = state.routableApps.filter { state.routeRules[$0.bundleID] == nil }

        return section("Routed apps") {
            if routed.isEmpty {
                InfoRow("No apps routed yet")
            }
            ForEach(routed) { app in
                if let rule = state.routeRules[app.bundleID] {
                    RoutedAppRow(app: app, rule: rule)
                    LevelRow(symbol: "speaker.wave.2", label: "Volume",
                             device: nil, level: Float(rule.volume), alwaysEnabled: true) {
                        state.setVolume(for: app.bundleID, Double($0))
                    }
                }
            }
            // "Route an app" is a real menu: pick an app, then a device.
            Menu {
                ForEach(others) { app in
                    Menu {
                        ForEach(state.outputDevices) { device in
                            Button(device.name) { state.setRoute(for: app, to: device) }
                        }
                    } label: {
                        if let icon = app.icon { Image(nsImage: icon) }
                        Text(app.name)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                        .frame(width: 16)
                    Text("Route an app")
                    Spacer()
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .foregroundStyle(.primary)
        }
    }

    // MARK: - Layout helpers

    private var divider: some View {
        Divider().padding(.horizontal, 14).padding(.vertical, 5)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 3)
            }
            content()
        }
    }
}

private struct PanelSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

// MARK: - Rows

/// A row with a checkmark gutter that toggles on click, like a menu item.
private struct CheckRow: View {
    let title: String
    let checked: Bool
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, checked: Bool, action: @escaping () -> Void) {
        self.title = title
        self.checked = checked
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 16)
                    .opacity(checked ? 1 : 0)
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }
}

/// A plain command row (Refresh, Quit).
private struct ActionRow: View {
    let title: String
    var shortcut: String? = nil
    let action: () -> Void

    init(_ title: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Color.clear.frame(width: 16)
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }
}

/// Secondary, non-interactive text.
private struct InfoRow: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 16)
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
    }
}

/// Icon, slider, percentage. Shows a note when the device has no level control.
private struct LevelRow: View {
    let symbol: String
    let label: String
    let device: AudioDevice?
    let level: Float?
    var alwaysEnabled = false
    let onChange: (Float) -> Void

    var body: some View {
        if let level, alwaysEnabled || device != nil {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Slider(value: Binding(
                    get: { Double(level) },
                    set: { onChange(Float($0)) }
                ), in: 0...1)
                .controlSize(.small)
                Text("\(Int((level * 100).rounded()))%")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
        } else if let device {
            InfoRow("\(device.name) has no \(label.lowercased()) control")
        } else {
            InfoRow("\(label): no device")
        }
    }
}

/// A routed app: icon, "App → Device", and a popup to change or stop it.
private struct RoutedAppRow: View {
    @EnvironmentObject private var state: AppState
    let app: RoutableApp
    let rule: RouteRule

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if let icon = app.icon {
                    Image(nsImage: icon).frame(width: 16)
                } else {
                    Color.clear.frame(width: 16)
                }
                Text(app.name + (app.isRunning ? "" : " (not running)"))
                Spacer()
                devicePicker
            }
            HStack(spacing: 8) {
                Color.clear.frame(width: 16)
                Text(state.routeStates[app.bundleID]?.text ?? rule.deviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
    }

    private var devicePicker: some View {
            Menu {
                ForEach(state.outputDevices) { device in
                    Button {
                        state.setRoute(for: app, to: device)
                    } label: {
                        if rule.deviceUID == device.uid {
                            Label(device.name, systemImage: "checkmark")
                        } else {
                            Text(device.name)
                        }
                    }
                }
                Divider()
                Button("Stop routing") { state.setRoute(for: app, to: nil) }
            } label: {
                Text(rule.deviceName)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .controlSize(.small)
    }
}

/// Menu-item-like highlight on hover.
private struct RowButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovering || configuration.isPressed ? Color.accentColor.opacity(0.85) : .clear)
            )
            .foregroundStyle(hovering || configuration.isPressed ? Color.white : Color.primary)
            .padding(.horizontal, 4)
            .onHover { hovering = $0 }
    }
}
