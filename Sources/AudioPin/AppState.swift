// AppState.swift
// The app's single source of truth for the UI, plus the "pin" policy:
//
//   * Holds the current device list and current defaults for the menu.
//   * Stores the pinned output / input device by UID in UserDefaults.
//   * When the HAL reports a change, waits ~300 ms (so we don't fight macOS
//     mid-reconnect), re-reads everything, and if "Enforce pins" is on and
//     a pinned device is connected but not the default, puts it back.
//   * Owns the "Launch at login" toggle via SMAppService.

import Combine
import CoreAudio
import Foundation
import ServiceManagement
import os

private let log = Logger(subsystem: "com.mattmoglia.AudioPin", category: "AppState")

@MainActor
final class AppState: ObservableObject {
    // What the menu shows.
    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var currentOutput: AudioDevice?
    @Published private(set) var currentInput: AudioDevice?
    @Published private(set) var launchAtLogin: Bool = false
    @Published private(set) var launchAtLoginMessage: String?

    // User choices. Setting any of these persists and re-applies pins.
    @Published var pinnedOutputUID: String? { didSet { persist(); applyPins() } }
    @Published var pinnedInputUID: String?  { didSet { persist(); applyPins() } }
    @Published var enforcePins: Bool        { didSet { persist(); applyPins() } }

    // Last-known names so the menu can say "Jabra (not connected)".
    @Published private(set) var pinnedOutputName: String?
    @Published private(set) var pinnedInputName: String?

    var outputDevices: [AudioDevice] { devices.filter(\.hasOutput) }
    var inputDevices: [AudioDevice] { devices.filter(\.hasInput) }
    var pinnedOutputConnected: Bool { pinnedOutputUID.map { uid in devices.contains { $0.uid == uid } } ?? false }
    var pinnedInputConnected: Bool { pinnedInputUID.map { uid in devices.contains { $0.uid == uid } } ?? false }

    private let manager = AudioDeviceManager()
    private let defaults = UserDefaults.standard
    private var pendingRefresh: DispatchWorkItem?
    private let debounce: TimeInterval = 0.3

    private enum Key {
        static let pinnedOutputUID = "pinnedOutputUID"
        static let pinnedInputUID = "pinnedInputUID"
        static let pinnedOutputName = "pinnedOutputName"
        static let pinnedInputName = "pinnedInputName"
        static let enforcePins = "enforcePins"
    }

    init() {
        pinnedOutputUID = defaults.string(forKey: Key.pinnedOutputUID)
        pinnedInputUID = defaults.string(forKey: Key.pinnedInputUID)
        pinnedOutputName = defaults.string(forKey: Key.pinnedOutputName)
        pinnedInputName = defaults.string(forKey: Key.pinnedInputName)
        // Default ON the first time the app runs.
        enforcePins = defaults.object(forKey: Key.enforcePins) as? Bool ?? true

        manager.onChange = { [weak self] in
            // Called on the HAL queue; hop to main and debounce.
            DispatchQueue.main.async { self?.scheduleRefresh() }
        }

        refreshLoginItemStatus()
        refreshAndEnforce()
        log.info("AudioPin started. enforce=\(self.enforcePins) output=\(self.pinnedOutputUID ?? "none") input=\(self.pinnedInputUID ?? "none")")
    }

    // MARK: - Pinning

    /// Pin the given output device (and apply it right away).
    func pinOutput(_ device: AudioDevice?) {
        pinnedOutputName = device?.name
        pinnedOutputUID = device?.uid
    }

    func pinInput(_ device: AudioDevice?) {
        pinnedInputName = device?.name
        pinnedInputUID = device?.uid
    }

    /// Re-read the HAL and enforce pins. Safe to call any time.
    func refreshAndEnforce() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        refreshSnapshot()
        applyPins()
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.refreshAndEnforce() }
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func refreshSnapshot() {
        devices = manager.allDevices().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        currentOutput = device(for: manager.defaultDeviceID(.output))
        currentInput = device(for: manager.defaultDeviceID(.input))
    }

    /// The core rule: if enforcing and a pinned device is present but not
    /// the default, make it the default. If it's absent, leave macOS alone.
    private func applyPins() {
        guard enforcePins else { return }
        var changed = false

        if let uid = pinnedOutputUID, let target = devices.first(where: { $0.uid == uid }) {
            if currentOutput?.uid != uid {
                log.info("Restoring pinned output: \(target.name)")
                changed = manager.setDefaultDevice(.output, to: target.id) || changed
            }
            // Keep alerts/sound effects on the same device as music.
            if manager.defaultDeviceID(.systemOutput) != target.id {
                changed = manager.setDefaultDevice(.systemOutput, to: target.id) || changed
            }
        }

        if let uid = pinnedInputUID, let target = devices.first(where: { $0.uid == uid }) {
            if currentInput?.uid != uid {
                log.info("Restoring pinned input: \(target.name)")
                changed = manager.setDefaultDevice(.input, to: target.id) || changed
            }
        }

        if changed {
            // Reflect what we just did without waiting for the HAL callback.
            currentOutput = device(for: manager.defaultDeviceID(.output))
            currentInput = device(for: manager.defaultDeviceID(.input))
        }
    }

    private func device(for id: AudioDeviceID?) -> AudioDevice? {
        guard let id else { return nil }
        return devices.first { $0.id == id }
    }

    private func persist() {
        defaults.set(pinnedOutputUID, forKey: Key.pinnedOutputUID)
        defaults.set(pinnedInputUID, forKey: Key.pinnedInputUID)
        defaults.set(pinnedOutputName, forKey: Key.pinnedOutputName)
        defaults.set(pinnedInputName, forKey: Key.pinnedInputName)
        defaults.set(enforcePins, forKey: Key.enforcePins)
    }

    // MARK: - Launch at login (SMAppService)

    func refreshLoginItemStatus() {
        let status = SMAppService.mainApp.status
        launchAtLogin = (status == .enabled)
        switch status {
        case .requiresApproval:
            launchAtLoginMessage = "Approve AudioPin in System Settings > General > Login Items"
        case .notFound:
            launchAtLoginMessage = nil
        default:
            launchAtLoginMessage = nil
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginMessage = nil
            log.info("Launch at login -> \(enabled)")
        } catch {
            log.error("Launch at login change failed: \(error.localizedDescription)")
            launchAtLoginMessage = "Couldn't change login item: \(error.localizedDescription)"
        }
        refreshLoginItemStatus()
    }
}
