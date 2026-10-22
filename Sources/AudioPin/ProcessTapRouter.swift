// ProcessTapRouter.swift
// Per-app output routing using the macOS 14.2 process-tap API.
//
// For each routing rule ("send app X to device Y") this class builds:
//
//   1. A *process tap* on the app's Core Audio process object. The tap
//      captures everything the app plays and (muteBehavior =
//      .mutedWhenTapped) silences the app's normal output while the tap runs.
//   2. A *private aggregate device* containing only the tap, with an IOProc
//      that copies the captured audio into a ring buffer.
//   3. A regular *output audio unit* (AUHAL) on the chosen device that pulls
//      from the ring buffer. This is the same path any normal app uses, so the
//      device gets its usual system processing (the MacBook speakers' tuning,
//      spatial audio, and so on). Playing through the aggregate's own output
//      side skipped that processing and sounded noticeably thinner.
//
// Tearing a route down undoes all of that in reverse, which also unmutes the
// app's normal output, so quitting AudioPin never leaves an app silent.
//
// All Core Audio calls happen on `workQueue`, a serial background queue, so a
// slow or wedged coreaudiod can never freeze the menu bar panel. `apply` is
// asynchronous and reports back on the main thread; `teardownAll` is
// synchronous because it runs right before the process exits.
// The capture IOProc and the output render callback run on real-time threads
// and touch only the ring buffer.

import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import os

private let log = Logger(subsystem: "com.mattmoglia.AudioPin", category: "ProcessTapRouter")

/// What the UI should say about one app's route.
enum RouteState: Equatable {
    case active(deviceName: String)
    case appNotRunning
    case waitingForAudio          // app runs but has no Core Audio process object yet
    case deviceNotConnected
    case failed(String)

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    var text: String {
        switch self {
        case .active(let name):   return "Routing to \(name)"
        case .appNotRunning:      return "App not running"
        case .waitingForAudio:    return "Waiting for the app to play audio"
        case .deviceNotConnected: return "Device not connected"
        case .failed(let why):    return why
        }
    }
}

final class ProcessTapRouter {

    /// One live route. Everything here must be destroyed in `teardown`.
    private final class Route {
        let bundleID: String
        let pid: pid_t
        let deviceUID: String
        let deviceID: AudioDeviceID
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var ioProcID: AudioDeviceIOProcID?
        var outputUnit: AudioUnit?
        /// Captured audio waiting to be played: half a second at 48 kHz stereo.
        let ring = RingBuffer(capacity: 48_000)
        /// Per-route volume, read on the audio thread. A plain Float write is
        /// atomic on Apple Silicon, so no lock is needed.
        let gain = GainBox()

        init(bundleID: String, pid: pid_t, deviceUID: String, deviceID: AudioDeviceID) {
            self.bundleID = bundleID
            self.pid = pid
            self.deviceUID = deviceUID
            self.deviceID = deviceID
        }
    }

    /// Holds the route's volume (0...1) so the IOProc block can read it.
    final class GainBox {
        var value: Float = 1
    }

    private let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private let ioQueue = DispatchQueue(label: "com.mattmoglia.AudioPin.io", qos: .userInteractive)
    private let workQueue = DispatchQueue(label: "com.mattmoglia.AudioPin.router", qos: .userInitiated)
    private var routes: [String: Route] = [:]          // keyed by bundle ID; workQueue only
    private var states: [String: RouteState] = [:]     // keyed by bundle ID; workQueue only
    private var applyGeneration = 0


    // MARK: - Public API

    /// Desired routing for one app.
    struct Request {
        let bundleID: String
        let pid: pid_t?            // nil when the app isn't running
        let device: AudioDevice?   // nil when the target device isn't connected
        let volume: Float          // 0...1, applied to the copied audio
        /// Tear the route down and build it again even if nothing else
        /// changed. Used when the system output moves: the tap's stream
        /// format follows the app's device, so a stale tap can sound wrong.
        var rebuild: Bool = false
    }

