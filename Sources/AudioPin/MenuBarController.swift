// MenuBarController.swift
// The status item and its dropdown, built with AppKit (NSStatusItem + NSMenu).
//
// AppKit rather than SwiftUI's MenuBarExtra because native menus can host
// custom views, which is how the per-app volume sliders work. The menu is
// rebuilt from AppState every time it opens (NSMenuDelegate), so it always
// reflects the current devices, pins and routes.

import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let state: AppState
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellable: AnyCancellable?

    init(state: AppState) {
        self.state = state
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.toolTip = "AudioPin"
        updateIcon()

        // Keep the icon in sync with "Enforce pins" (fires before the change,
        // so hop to the next run-loop turn to read the new value).
        cancellable = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }
    }

    /// A pushpin, so it isn't mistaken for the system Sound icon.
    /// Slashed when "Enforce pins" is off.
    private func updateIcon() {
        let name = state.enforcePins ? "pin.fill" : "pin.slash"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "AudioPin")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        state.refreshAndEnforce()
        rebuild()
    }

    // MARK: - Building the menu

    private func rebuild() {
        menu.removeAllItems()

        menu.addItem(.sectionHeader(title: "Now playing through"))
        menu.addItem(info("Output: \(state.currentOutput?.name ?? "Unknown")"))
        menu.addItem(info("Input: \(state.currentInput?.name ?? "Unknown")"))
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Pinned output"))
        for device in state.outputDevices {
            let pinned = state.pinnedOutputUID == device.uid
            menu.addItem(action(device.name, checked: pinned) { [state] in
                state.pinOutput(pinned ? nil : device)
            })
        }
        if let name = state.pinnedOutputName, state.pinnedOutputUID != nil, !state.pinnedOutputConnected {
            menu.addItem(info("\(name) (not connected)"))
        }
        if state.pinnedOutputUID != nil {
            menu.addItem(action("Clear output pin") { [state] in state.pinOutput(nil) })
        }
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Pinned input"))
        for device in state.inputDevices {
            let pinned = state.pinnedInputUID == device.uid
            menu.addItem(action(device.name, checked: pinned) { [state] in
                state.pinInput(pinned ? nil : device)
            })
        }
        if let name = state.pinnedInputName, state.pinnedInputUID != nil, !state.pinnedInputConnected {
            menu.addItem(info("\(name) (not connected)"))
        }
        if state.pinnedInputUID != nil {
            menu.addItem(action("Clear input pin") { [state] in state.pinInput(nil) })
        }
        menu.addItem(.separator())

        let routing = NSMenuItem(title: "App routing", action: nil, keyEquivalent: "")
        routing.submenu = routingMenu()
        menu.addItem(routing)
        menu.addItem(.separator())

        menu.addItem(action("Enforce pins", checked: state.enforcePins) { [state] in
            state.enforcePins.toggle()
        })
        menu.addItem(action("Launch at login", checked: state.launchAtLogin) { [state] in
            state.setLaunchAtLogin(!state.launchAtLogin)
        })
        if let message = state.launchAtLoginMessage {
            menu.addItem(info(message))
        }
        menu.addItem(.separator())

        menu.addItem(action("Refresh devices") { [state] in state.refreshAndEnforce() })
        menu.addItem(action("Quit AudioPin", keyEquivalent: "q") { NSApplication.shared.terminate(nil) })
    }

    /// The "App routing" submenu: routed apps first, then everything running.
    private func routingMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let routed = state.routableApps.filter { state.routeRules[$0.bundleID] != nil }
        let others = state.routableApps.filter { state.routeRules[$0.bundleID] == nil }

        if routed.isEmpty {
            submenu.addItem(info("No apps routed yet"))
        } else {
            submenu.addItem(.sectionHeader(title: "Routed"))
            for app in routed { submenu.addItem(appItem(app)) }
        }
        submenu.addItem(.separator())
        submenu.addItem(.sectionHeader(title: "Running apps"))
        for app in others { submenu.addItem(appItem(app)) }
        return submenu
    }

    /// One app row with its own submenu: status, device choice, volume.
    private func appItem(_ app: RoutableApp) -> NSMenuItem {
        let rule = state.routeRules[app.bundleID]

        var title = app.name
        if let rule { title += " → \(rule.deviceName)" }
        if !app.isRunning { title += " (not running)" }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = app.icon

        let submenu = NSMenu()
        submenu.autoenablesItems = false

        if let rule {
            submenu.addItem(info(state.routeStates[app.bundleID]?.text ?? rule.deviceName))
            submenu.addItem(.separator())
        }

        submenu.addItem(action("System default", checked: rule == nil) { [state] in
            state.setRoute(for: app, to: nil)
        })
        submenu.addItem(.separator())
        for device in state.outputDevices {
            submenu.addItem(action(device.name, checked: rule?.deviceUID == device.uid) { [state] in
                state.setRoute(for: app, to: device)
            })
        }
        if let rule, !state.outputDevices.contains(where: { $0.uid == rule.deviceUID }) {
            submenu.addItem(info("\(rule.deviceName) (not connected)"))
        }

        if let rule {
            submenu.addItem(.separator())
            submenu.addItem(.sectionHeader(title: "Volume"))
            let sliderItem = NSMenuItem()
            sliderItem.view = VolumeSliderView(value: rule.volume) { [state] value in
                state.setVolume(for: app.bundleID, value)
            }
            submenu.addItem(sliderItem)
        }

        item.submenu = submenu
        return item
    }

    // MARK: - Item helpers

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, checked: Bool = false, keyEquivalent: String = "", handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, keyEquivalent: keyEquivalent, handler: handler)
        item.state = checked ? .on : .off
        return item
    }
}

/// An NSMenuItem that runs a closure instead of a target/selector.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

/// A menu row with a speaker icon, a slider, and a percentage label.
/// Dragging the slider changes the routed app's volume live.
private final class VolumeSliderView: NSView {
    private let slider = NSSlider()
    private let percent = NSTextField(labelWithString: "")
    private let onChange: (Double) -> Void

    init(value: Double, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 30))

        let icon = NSImageView(image: NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil) ?? NSImage())
        icon.frame = NSRect(x: 14, y: 7, width: 16, height: 16)
        icon.contentTintColor = .secondaryLabelColor
        addSubview(icon)

        slider.frame = NSRect(x: 36, y: 5, width: 150, height: 20)
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = value
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(changed)
        addSubview(slider)

        percent.frame = NSRect(x: 190, y: 7, width: 44, height: 16)
        percent.alignment = .right
        percent.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        percent.textColor = .secondaryLabelColor
        addSubview(percent)
        updateLabel()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func changed() {
        updateLabel()
        onChange(slider.doubleValue)
    }

    private func updateLabel() {
        percent.stringValue = "\(Int((slider.doubleValue * 100).rounded()))%"
    }
}
