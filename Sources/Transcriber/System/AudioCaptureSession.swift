import AVFoundation
import CoreAudio
import Foundation
import os
import TranscriberCore

/// The only state shared with the audio callback. Closing admission is
/// synchronous, even while a driver is still servicing start() on its queue.
final class AudioCaptureRequest: @unchecked Sendable {
    let id = UUID()
    let onChunk: (@Sendable (CapturedAudioChunk) -> Void)?
    /// Fork: frozen for the whole take; resolved against the prepared format.
    let inferenceChannels: InferenceChannelRequest?
    private enum State { case open, released, cancelled }
    // Fork: an unfair lock, because every audio callback reads this gate.
    private let state = OSAllocatedUnfairLock(initialState: State.open)

    init(onChunk: (@Sendable (CapturedAudioChunk) -> Void)? = nil, inferenceChannels: InferenceChannelRequest? = nil) {
        self.onChunk = onChunk
        self.inferenceChannels = inferenceChannels
    }

    var acceptsAudio: Bool { state.withLock { $0 == .open } }
    var isReleased: Bool { state.withLock { $0 == .released } }
    var isCancelled: Bool { state.withLock { $0 == .cancelled } }

    func release() {
        state.withLock { if $0 == .open { $0 = .released } }
    }

    func cancel() { state.withLock { $0 = .cancelled } }

    func requireOpen() throws {
        try state.withLock { state in
            switch state {
            case .open: break
            case .released: throw AudioRecordingError.noAudio
            case .cancelled: throw AudioRecordingError.cancelled
            }
        }
    }
}

/// Fork: what the capture worker keeps running between takes. `.off` carries
/// the reason, which the unified log reports when a take opens its device.
enum WarmInputTarget: Equatable, Sendable {
    case input(AudioDeviceID, AudioInputDevice)
    case off(String)
}

/// Fork: system states during which the ready input is released.
enum WarmInputSuspension: Sendable {
    case sleep, session
}

/// Fork: an input unit kept running between takes. Its callback renders every
/// cycle and discards the buffer until a take attaches a sink, so a take skips
/// device startup. Confined to the capture queue. The worker disposes it on any
/// device, format, driver, sleep, or permission change and rebuilds it later.
final class WarmInput {
    let deviceID: AudioDeviceID
    let device: AudioInputDevice
    let format: AVAudioFormat
    private let unit: InputOnlyAudioUnit
    private var observers: [AudioDeviceObservation] = []

    init(deviceID: AudioDeviceID, device: AudioInputDevice,
         onChange: @escaping @Sendable (String) -> Void, onError: @escaping @Sendable (OSStatus) -> Void) throws {
        self.deviceID = deviceID
        self.device = device
        unit = InputOnlyAudioUnit()
        format = try unit.prepare(deviceID: deviceID)
        try unit.startWarm(onError: onError)
        // The per-take listeners, kept for the unit's lifetime. A change only
        // triggers validate(); unrelated device-list changes keep the unit.
        observers = [
            AudioDeviceObservation.observe(deviceID, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal) {
                onChange("device availability changed")
            },
            AudioDeviceObservation.observe(deviceID, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal) {
                onChange("sample rate changed")
            },
            AudioDeviceObservation.observe(deviceID, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput) {
                onChange("channel layout changed")
            },
            AudioDeviceObservation.observe(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal) {
                onChange("device list changed")
            },
        ].compactMap { $0 }
    }

    /// Throws unless the unit still captures this device, in its prepared
    /// format, and its callback has run recently.
    func validate() throws {
        guard AudioInputHardware.isAvailable(deviceID), AudioInputHardware.uid(deviceID) == device.uid else {
            throw InputAudioUnitError.routeChanged
        }
        try unit.validateRoute(requireRunning: true)
        guard unit.secondsSinceLastCallback < 1 else {
            throw InputAudioUnitError.driver("receive input", kAudioHardwareNotRunningError)
        }
    }

    func attach(_ sink: InputAudioSink) throws { try unit.attach(sink) }

    /// Closes the sink's admission and waits for callbacks that leased it.
    func detach(_ sink: InputAudioSink) { unit.detach(sink) }

