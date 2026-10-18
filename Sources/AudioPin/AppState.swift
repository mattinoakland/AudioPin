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
    /// 0...1, applied to the routed audio. Older saved rules have no value.
    var volume: Double

    init(appName: String, deviceUID: String, deviceName: String, volume: Double = 1) {
        self.appName = appName
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.volume = volume
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appName = try c.decode(String.self, forKey: .appName)
        deviceUID = try c.decode(String.self, forKey: .deviceUID)
        deviceName = try c.decode(String.self, forKey: .deviceName)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
    }
}

/// An app the routing menu can show: running GUI apps plus any app that has
/// a rule even if it isn't running right now.
struct RoutableApp: Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let pid: pid_t?
    let icon: NSImage?
    var isRunning: Bool { pid != nil }

    static func == (lhs: RoutableApp, rhs: RoutableApp) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.name == rhs.name && lhs.pid == rhs.pid
    }
    func hash(into hasher: inout Hasher) { hasher.combine(bundleID) }
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
    /// Hardware level of the pinned output / input (nil = no level control).
    @Published private(set) var outputLevel: Float?
    @Published private(set) var inputLevel: Float?
    /// A newer version the server told us about, if any.
    @Published private(set) var availableUpdate: UpdateInfo?
    @Published var sendUsageStats: Bool {
        didSet { telemetry.isEnabled = sendUsageStats }
    }

    // User choices. Setting any of these persists and re-applies pins.
    @Published var pinnedOutputUID: String? { didSet { persist(); applyPins() } }
    @Published var pinnedInputUID: String?  { didSet { persist(); applyPins() } }
    @Published var enforcePins: Bool        { didSet { persist(); applyPins() } }
    @Published private(set) var routeRules: [String: RouteRule] = [:]

    // Last-known names so the menu can say "Jabra (not connected)".
    @Published private(set) var pinnedOutputName: String?
    @Published private(set) var pinnedInputName: String?

    /// Real hardware only; virtual devices (Zoom, Loom, aggregates) are hidden
    /// from the menus. A pin on one still works if it was set before.
    var outputDevices: [AudioDevice] { devices.filter { $0.hasOutput && !$0.isVirtual } }
    var inputDevices: [AudioDevice] { devices.filter { $0.hasInput && !$0.isVirtual } }
    var pinnedOutputConnected: Bool { pinnedOutputUID.map { uid in devices.contains { $0.uid == uid } } ?? false }
    var pinnedInputConnected: Bool { pinnedInputUID.map { uid in devices.contains { $0.uid == uid } } ?? false }

    private let manager = AudioDeviceManager()
    private let router = ProcessTapRouter()
    private let telemetry = Telemetry()
    private let defaults = UserDefaults.standard
    private var pendingRefresh: DispatchWorkItem?
    private let debounce: TimeInterval = 0.3
    private var observers: [NSObjectProtocol] = []
    private var signalSources: [DispatchSourceSignal] = []
    /// System output seen on the last route pass, to notice when it moves.
    private var lastSystemOutputUID: String?

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
        sendUsageStats = telemetry.isEnabled
        telemetry.onResult = { [weak self] update in self?.availableUpdate = update }

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
            MainActor.assumeIsolated { self?.router.teardownAll() }
        })
        // A plain `kill` (SIGTERM) or Ctrl-C bypasses willTerminate; turn
        // them into a normal quit so routes still get torn down.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApplication.shared.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }

        refreshLoginItemStatus()
        refreshAndEnforce()
        telemetry.start()
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
        refreshLevels()
    }

    /// Re-read the pinned devices' hardware levels for the sliders.
    func refreshLevels() {
        outputLevel = outputVolume()
        inputLevel = inputGain()
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
            refreshLevels()
        }
    }

    private func device(for id: AudioDeviceID?) -> AudioDevice? {
        guard let id else { return nil }
        return devices.first { $0.id == id }
    }

    // MARK: - Device volume (pinned output level, pinned input gain)

    /// The device whose level the output slider controls: the pinned output
    /// if it's connected, otherwise whatever is the default right now.
    var volumeOutputDevice: AudioDevice? {
        if let uid = pinnedOutputUID, let d = devices.first(where: { $0.uid == uid }) { return d }
        return currentOutput
    }

    var volumeInputDevice: AudioDevice? {
        if let uid = pinnedInputUID, let d = devices.first(where: { $0.uid == uid }) { return d }
        return currentInput
    }

    /// Current level, or nil if the device has no volume control.
    func outputVolume() -> Float? {
        volumeOutputDevice.flatMap { manager.volume(of: $0.id, scope: kAudioDevicePropertyScopeOutput) }
    }

    func inputGain() -> Float? {
        volumeInputDevice.flatMap { manager.volume(of: $0.id, scope: kAudioDevicePropertyScopeInput) }
    }

    func setOutputVolume(_ value: Float) {
        guard let device = volumeOutputDevice else { return }
        manager.setVolume(of: device.id, scope: kAudioDevicePropertyScopeOutput, to: value)
        outputLevel = value
    }

    func setInputGain(_ value: Float) {
        guard let device = volumeInputDevice else { return }
        manager.setVolume(of: device.id, scope: kAudioDevicePropertyScopeInput, to: value)
        inputLevel = value
    }

    // MARK: - Per-app routing (Phase 2)

    /// Route `bundleID` to `device`, or pass nil to remove the rule (back to
    /// the system default).
    func setRoute(for app: RoutableApp, to device: AudioDevice?) {
        if let device {
            let volume = routeRules[app.bundleID]?.volume ?? 1
            routeRules[app.bundleID] = RouteRule(appName: app.name, deviceUID: device.uid, deviceName: device.name, volume: volume)
            log.info("Rule set: \(app.bundleID, privacy: .public) -> \(device.name, privacy: .public)")
        } else {
            routeRules[app.bundleID] = nil
            log.info("Rule removed: \(app.bundleID, privacy: .public)")
        }
        persist()
        refreshRoutableApps()
        applyRoutes()
    }

    /// Volume for a routed app, 0...1. Applied live; saved with the rule.
    func setVolume(for bundleID: String, _ volume: Double) {
        guard routeRules[bundleID] != nil else { return }
        let clamped = max(0, min(1, volume))
        routeRules[bundleID]?.volume = clamped
        router.setGain(bundleID: bundleID, Float(clamped))
        persist()
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
                pid: app.processIdentifier,
                icon: Self.menuIcon(app.icon)
            )
        }
        for (bundleID, rule) in routeRules where byBundle[bundleID] == nil {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            byBundle[bundleID] = RoutableApp(bundleID: bundleID, name: rule.appName, pid: nil, icon: Self.menuIcon(icon))
        }
        routableApps = byBundle.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A copy of an app icon sized for a menu row.
    private static func menuIcon(_ image: NSImage?) -> NSImage? {
        guard let image, let copy = image.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    private func applyRoutes() {
        // A routed app's audio goes straight to its device's hardware level,
        // which nothing else moves (the volume keys only touch the system
        // output). If that level was left low, routed audio tops out low. So
        // when a route starts to a device that isn't the system output, or
        // the system output moves off a routed device, open the device all
        // the way up and scale the app's slider down by the same amount, so
        // nothing gets louder but the slider now has headroom above it.
        let outputChanged = currentOutput?.uid != lastSystemOutputUID
        lastSystemOutputUID = currentOutput?.uid
        var opened: [String: Float] = [:]   // device UID -> level it had before
        for (bundleID, rule) in routeRules {
            guard routeStates[bundleID]?.isActive != true || outputChanged,
                  opened[rule.deviceUID] == nil,
                  let device = devices.first(where: { $0.uid == rule.deviceUID && $0.hasOutput }),
                  device.uid != currentOutput?.uid,
                  let level = manager.volume(of: device.id, scope: kAudioDevicePropertyScopeOutput),
                  level < 0.999
            else { continue }
            if manager.setVolume(of: device.id, scope: kAudioDevicePropertyScopeOutput, to: 1) {
                opened[device.uid] = level
                log.info("Opened \(device.name, privacy: .public) to 100% for route \(bundleID, privacy: .public) (was \(Int(level * 100))%)")
            }
        }
        if !opened.isEmpty {
            for (bundleID, rule) in routeRules {
                guard let level = opened[rule.deviceUID] else { continue }
                let scaled = max(0, min(1, rule.volume * Double(level)))
                routeRules[bundleID]?.volume = scaled
                log.info("Scaled \(bundleID, privacy: .public) slider \(Int(rule.volume * 100))% -> \(Int(scaled * 100))% to keep loudness")
            }
            persist()
        }

        let requests = routeRules.map { bundleID, rule in
            ProcessTapRouter.Request(
                bundleID: bundleID,
                pid: routableApps.first { $0.bundleID == bundleID }?.pid,
                device: devices.first { $0.uid == rule.deviceUID && $0.hasOutput },
                volume: Float(rule.volume)
            )
        }
        router.apply(requests) { [weak self] states in
            self?.routeStates = states
        }
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