    /// Make reality match `requests`: build routes that are missing, rebuild
    /// routes whose app relaunched or whose device changed, and tear down
    /// routes that no longer have a request. Idempotent and cheap to call.
    /// Runs in the background; `completion` gets the new states on main.
    /// If several calls pile up, only the newest one's result is reported.
    func apply(_ requests: [Request], completion: @escaping ([String: RouteState]) -> Void) {
        applyGeneration += 1
        let generation = applyGeneration
        workQueue.async { [self] in
            applyNow(requests)
            let snapshot = states
            DispatchQueue.main.async {
                guard generation == self.applyGeneration else { return }
                completion(snapshot)
            }
        }
    }

    /// Change a live route's volume without rebuilding it.
    func setGain(bundleID: String, _ volume: Float) {
        workQueue.async { [self] in
            routes[bundleID]?.gain.value = max(0, min(1, volume))
        }
    }

    /// Destroy every route. Call before the app exits. Blocks until done.
    func teardownAll() {
        workQueue.sync { [self] in
            for bundleID in Array(routes.keys) {
                teardown(bundleID: bundleID)
            }
            states.removeAll()
        }
    }

    private func applyNow(_ requests: [Request]) {
        let wanted = Set(requests.map(\.bundleID))

        // Tear down anything no longer requested.
        for bundleID in routes.keys where !wanted.contains(bundleID) {
            teardown(bundleID: bundleID)
            states[bundleID] = nil
        }

        for request in requests {
            guard let pid = request.pid else {
                teardown(bundleID: request.bundleID)
                states[request.bundleID] = .appNotRunning
                continue
            }
            guard let device = request.device else {
                teardown(bundleID: request.bundleID)
                states[request.bundleID] = .deviceNotConnected
                continue
            }

            if let existing = routes[request.bundleID] {
                let unchanged = existing.pid == pid
                    && existing.deviceUID == device.uid
                    && existing.deviceID == device.id
                    && !request.rebuild
                if unchanged, case .active = states[request.bundleID] {
                    existing.gain.value = request.volume
                    continue
                }
                teardown(bundleID: request.bundleID)
            }

            states[request.bundleID] = build(bundleID: request.bundleID, pid: pid, device: device, volume: request.volume)
        }
    }

    // MARK: - Building a route

    private func build(bundleID: String, pid: pid_t, device: AudioDevice, volume: Float) -> RouteState {
        guard let processObject = processObject(forPID: pid) else {
            // The app hasn't touched Core Audio yet. AppState retries when the
            // HAL's process list changes.
            return .waitingForAudio
        }

        let route = Route(bundleID: bundleID, pid: pid, deviceUID: device.uid, deviceID: device.id)
        route.gain.value = max(0, min(1, volume))

        // 1. Process tap. Stereo mixdown keeps the IOProc simple regardless of
        //    how many channels the app actually produces.
        let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        description.name = "AudioPin tap: \(bundleID)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var status = AudioHardwareCreateProcessTap(description, &route.tapID)
        guard status == noErr, route.tapID != kAudioObjectUnknown else {
            log.error("CreateProcessTap failed for \(bundleID, privacy: .public): \(status)")
            return .failed(Self.explainTapError(status))
        }
        if let format = tapFormat(route.tapID) {
            log.info("Tap format for \(bundleID, privacy: .public): \(format.mSampleRate) Hz, \(format.mChannelsPerFrame) ch, \(format.mBitsPerChannel)-bit, flags \(format.mFormatFlags)")
        }

        // 2. Private aggregate holding just the tap: our capture side.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioPin capture: \(bundleID)",
            kAudioAggregateDeviceUIDKey: "com.mattmoglia.AudioPin.capture.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &route.aggregateID)
        guard status == noErr, route.aggregateID != kAudioObjectUnknown else {
            log.error("CreateAggregateDevice failed for \(bundleID, privacy: .public): \(status)")
            destroy(route)
            return .failed("Couldn't create capture device (error \(status))")
        }

        // 3. Capture IOProc: tapped audio -> ring buffer.
        let ring = route.ring
        status = AudioDeviceCreateIOProcIDWithBlock(&route.ioProcID, route.aggregateID, ioQueue) {
            _, inputData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard buffers.count > 0, let data = buffers[0].mData else { return }
            let samples = data.assumingMemoryBound(to: Float32.self)
            ring.write(samples, count: Int(buffers[0].mDataByteSize) / MemoryLayout<Float32>.size)
        }
        guard status == noErr, route.ioProcID != nil else {
            log.error("CreateIOProcID failed for \(bundleID, privacy: .public): \(status)")
            destroy(route)
            return .failed("Couldn't start audio capture (error \(status))")
        }

        // 4. A normal output unit on the chosen device: ring buffer -> device.
        //    Same path as any app, so the device's system processing applies.
        guard let format = tapFormat(route.tapID) else {
            destroy(route)
            return .failed("Couldn't read the tap's audio format")
        }
        switch makeOutputUnit(device: device.id, format: format, ring: ring, gain: route.gain) {
        case .success(let unit):
            route.outputUnit = unit
        case .failure(let message):
            destroy(route)
            return .failed(message)
        }

        status = AudioDeviceStart(route.aggregateID, route.ioProcID)
        guard status == noErr else {
            log.error("AudioDeviceStart failed for \(bundleID, privacy: .public): \(status)")
            destroy(route)
            return .failed("Couldn't start capture (error \(status))")
        }
        status = AudioOutputUnitStart(route.outputUnit!)
        guard status == noErr else {
            log.error("AudioOutputUnitStart failed for \(bundleID, privacy: .public): \(status)")
            destroy(route)
            return .failed("Couldn't start playback (error \(status))")
        }

        routes[bundleID] = route
        log.info("Route up: \(bundleID, privacy: .public) (pid \(pid)) -> \(device.name, privacy: .public)")
        return .active(deviceName: device.name)
    }