    func stop() {
        observers.forEach { $0.cancel() }
        observers.removeAll()
        unit.stop()
    }

    deinit { stop() }
}

/// Implementations are created, used, and destroyed on one capture queue.
/// Tests provide a fake implementation; they never construct an audio engine.
protocol AudioCaptureHardware: AnyObject {
    func start(request: AudioCaptureRequest, deviceID: AudioDeviceID?, preserveOriginalAudio: Bool,
               onLevel: @escaping @Sendable (Float) -> Void,
               onInterruption: @escaping @Sendable (String) -> Void) throws
    func stop() -> RecordingWriter?
    func cancel()
    /// Fork: the ready input this take uses failed. End admission, keep the
    /// audio captured so far, and report `message` like any interruption.
    func interruptInput(message: String)
}

/// Serializes hardware work without occupying MainActor. A captured request ID
/// protects a new take from old teardown and notification work.
final class AudioCaptureWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.codecaine.transcriber.audio-capture", qos: .userInitiated)
    /// Fork: a nil WarmInput opens the device for the take, as upstream does.
    private let makeHardware: @Sendable (DispatchQueue, WarmInput?) -> AudioCaptureHardware
    private var hardware: AudioCaptureHardware?
    private var requestID: UUID?

    // Fork: the ready input and its policy. Every property below is confined
    // to `queue`. While a take owns `hardware`, the ready input is either that
    // take's input or left alone; changes are applied when the take ends.
    private static let warmAttemptLimit = 3
    private var warm: WarmInput?
    private var warmAttached = false
    private var warmTarget = WarmInputTarget.off("Keep microphone ready has not started")
    private var warmEpoch = 0
    private var warmFailures = 0
    private var warmHasRun = false
    private var warmPendingReason: String?
    private var warmSuspensions: [WarmInputSuspension: Int] = [:]
    private var suspensionEpoch = 0
    private var coldReason = "Keep microphone ready has not started"
    private var isClosed = false
    /// The HAL default is false: running IO holds off idle sleep. Only an idle
    /// ready input allows it; every take restores the default.
    private var idleSleepAllowed = false

    init(makeHardware: @escaping @Sendable (DispatchQueue, WarmInput?) -> AudioCaptureHardware) {
        self.makeHardware = makeHardware
    }

    func start(request: AudioCaptureRequest, deviceID: AudioDeviceID?, preserveOriginalAudio: Bool = false,
               onLevel: @escaping @Sendable (Float) -> Void,
               onInterruption: @escaping @Sendable (String) -> Void) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    do {
                        try request.requireOpen()
                        guard hardware == nil else { throw AudioRecordingError.alreadyRecording }
                        let ready = readyInput(for: deviceID) // Fork
                        let capture = makeHardware(queue, ready)
                        hardware = capture
                        requestID = request.id
                        warmAttached = ready != nil
                        do {
                            try capture.start(request: request, deviceID: deviceID,
                                              preserveOriginalAudio: preserveOriginalAudio,
                                              onLevel: onLevel, onInterruption: onInterruption)
                            guard !request.isCancelled else { throw AudioRecordingError.cancelled }
                            continuation.resume()
                            allowIdleSleep(false) // Fork: after the caller resumes.
                        } catch {
                            if !request.isReleased { request.cancel() }
                            capture.cancel()
                            endTake()
                            continuation.resume(throwing: error)
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            request.cancel()
            self.cancel(request: request)
        }
    }

    func stop(request: AudioCaptureRequest) async throws -> CapturedAudio {
        request.release()
        let writer: RecordingWriter? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    guard requestID == request.id else {
                        continuation.resume(returning: nil)
                        return
                    }
                    // Fork: a ready input's stop only detaches, draining any
                    // callback that leased this take's sink; the device keeps running.
                    let writer = hardware?.stop()
                    if warmAttached, warm != nil, writer != nil { warmFailures = 0 }
                    endTake()
                    continuation.resume(returning: writer)
                }
            }
        } onCancel: { request.cancel() }
        guard let writer else {
            throw request.isCancelled ? AudioRecordingError.cancelled : AudioRecordingError.noAudio
        }
        guard !request.isCancelled, !Task.isCancelled else {
            writer.cancel()
            throw AudioRecordingError.cancelled
        }
        return try await withTaskCancellationHandler {
            let audio = try await writer.finish()
            guard !request.isCancelled, !Task.isCancelled else {
                audio.cleanup()
                throw AudioRecordingError.cancelled
            }
            return audio
        } onCancel: {
            request.cancel()
            writer.cancel()
        }
    }

    func cancel(request: AudioCaptureRequest) {
        request.cancel()
        queue.async { [self] in
            guard requestID == request.id else { return }
            hardware?.cancel()
            endTake()
        }
    }

    // MARK: - Fork: ready input

    /// Keeps `target`'s input running between takes; `.off` releases it.
    func setWarmTarget(_ target: WarmInputTarget) {
        queue.async { [self] in
            guard target != warmTarget else { return }
            warmTarget = target
            warmFailures = 0
            warmPendingReason = nil
            switch target {
            case .input(_, let device): reconcileWarm(reason: "microphone is \(device.name)")
            case .off(let reason): reconcileWarm(reason: reason)
            }
        }
    }

    /// Releases the ready input now; an attached take ends with `message`.
    func suspendWarm(_ kind: WarmInputSuspension, reason: String, message: String) {
        queue.async { [self] in
            suspensionEpoch += 1
            warmSuspensions[kind] = suspensionEpoch
            if warm != nil { loseWarm(message: message, reason: reason) }
            reconcileWarm(reason: reason)
        }
    }

    /// Rebuilds after `delay`, unless the same state was entered again meanwhile.
    func resumeWarm(_ kind: WarmInputSuspension, reason: String, after delay: TimeInterval) {
        queue.async { [self] in
            guard let epoch = warmSuspensions[kind] else { return }
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, warmSuspensions[kind] == epoch else { return }
                warmSuspensions[kind] = nil
                warmFailures = 0
                warmPendingReason = nil
                reconcileWarm(reason: reason)
            }
        }
    }

    /// Stops and disposes the ready input for good. Waits at most `timeout`,
    /// so quitting is never held up by a slow driver.
    func closeWarm(timeout: TimeInterval) {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            isClosed = true
            warmTarget = .off("the app is quitting")
            if warm != nil { loseWarm(message: "The app quit during this take.", reason: "the app is quitting") }
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    private func endTake() {
        hardware = nil
        requestID = nil
        warmAttached = false
        allowIdleSleep(warm != nil)
        // After the caller resumes its continuation: a rebuild must not delay it.
        queue.async { [self] in reconcileWarm(reason: "take ended") }
    }

    /// The running unit when it still captures `deviceID` as prepared; nil
    /// opens the device for this take. Logs why a take does not use it.
    private func readyInput(for deviceID: AudioDeviceID?) -> WarmInput? {
        guard let warm else {
            Self.log("cold path: \(coldReason)")
            return nil
        }
        guard deviceID == warm.deviceID else {
            // Left running; the take's end applies the current target.
            Self.log("cold path: the ready microphone is \(warm.device.name), not this take's")
            return nil
        }
        do {
            try warm.validate()
            return warm
        } catch {
            let reason = "\(warm.device.name) changed: \(error.localizedDescription)"
            dropWarm()
            warmPendingReason = reason
            Self.log("cold path: \(reason)")
            return nil
        }
    }

    private func reconcileWarm(reason: String) {
        guard hardware == nil else {
            warmPendingReason = reason // Applied when the take ends.
            return
        }
        let wanted = wantedInput()
        if let warm {
            if let wanted, wanted.id == warm.deviceID, wanted.device.uid == warm.device.uid,
               (try? warm.validate()) != nil {
                warmPendingReason = nil
                return
            }
            dropWarm()
            if wanted == nil {
                Self.log("warm unit stopped: \(coldReason)")
                return
            }
        }
        guard let wanted, warmFailures < Self.warmAttemptLimit else { return }
        let why = warmPendingReason ?? reason
        warmPendingReason = nil
        if warmHasRun { Self.log("warm unit rebuilt: \(why)") }
        buildWarm(id: wanted.id, device: wanted.device)
    }

    /// The input to keep running, or nil with `coldReason` saying why not.
    private func wantedInput() -> (id: AudioDeviceID, device: AudioInputDevice)? {
        switch warmTarget {
        case .off(let reason):
            coldReason = reason
            return nil
        case .input(let id, let device):
            if isClosed {
                coldReason = "the app is quitting"
            } else if let kind = warmSuspensions.keys.first {
                coldReason = kind == .sleep ? "the Mac is asleep" : "this user session is inactive"
            } else if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                coldReason = "microphone access is not allowed"
            } else if !AudioInputHardware.isAvailable(id) {
                coldReason = "\(device.name) is unavailable"
            } else if device.transport == .bluetooth || AudioInputHardware.isBluetooth(id) {
                // Never kept open: a headset microphone forces call-quality output.
                coldReason = "\(device.name) is Bluetooth, so it opens for each take"
            } else {
                return (id, device)
            }
            return nil
        }
    }

    private func buildWarm(id: AudioDeviceID, device: AudioInputDevice) {
        let began = ProcessInfo.processInfo.systemUptime
        warmEpoch += 1
        let epoch = warmEpoch
        do {
            let input = try WarmInput(
                deviceID: id, device: device,
                onChange: { [weak self] reason in
                    self?.queue.async { self?.checkWarm(epoch: epoch, reason: reason) }
                },
                onError: { [weak self] status in
                    // Enqueues one teardown; never runs it on the real-time thread.
                    self?.queue.async { self?.warmFailed(epoch: epoch, status: status) }
                }
            )
            warm = input
            warmHasRun = true
            allowIdleSleep(hardware == nil)
            let milliseconds = Int(((ProcessInfo.processInfo.systemUptime - began) * 1000).rounded())
            Self.log("warm unit ready: \(device.name), \(Int(input.format.sampleRate)) Hz, "
                + "\(input.format.channelCount) ch, \(milliseconds) ms")
        } catch {
            warmFailures += 1
            coldReason = "the ready microphone could not start: \(error.localizedDescription)"
            Self.log("warm unit failed (\(warmFailures) of \(Self.warmAttemptLimit)): \(error.localizedDescription)",
                     level: .error)
            scheduleWarmRetry(reason: "retrying after a failed start")
        }
    }

    private func checkWarm(epoch: Int, reason: String) {
        guard epoch == warmEpoch, let warm else { return }
        do {
            try warm.validate()
        } catch {
            loseWarm(message: error.localizedDescription, reason: "\(reason): \(error.localizedDescription)")
            reconcileWarm(reason: reason)
        }
    }

    private func warmFailed(epoch: Int, status: OSStatus) {
        guard epoch == warmEpoch, warm != nil else { return }
        warmFailures += 1
        let message = InputAudioUnitError.driver("read input", status).localizedDescription
        loseWarm(message: message, reason: "driver error \(status)")
        coldReason = "the ready microphone failed with audio error \(status)"
        scheduleWarmRetry(reason: "retrying after driver error \(status)")
    }

    /// Disposes the ready input. A take attached to it is interrupted first,
    /// so it keeps the audio captured so far.
    private func loseWarm(message: String, reason: String) {
        if warmAttached { hardware?.interruptInput(message: message) }
        dropWarm()
        warmPendingReason = reason
        Self.log("warm unit stopped: \(reason)")
    }

    private func dropWarm() {
        warmEpoch += 1 // Ignore late notifications from the disposed unit.
        warm?.stop()
        warm = nil
    }

    private func allowIdleSleep(_ allowed: Bool) {
        guard allowed != idleSleepAllowed else { return }
        idleSleepAllowed = allowed
        AudioInputHardware.setIdleSleepAllowed(allowed)
    }

    private func scheduleWarmRetry(reason: String) {
        guard warmFailures < Self.warmAttemptLimit else { return }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.reconcileWarm(reason: reason) }
    }

    /// Fork: the ready input's lifecycle and why a take opens its device.
    /// Read with: log stream --predicate 'subsystem == "ai.codecaine.transcriber" AND category == "microphone"'
    private static let logger = Logger(subsystem: "ai.codecaine.transcriber", category: "microphone")

    private static func log(_ message: String, level: OSLogType = .default) {
        logger.log(level: level, "\(message, privacy: .public)")
    }
}
