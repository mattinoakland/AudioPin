// AppState.swift
// The app's single source of truth for the UI, plus the "pin" policy and
// the per-app routing rules:
//
//   * Holds the current device list and current defaults for the menu.
//   * Stores the pinned output / input device by UID in UserDefaults.
//   * When the HAL reports a change, waits ~300 ms (so we don't fight macOS
//     mid-reconnect), re-reads everything, and if "Enforce pins" is on and
//     a pinned device is connected but not the default, puts it back.
//   * Phase 2: stores routing rules (bundle ID -> output device UID), watches
//     app launches/quits, and asks ProcessTapRouter to keep routes in sync.
//   * Owns the "Launch at login" toggle via SMAppService.

import AppKit
import Combine
import CoreAudio
import Foundation
import ServiceManagement
import os

private let log = Logger(subsystem: "com.mattmoglia.AudioPin", category: "AppState")

/// A per-app routing rule, persisted as JSON in UserDefaults.
struct RouteRule: Codable, Equatable {
    var appName: String
    var deviceUID: String
    var deviceName: String
}

/// An app the routing menu can show: running GUI apps plus any app that has
/// a rule even if it isn't running right now.
struct RoutableApp: Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let pid: pid_t?
    var isRunning: Bool { pid != nil }
}

@MainActor
final class AppState: ObservableObject {
    // What the menu shows.
    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var currentOutput: AudioDevice?
    @Published private(set) var currentInput: AudioDevice?
    @Published private(set) var launchAtLogin: Bool = false
    @Published private(set) var launchAtLoginMessage: String?
    @Published private(set) var routableApps: [RoutableApp] = []
    @Published private(set) var routeStates: [String: RouteState] = [:]

    // User choices. Setting any of these persists and re-applies pins.
    @Published var pinnedOutputUID: String? { didSet { persist(); applyPins() } }
    @Published var pinnedInputUID: String?  { didSet { persist(); applyPins() } }
    @Published var enforcePins: Bool        { didSet { persist(); applyPins() } }
    @Published private(set) var routeRules: [String: RouteRule] = [:]

    // Last-known names so the menu can say "Jabra (not connected)".
    @Published private(set) var pinnedOutputName: String?
    @Published private(set) var pinnedInputName: String?

    var outputDevices: [AudioDevice] { devices.filter(\.hasOutput) }
    var inputDevices: [AudioDevice] { devices.filter(\.hasInput) }
    var pinnedOutputConnected: Bool { pinnedOutputUID.map { uid in devices.contains { $0.uid == uid } } ?? false }
    var pinnedInputConnected: Bool { pinnedInputUID.map { uid in devices.contains { $0.uid == uid } } ?? false }

    private let manager = AudioDeviceManager()
    private let router = ProcessTapRouter()
    private let defaults = UserDefaults.standard
    private var pendingRefresh: DispatchWorkItem?
    private let debounce: TimeInterval = 0.3
    private var observers: [NSObjectProtocol] = []

    private enum Key {
        static let pinnedOutputUID = "pinnedOutputUID"
        static let pinnedInputUID = "pinnedInputUID"
        static let pinnedOutputName = "pinnedOutputName"
        static let pinnedInputName = "pinnedInputName"
        static let enforcePins = "enforcePins"
        static let routeRules = "routeRules"
    }