    private func teardown(bundleID: String) {
        guard let route = routes.removeValue(forKey: bundleID) else { return }
        destroy(route)
        log.info("Route down: \(bundleID, privacy: .public)")
    }

    /// Reverse of `build`. Safe to call on a partially built route.
    private func destroy(_ route: Route) {
        if let unit = route.outputUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            route.outputUnit = nil
        }
        if let procID = route.ioProcID, route.aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(route.aggregateID, procID)
            AudioDeviceDestroyIOProcID(route.aggregateID, procID)
            route.ioProcID = nil
        }
        if route.aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(route.aggregateID)
            route.aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if route.tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(route.tapID)   // also unmutes the app
            route.tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Output unit (AUHAL on the target device)

    private enum UnitResult {
        case success(AudioUnit)
        case failure(String)
    }

    /// Builds, configures and initializes an output unit that renders from
    /// `ring` (scaled by `gain`) to `device`, in the tap's stream format.
    private func makeOutputUnit(device: AudioDeviceID, format: AudioStreamBasicDescription,
                                ring: RingBuffer, gain: GainBox) -> UnitResult {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            return .failure("No output unit available")
        }
        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else { return .failure("Couldn't create output unit (error \(status))") }

        // Output on bus 0, no input bus.
        var enable: UInt32 = 1
        var disable: UInt32 = 0
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, UInt32(MemoryLayout<UInt32>.size))
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disable, UInt32(MemoryLayout<UInt32>.size))

        var deviceID = device
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            return .failure("Couldn't select the output device (error \(status))")
        }

        // We hand the unit audio in the tap's format; it converts to whatever
        // the device wants.
        var inFormat = format
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &inFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            return .failure("Output unit rejected the audio format (error \(status))")
        }

        let context = RenderContext(ring: ring, gain: gain, channels: Int(format.mChannelsPerFrame))
        let contextPointer = Unmanaged.passRetained(context).toOpaque()
        var callback = AURenderCallbackStruct(inputProc: renderCallback, inputProcRefCon: contextPointer)
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else {
            Unmanaged<RenderContext>.fromOpaque(contextPointer).release()
            AudioComponentInstanceDispose(unit)
            return .failure("Couldn't attach the audio source (error \(status))")
        }

        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            Unmanaged<RenderContext>.fromOpaque(contextPointer).release()
            AudioComponentInstanceDispose(unit)
            return .failure("Couldn't initialize the output unit (error \(status))")
        }
        // The context is intentionally leaked for the unit's lifetime; it is a
        // few bytes per route and the ring buffer is shared with the Route.
        return .success(unit)
    }

    /// What the render callback needs, reachable through an opaque pointer.
    final class RenderContext {
        let ring: RingBuffer
        let gain: GainBox
        let channels: Int
        init(ring: RingBuffer, gain: GainBox, channels: Int) {
            self.ring = ring
            self.gain = gain
            self.channels = channels
        }
    }

    // MARK: - Core Audio helpers

    /// The HAL process object for a PID, or nil if that process has not used
    /// Core Audio yet.
    private func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            systemObject, &address,
            UInt32(MemoryLayout<pid_t>.size), &qualifier,
            &size, &object
        )
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    /// The stream format the tap delivers (follows the tapped app's device).
    private func tapFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr else { return nil }
        return format
    }

    private static func explainTapError(_ status: OSStatus) -> String {
        // The HAL doesn't give a specific "permission denied" code; a failed
        // tap on a valid process is almost always the TCC prompt being
        // declined, so point there.
        "Couldn't tap this app (error \(status)). Allow AudioPin under System Settings > Privacy & Security > Screen & System Audio Recording, then try again."
    }
}


