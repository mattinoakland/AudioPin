// AudioDeviceManager.swift
// Thin Swift wrapper over the Core Audio HAL (CoreAudio.framework).
//
// Responsibilities:
//   * Enumerate audio devices and tell input devices from output devices.
//   * Read and set the three "default" device slots macOS keeps:
//       - default output        (what apps play through)
//       - default input         (what apps record from)
//       - default system output (alerts / sound effects)
//   * Watch the HAL for changes (device plugged/unplugged, default changed)
//     and call `onChange` on a background queue.
//
// Everything here is synchronous and does no debouncing or policy; that
// lives in AppState so this file stays a plain, testable API layer.

import CoreAudio
import Foundation
import os

private let log = Logger(subsystem: "com.mattmoglia.AudioPin", category: "AudioDeviceManager")

/// A snapshot of one audio device. `id` is only valid until the device is
/// unplugged; `uid` is stable across reconnects, so pins are stored by UID.
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let hasInput: Bool
    let hasOutput: Bool
    /// Software devices (Zoom, Loom, aggregates) rather than real hardware.
    /// They're kept in the list so pins can match them, but hidden from menus.
    let isVirtual: Bool
}

/// The three default-device slots macOS maintains.
enum DefaultRole: CaseIterable {
    case output, input, systemOutput

    var selector: AudioObjectPropertySelector {
        switch self {
        case .output:       return kAudioHardwarePropertyDefaultOutputDevice
        case .input:        return kAudioHardwarePropertyDefaultInputDevice
        case .systemOutput: return kAudioHardwarePropertyDefaultSystemOutputDevice
        }
    }

    var label: String {
        switch self {
        case .output:       return "output"
        case .input:        return "input"
        case .systemOutput: return "system output"
        }
    }
}

final class AudioDeviceManager {
    /// Fired (on `listenerQueue`) whenever the device list or any default
    /// device changes. AppState debounces and hops to the main thread.
    var onChange: (() -> Void)?

