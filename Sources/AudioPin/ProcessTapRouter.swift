// ProcessTapRouter.swift
// Per-app output routing using the macOS 14.2 process-tap API.
//
// For each routing rule ("send app X to device Y") this class builds:
//
//   1. A *process tap* on the app's Core Audio process object. The tap
//      captures everything the app plays and (muteBehavior =
//      .mutedWhenTapped) silences the app's normal output while the tap runs.
//   2. A *private aggregate device* that contains the tap (as its input side)
//      and the chosen output device (as its output side).
//   3. An IOProc on that aggregate device that copies the tapped audio
//      straight into the output buffers.
//
// Tearing a route down undoes those three in reverse, which also unmutes the
// app's normal output, so quitting AudioPin never leaves an app silent.
//
// All Core Audio calls happen on `workQueue`, a serial background queue, so a
// slow or wedged coreaudiod can never freeze the menu bar panel. `apply` is
// asynchronous and reports back on the main thread; `teardownAll` is
// synchronous because it runs right before the process exits.
// The IOProc block runs on its own real-time queue and touches only buffers.

import Accelerate
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
        /// Per-route volume, read by the IOProc on the audio thread. A plain
        /// Float write is atomic on Apple Silicon, so no lock is needed.
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

        // 2. Private aggregate: tap in, chosen device out.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioPin route: \(bundleID)",
            kAudioAggregateDeviceUIDKey: "com.mattmoglia.AudioPin.route.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: device.uid],
            ],
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
            return .failed("Couldn't create routing device (error \(status))")
        }

        // 3. IOProc: copy tapped input to the output device.
        let gain = route.gain
        status = AudioDeviceCreateIOProcIDWithBlock(&route.ioProcID, route.aggregateID, ioQueue) {
            _, inputData, _, outputData, _ in
            ProcessTapRouter.copy(from: inputData, to: outputData, gain: gain.value)
        }
        guard status == noErr, route.ioProcID != nil else {
            log.error("CreateIOProcID failed for \(bundleID, privacy: .public): \(status)")
            destroy(route)
            return .failed("Couldn't start audio copy (error \(status))")
        }

        status = AudioDeviceStart(route.aggregateID, route.ioProcID)
        guard status == noErr else {
            log.error("AudioDeviceStart failed for \(bundleID, privacy: .public): \(status)")
            destroy(route)
            return .failed("Couldn't start routing device (error \(status))")
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

    // MARK: - Audio copy (runs on the IO queue, real-time: no allocation, no locks)

    /// Copies each input buffer into the matching output buffer. The tap is a
    /// stereo mixdown; if the output device has a different channel count,
    /// channels are matched frame by frame and the extras are silenced.
    private static func copy(from inputList: UnsafePointer<AudioBufferList>, to outputList: UnsafeMutablePointer<AudioBufferList>, gain: Float) {
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputList))
        let output = UnsafeMutableAudioBufferListPointer(outputList)

        for index in 0..<output.count {
            let outBuffer = output[index]
            guard let outData = outBuffer.mData else { continue }
            let outBytes = Int(outBuffer.mDataByteSize)

            guard index < input.count, let inData = input[index].mData else {
                memset(outData, 0, outBytes)
                continue
            }
            let inBuffer = input[index]
            let inBytes = Int(inBuffer.mDataByteSize)
            let inChannels = Int(inBuffer.mNumberChannels)
            let outChannels = Int(outBuffer.mNumberChannels)

            if inChannels == outChannels || inChannels == 0 || outChannels == 0 {
                let n = min(inBytes, outBytes)
                memcpy(outData, inData, n)
                if n < outBytes { memset(outData + n, 0, outBytes - n) }
                if gain != 1 {
                    var g = gain
                    let samples = outData.assumingMemoryBound(to: Float32.self)
                    vDSP_vsmul(samples, 1, &g, samples, 1, vDSP_Length(n / MemoryLayout<Float32>.size))
                }
                continue
            }

            // Interleaved Float32 with different channel counts.
            let sampleSize = MemoryLayout<Float32>.size
            let inFrames = inBytes / (sampleSize * inChannels)
            let outFrames = outBytes / (sampleSize * outChannels)
            let frames = min(inFrames, outFrames)
            let src = inData.assumingMemoryBound(to: Float32.self)
            let dst = outData.assumingMemoryBound(to: Float32.self)
            memset(outData, 0, outBytes)
            let channels = min(inChannels, outChannels)
            for frame in 0..<frames {
                for channel in 0..<channels {
                    dst[frame * outChannels + channel] = src[frame * inChannels + channel] * gain
                }
            }
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