    init() {
        pinnedOutputUID = defaults.string(forKey: Key.pinnedOutputUID)
        pinnedInputUID = defaults.string(forKey: Key.pinnedInputUID)
        pinnedOutputName = defaults.string(forKey: Key.pinnedOutputName)
        pinnedInputName = defaults.string(forKey: Key.pinnedInputName)
        // Default ON the first time the app runs.
        enforcePins = defaults.object(forKey: Key.enforcePins) as? Bool ?? true
        if let data = defaults.data(forKey: Key.routeRules),
           let rules = try? JSONDecoder().decode([String: RouteRule].self, from: data) {
            routeRules = rules
        }

        manager.onChange = { [weak self] in
            // Called on the HAL queue; hop to main and debounce.
            DispatchQueue.main.async { self?.scheduleRefresh() }
        }

        // App launches/quits change which routes can exist.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            })
        }
        // Tear routes down before exit so no app is left muted.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.router.teardownAll() }
        })

        refreshLoginItemStatus()
        refreshAndEnforce()
        log.info("AudioPin started. enforce=\(self.enforcePins) output=\(self.pinnedOutputUID ?? "none", privacy: .public) input=\(self.pinnedInputUID ?? "none", privacy: .public) rules=\(self.routeRules.count)")
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

    /// Re-read the HAL and enforce pins and routes. Safe to call any time.
    func refreshAndEnforce() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        refreshSnapshot()
        applyPins()
        refreshRoutableApps()
        applyRoutes()
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
                log.info("Restoring pinned output: \(target.name, privacy: .public)")
                changed = manager.setDefaultDevice(.output, to: target.id) || changed
            }
            // Keep alerts/sound effects on the same device as music.
            if manager.defaultDeviceID(.systemOutput) != target.id {
                changed = manager.setDefaultDevice(.systemOutput, to: target.id) || changed
            }
        }

        if let uid = pinnedInputUID, let target = devices.first(where: { $0.uid == uid }) {
            if currentInput?.uid != uid {
                log.info("Restoring pinned input: \(target.name, privacy: .public)")
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

    // MARK: - Per-app routing (Phase 2)

    /// Route `bundleID` to `device`, or pass nil to remove the rule (back to
    /// the system default).
    func setRoute(for app: RoutableApp, to device: AudioDevice?) {
        if let device {
            routeRules[app.bundleID] = RouteRule(appName: app.name, deviceUID: device.uid, deviceName: device.name)
            log.info("Rule set: \(app.bundleID, privacy: .public) -> \(device.name, privacy: .public)")
        } else {
            routeRules[app.bundleID] = nil
            log.info("Rule removed: \(app.bundleID, privacy: .public)")
        }
        persist()
        refreshRoutableApps()
        applyRoutes()
    }

    /// Running GUI apps (except ourselves) plus any app that has a rule.
    private func refreshRoutableApps() {
        var byBundle: [String: RoutableApp] = [:]
        let me = Bundle.main.bundleIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier, bundleID != me else { continue }
            byBundle[bundleID] = RoutableApp(
                bundleID: bundleID,
                name: app.localizedName ?? bundleID,
                pid: app.processIdentifier
            )
        }
        for (bundleID, rule) in routeRules where byBundle[bundleID] == nil {
            byBundle[bundleID] = RoutableApp(bundleID: bundleID, name: rule.appName, pid: nil)
        }
        routableApps = byBundle.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func applyRoutes() {
        let requests = routeRules.map { bundleID, rule in
            ProcessTapRouter.Request(
                bundleID: bundleID,
                pid: routableApps.first { $0.bundleID == bundleID }?.pid,
                device: devices.first { $0.uid == rule.deviceUID && $0.hasOutput }
            )
        }
        router.apply(requests)
        routeStates = router.states
    }

    private func persist() {
        defaults.set(pinnedOutputUID, forKey: Key.pinnedOutputUID)
        defaults.set(pinnedInputUID, forKey: Key.pinnedInputUID)
        defaults.set(pinnedOutputName, forKey: Key.pinnedOutputName)
        defaults.set(pinnedInputName, forKey: Key.pinnedInputName)
        defaults.set(enforcePins, forKey: Key.enforcePins)
        if let data = try? JSONEncoder().encode(routeRules) {
            defaults.set(data, forKey: Key.routeRules)
        }
    }

    // MARK: - Launch at login (SMAppService)

    func refreshLoginItemStatus() {
        let status = SMAppService.mainApp.status
        launchAtLogin = (status == .enabled)
        switch status {
        case .requiresApproval:
            launchAtLoginMessage = "Approve AudioPin in System Settings > General > Login Items"
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
            log.error("Launch at login change failed: \(error.localizedDescription, privacy: .public)")
            launchAtLoginMessage = "Couldn't change login item: \(error.localizedDescription)"
        }
        refreshLoginItemStatus()
    }
}