    private let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private let listenerQueue = DispatchQueue(label: "com.mattmoglia.AudioPin.hal", qos: .userInitiated)
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private let watchedSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultSystemOutputDevice,
        // Phase 2: fires when an app starts or stops using Core Audio, which
        // is when a per-app route can first be built.
        kAudioHardwarePropertyProcessObjectList,
    ]

    init() {
        startListening()
    }

    deinit {
        stopListening()
    }

    // MARK: - Enumeration

    /// All devices the HAL knows about that have at least one input or
    /// output stream and a usable UID.
    func allDevices() -> [AudioDevice] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size)
        guard status == noErr else {
            log.error("GetPropertyDataSize(devices) failed: \(status)")
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids)
        guard status == noErr else {
            log.error("GetPropertyData(devices) failed: \(status)")
            return []
        }

        return ids.compactMap { id in
            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty else { return nil }
            let name = stringProperty(id, kAudioObjectPropertyName) ?? uid
            let hasInput = streamCount(id, scope: kAudioDevicePropertyScopeInput) > 0
            let hasOutput = streamCount(id, scope: kAudioDevicePropertyScopeOutput) > 0
            guard hasInput || hasOutput else { return nil }
            let transport = transportType(id)
            let isVirtual = transport == kAudioDeviceTransportTypeVirtual
                || transport == kAudioDeviceTransportTypeAggregate
                || transport == kAudioDeviceTransportTypeUnknown
            return AudioDevice(id: id, uid: uid, name: name, hasInput: hasInput, hasOutput: hasOutput, isVirtual: isVirtual)
        }
    }

    // MARK: - Default devices

    /// The device ID currently in the given default slot, or nil if unset.
    func defaultDeviceID(_ role: DefaultRole) -> AudioDeviceID? {
        var address = Self.address(role.selector)
        var id: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &id)
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// Puts `deviceID` into the given default slot. Returns true on success.
    @discardableResult
    func setDefaultDevice(_ role: DefaultRole, to deviceID: AudioDeviceID) -> Bool {
        var address = Self.address(role.selector)
        var id = deviceID
        let status = AudioObjectSetPropertyData(
            systemObject, &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id
        )
        if status == noErr {
            log.info("Set default \(role.label, privacy: .public) -> device \(deviceID)")
            return true
        } else {
            log.error("Failed to set default \(role.label, privacy: .public) to \(deviceID): \(status)")
            return false
        }
    }

    // MARK: - Device volume

    /// 'vmvc': the "virtual main volume" the system volume slider moves.
    /// Declared in AudioToolbox as kAudioHardwareServiceDeviceProperty_VirtualMainVolume;
    /// spelled out here so this file only needs CoreAudio.
    private let virtualMainVolumeSelector: AudioObjectPropertySelector = 0x766D_7663

    /// The device's volume (0...1) in the given scope (output = speaker level,
    /// input = mic gain), or nil if the device has no software volume control
    /// (HDMI displays, for example).
    func volume(of deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Float? {
        // The "virtual main" volume is what the system volume slider moves.
        var main = Self.address(virtualMainVolumeSelector, scope: scope)
        if AudioObjectHasProperty(deviceID, &main) {
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &main, 0, nil, &size, &value) == noErr {
                return value
            }
        }
        // Fall back to the per-channel scalar (average of the first two channels).
        var values: [Float32] = []
        for channel in [1, 2] as [AudioObjectPropertyElement] {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: channel)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr {
                values.append(value)
            }
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }

    /// Sets the device's volume (0...1) in the given scope. Returns false if
    /// the device doesn't allow it.
    @discardableResult
    func setVolume(of deviceID: AudioDeviceID, scope: AudioObjectPropertyScope, to volume: Float) -> Bool {
        var value = Float32(max(0, min(1, volume)))
        let size = UInt32(MemoryLayout<Float32>.size)

        var main = Self.address(virtualMainVolumeSelector, scope: scope)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(deviceID, &main),
           AudioObjectIsPropertySettable(deviceID, &main, &settable) == noErr, settable.boolValue,
           AudioObjectSetPropertyData(deviceID, &main, 0, nil, size, &value) == noErr {
            return true
        }

        var any = false
        for channel in [1, 2] as [AudioObjectPropertyElement] {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: channel)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            if AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == noErr {
                any = true
            }
        }
        if !any {
            log.error("Device \(deviceID) has no settable volume in scope \(scope)")
        }
        return any
    }

    // MARK: - Listeners

    private func startListening() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onChange?()
        }
        listenerBlock = block
        for selector in watchedSelectors {
            var address = Self.address(selector)
            let status = AudioObjectAddPropertyListenerBlock(systemObject, &address, listenerQueue, block)
            if status != noErr {
                log.error("AddPropertyListenerBlock(\(selector)) failed: \(status)")
            }
        }
        log.info("HAL listeners registered")
    }

    private func stopListening() {
        guard let block = listenerBlock else { return }
        for selector in watchedSelectors {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(systemObject, &address, listenerQueue, block)
        }
        listenerBlock = nil
    }

    // MARK: - Property helpers

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a CFString property (name, UID) as a Swift String.
    private func stringProperty(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>? = nil
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let unmanaged = value else { return nil }
        return unmanaged.takeRetainedValue() as String
    }

    /// How the device is attached (built-in, USB, Bluetooth, virtual, ...).
    private func transportType(_ objectID: AudioObjectID) -> UInt32 {
        var address = Self.address(kAudioDevicePropertyTransportType)
        var value: UInt32 = kAudioDeviceTransportTypeUnknown
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr ? value : kAudioDeviceTransportTypeUnknown
    }

    /// Number of streams a device has in a scope; >0 means it can do
    /// input (or output) at all.
    private func streamCount(_ objectID: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = Self.address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard status == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }
}