/// Real-time render callback: pulls interleaved Float32 from the ring buffer
/// into the output unit's buffer, applies the route's gain, zero-fills on
/// underrun. No allocation, no Swift collections.
private func renderCallback(
    _ refCon: UnsafeMutableRawPointer,
    _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
    _ inBusNumber: UInt32,
    _ inNumberFrames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let ioData else { return noErr }
    let context = Unmanaged<ProcessTapRouter.RenderContext>.fromOpaque(refCon).takeUnretainedValue()
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    guard buffers.count > 0, let data = buffers[0].mData else { return noErr }
    let samples = data.assumingMemoryBound(to: Float32.self)
    let wanted = Int(inNumberFrames) * context.channels
    let got = context.ring.read(into: samples, count: wanted)
    if got < wanted {
        memset(samples + got, 0, (wanted - got) * MemoryLayout<Float32>.size)
    }
    let gain = context.gain.value
    if gain != 1, got > 0 {
        var g = gain
        vDSP_vsmul(samples, 1, &g, samples, 1, vDSP_Length(got))
    }
    return noErr
}

/// Single-producer, single-consumer ring of Float32 samples. The capture
/// IOProc writes, the output render callback reads. A short unfair lock guards
/// the indices; the copies are small (a few KB per callback).
final class RingBuffer {
    private let storage: UnsafeMutablePointer<Float32>
    private let capacity: Int
    private var head = 0        // next write position
    private var tail = 0        // next read position
    private var count = 0
    private var lock = os_unfair_lock()
    /// Don't start playing until this much is buffered, to ride out jitter
    /// between the capture and playback clocks (about 20 ms at 48 kHz stereo).
    private let prefill = 2048
    private var primed = false

    init(capacity: Int) {
        self.capacity = capacity
        storage = UnsafeMutablePointer<Float32>.allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit { storage.deallocate() }

    func write(_ src: UnsafePointer<Float32>, count n: Int) {
        os_unfair_lock_lock(&lock)
        var toWrite = min(n, capacity)
        // If the reader fell behind, drop the oldest audio rather than block.
        if count + toWrite > capacity {
            let drop = count + toWrite - capacity
            tail = (tail + drop) % capacity
            count -= drop
        }
        var offset = n - toWrite
        while toWrite > 0 {
            let chunk = min(toWrite, capacity - head)
            memcpy(storage + head, src + offset, chunk * MemoryLayout<Float32>.size)
            head = (head + chunk) % capacity
            offset += chunk
            toWrite -= chunk
            count += chunk
        }
        if count >= prefill { primed = true }
        os_unfair_lock_unlock(&lock)
    }

    /// Reads up to `n` samples; returns how many were available.
    func read(into dst: UnsafeMutablePointer<Float32>, count n: Int) -> Int {
        os_unfair_lock_lock(&lock)
        guard primed else { os_unfair_lock_unlock(&lock); return 0 }
        var toRead = min(n, count)
        let total = toRead
        var offset = 0
        while toRead > 0 {
            let chunk = min(toRead, capacity - tail)
            memcpy(dst + offset, storage + tail, chunk * MemoryLayout<Float32>.size)
            tail = (tail + chunk) % capacity
            offset += chunk
            toRead -= chunk
            count -= chunk
        }
        if count == 0 { primed = false }   // underrun: re-buffer before resuming
        os_unfair_lock_unlock(&lock)
        return total
    }
}
