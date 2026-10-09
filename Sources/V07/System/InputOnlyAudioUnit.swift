import AVFoundation
import AudioToolbox
import CoreAudio
import OSLog
import os

/// C API boundary: tests supply every operation and never instantiate hardware.
struct InputAudioUnitOperations {
    var create: () throws -> AudioUnit
    var set: (AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, UnsafeRawPointer, UInt32) -> OSStatus
    var get: (AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, UnsafeMutableRawPointer, UnsafeMutablePointer<UInt32>) -> OSStatus
    var initialize: (AudioUnit) -> OSStatus
    var start: (AudioUnit) -> OSStatus
    var stop: (AudioUnit) -> OSStatus
    var uninitialize: (AudioUnit) -> OSStatus
    var dispose: (AudioUnit) -> OSStatus
    var render: (AudioUnit, UnsafeMutablePointer<AudioUnitRenderActionFlags>, UnsafePointer<AudioTimeStamp>, UInt32, UInt32, UnsafeMutablePointer<AudioBufferList>) -> OSStatus

    static var live: Self {
        Self(create: {
            var description = AudioComponentDescription(
                componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
            )
            guard let component = AudioComponentFindNext(nil, &description) else {
                throw InputAudioUnitError.driver("create input", kAudioUnitErr_FailedInitialization)
            }
            var unit: AudioUnit?
            try InputAudioUnitError.check(AudioComponentInstanceNew(component, &unit), "create input")
            guard let unit else { throw InputAudioUnitError.driver("create input", kAudioUnitErr_FailedInitialization) }
            return unit
        }, set: { AudioUnitSetProperty($0, $1, $2, $3, $4, $5) },
           get: { AudioUnitGetProperty($0, $1, $2, $3, $4, $5) },
           initialize: AudioUnitInitialize, start: AudioOutputUnitStart, stop: AudioOutputUnitStop,
           uninitialize: AudioUnitUninitialize, dispose: AudioComponentInstanceDispose,
           render: { AudioUnitRender($0, $1, $2, $3, $4, $5) })
    }
}

enum InputAudioUnitError: LocalizedError {
    case driver(String, OSStatus)
    case invalidFormat
    case routeChanged

    var errorDescription: String? {
        switch self {
        case .driver(let operation, let status): "Could not \(operation) on the selected microphone (audio error \(status)). Please try again."
        case .invalidFormat: "The selected microphone has no usable audio format."
        case .routeChanged: "The recording microphone changed or disconnected. Please try again."
        }
    }

    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw Self.driver(operation, status) }
    }
}

/// One explicit device, input enabled, output disabled. Unlike AVAudioEngine,
/// this never constructs a default input/output aggregate or follows its route.
/// All lifecycle work is serialized by AudioCaptureWorker's queue.
final class InputOnlyAudioUnit {
    private let operations: InputAudioUnitOperations
    private var unit: AudioUnit?
    private var format: AVAudioFormat?
    private var selectedDevice: AudioDeviceID?
    private var initialized = false
    private var startAttempted = false
    private var context: InputAudioRenderContext?
    private var contextReference: UnsafeMutableRawPointer?

    init(operations: InputAudioUnitOperations = .live) { self.operations = operations }

    func prepare(deviceID: AudioDeviceID) throws -> AVAudioFormat {
        guard unit == nil else { throw AudioRecordingError.alreadyRecording }
        guard deviceID != kAudioObjectUnknown else { throw AudioRecordingError.microphoneUnavailable }
        unit = try operations.create()
        do {
            // Both directions are configured BEFORE selecting any device.
            // Only unit-local properties are written, never HAL device/default
            // properties, output routes, hog mode, or a device's sample rate.
            try set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0))
            try set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1))
            try set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, deviceID)
            let hardware = try hardwareFormat()
            // Original-audio uploads support at most eight input channels.
            guard hardware.mSampleRate.isFinite, hardware.mSampleRate > 0,
                  hardware.mSampleRate <= 768_000,
                  hardware.mChannelsPerFrame > 0, hardware.mChannelsPerFrame <= 8 else {
                throw InputAudioUnitError.invalidFormat
            }
            // The channel-count initializer only supports mono and stereo.
            // USB interfaces expose discrete inputs, not surround speaker positions.
            let format: AVAudioFormat
            if hardware.mChannelsPerFrame > 2 {
                guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | hardware.mChannelsPerFrame) else {
                    throw InputAudioUnitError.invalidFormat
                }
                format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate,
                                       interleaved: false, channelLayout: layout)
            } else {
                guard let monoOrStereo = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                    sampleRate: hardware.mSampleRate, channels: hardware.mChannelsPerFrame, interleaved: false) else {
                    throw InputAudioUnitError.invalidFormat
                }
                format = monoOrStereo
            }
            // Set our client PCM layout on OUTPUT scope of INPUT element 1.
            // Keep the physical device's rate/channels; the writer resamples.
            try set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, format.streamDescription.pointee)
            try set(kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Output, 1, UInt32(0))
            self.format = format
            selectedDevice = deviceID
            try validateRoute()
            return format
        } catch {
            stop()
            throw error
        }
    }

    func start(request: AudioCaptureRequest, onAudio: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
               onError: @escaping @Sendable (OSStatus) -> Void) throws {
        do {
            try request.requireOpen()
            try run(sink: InputAudioSink(request: request, onAudio: onAudio), request: request, onError: onError)
        } catch {
            if !request.isReleased { request.cancel() }
            stop()
            throw error
        }
    }

    /// Fork: runs the device with no take attached. Every callback renders and
    /// discards its buffer until attach(_:) admits a take.
    func startWarm(onError: @escaping @Sendable (OSStatus) -> Void) throws {
        do {
            try run(sink: nil, request: nil, onError: onError)
        } catch {
            stop()
            throw error
        }
    }

    private func run(sink: InputAudioSink?, request: AudioCaptureRequest?,
                     onError: @escaping @Sendable (OSStatus) -> Void) throws {
        guard let unit, let format, context == nil else { throw AudioRecordingError.notRecording }
        let context = InputAudioRenderContext(unit: unit, render: operations.render, sink: sink, onError: onError)
        self.context = context
        let reference = Unmanaged.passRetained(context).toOpaque()
        contextReference = reference
        let callback = AURenderCallbackStruct(inputProc: { reference, flags, time, _, frames, _ in
            let context = Unmanaged<InputAudioRenderContext>.fromOpaque(reference).takeUnretainedValue()
            return context.receive(flags: flags, time: time, frames: frames)
        }, inputProcRefCon: reference)
        try set(kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, callback)
        // Mark attempts before the calls so partial failures are torn down.
        initialized = true
        try InputAudioUnitError.check(operations.initialize(unit), "initialize input")
        let maximum: UInt32 = try get(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, initial: 0)
        guard maximum > 0, maximum <= 65_536,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximum) else {
            throw InputAudioUnitError.invalidFormat
        }
        context.buffer = buffer // Immutable after start; no callbacks yet.
        try validateRoute()
        try request?.requireOpen()
        startAttempted = true
        try InputAudioUnitError.check(operations.start(unit), "start input")
        context.markStarted() // Fork: a slow start is not a stalled callback.
        if request?.isCancelled == true { throw AudioRecordingError.cancelled }
        try validateRoute(requireRunning: true)
    }

    /// Fork: admits one take to a running unit. Capture queue only; the sink is
    /// allocated by the caller, so the callback only swaps a pointer.
    func attach(_ sink: InputAudioSink) throws {
        guard let context, startAttempted else { throw AudioRecordingError.notRecording }
        guard context.attach(sink) else { throw AudioRecordingError.alreadyRecording }
    }

    /// Fork: removes the sink, then waits for callbacks that leased it, so a
    /// writer finished afterwards receives every buffer rendered for its take.
    /// The take's request was already released; this never stops the device.
    func detach(_ sink: InputAudioSink) {
        guard let context else { return }
        if !context.detach(sink, timeout: 0.25) { report(kAudioUnitErr_CannotDoInCurrentContext, "drain input") }
    }

    /// Fork: time since the last callback, or since start before the first one.
    var secondsSinceLastCallback: TimeInterval { context?.secondsSinceLastCallback ?? .infinity }

    func validateRoute(requireRunning: Bool = false) throws {
        guard let selectedDevice, let format else { throw AudioRecordingError.notRecording }
        let current: AudioDeviceID = try get(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, initial: 0)
        let hardware = try hardwareFormat()
        guard current == selectedDevice, hardware.mSampleRate == format.sampleRate,
              hardware.mChannelsPerFrame == format.channelCount else { throw InputAudioUnitError.routeChanged }
        if requireRunning {
            let running: UInt32 = try get(kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, initial: 0)
            guard running != 0 else { throw InputAudioUnitError.routeChanged }
        }
    }

    func stop() {
        // Close admission before waiting on any driver operation. Keep callback
        // storage alive until disposal has stopped all use of its raw refCon.
        // Fork: the detached sink is released here, after the driver stops.
        let sink = context?.detachAll()
        sink?.request.release()
        guard let unit else { return }
        if startAttempted {
            report(operations.stop(unit), "stop input")
            _ = context?.drain(timeout: 0.25)
        }
        if initialized { report(operations.uninitialize(unit), "uninitialize input") }
        let disposed = operations.dispose(unit)
        report(disposed, "dispose input")
        if disposed == noErr, let reference = contextReference {
            Unmanaged<InputAudioRenderContext>.fromOpaque(reference).release()
        }
        // A defective driver that refuses disposal must not receive a dangling
        // refCon. In that exceptional case retain the closed gate until exit.
        contextReference = nil
        context = nil
        self.unit = nil
        format = nil
        selectedDevice = nil
        initialized = false
        startAttempted = false
    }

    private func hardwareFormat() throws -> AudioStreamBasicDescription {
        try get(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, initial: AudioStreamBasicDescription())
    }

    private func set<T>(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement, _ value: T) throws {
        guard let unit else { throw AudioRecordingError.notRecording }
        try withUnsafeBytes(of: value) { bytes in
            try InputAudioUnitError.check(operations.set(unit, property, scope, element, bytes.baseAddress!, UInt32(bytes.count)), "configure input")
        }
    }

    private func get<T>(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement, initial: T) throws -> T {
        guard let unit else { throw AudioRecordingError.notRecording }
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutableBytes(of: &value) { bytes in
            try InputAudioUnitError.check(operations.get(unit, property, scope, element, bytes.baseAddress!, &size), "read input format")
        }
        guard size == MemoryLayout<T>.size else { throw InputAudioUnitError.invalidFormat }
        return value
    }

    private func report(_ status: OSStatus, _ operation: String) {
        if status != noErr {
            Logger(subsystem: "dev.davis.v07", category: "audio-capture")
                .error("\(operation, privacy: .public) failed: \(status)")
        }
    }

    deinit { stop() }
}

/// Fork: one take's destination for rendered input. A callback leases the
/// sink while its request admits audio and then delivers that buffer, even if
/// the take is released while it renders. Stopping never drops a tail buffer.
final class InputAudioSink: @unchecked Sendable {
    let request: AudioCaptureRequest
    let onAudio: @Sendable (AVAudioPCMBuffer) -> Void

    init(request: AudioCaptureRequest, onAudio: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.request = request
        self.onAudio = onAudio
    }
}

/// Callback-only mutable state after start. No device queries, file writes,
/// format conversion, or UI work on the driver's real-time thread.
private final class InputAudioRenderContext {
    let unit: AudioUnit
    let render: InputAudioUnitOperations.Render
    let onError: @Sendable (OSStatus) -> Void
    var buffer: AVAudioPCMBuffer?
    private var failed = false
    /// Fork: the attached sink, callbacks holding a lease on it, and the last
    /// callback's host time. The unfair lock is held only to read or swap these,
    /// never while rendering or delivering, and nothing under it allocates.
    private struct Slot {
        var sink: InputAudioSink?
        var leases = 0
        var lastCallback: UInt64
    }
    private let slot: OSAllocatedUnfairLock<Slot>

    init(unit: AudioUnit, render: @escaping InputAudioUnitOperations.Render, sink: InputAudioSink?,
         onError: @escaping @Sendable (OSStatus) -> Void) {
        self.unit = unit
        self.render = render
        self.onError = onError
        slot = OSAllocatedUnfairLock(uncheckedState: Slot(sink: sink, lastCallback: mach_absolute_time()))
    }

    func receive(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, time: UnsafePointer<AudioTimeStamp>, frames: UInt32) -> OSStatus {
        guard !failed, frames > 0 else { return noErr }
        guard let buffer, frames <= buffer.frameCapacity else {
            fail(kAudioUnitErr_TooManyFramesToProcess)
            return noErr
        }
        // Fork: lease before rendering. Without a sink the buffer is rendered
        // and discarded, so audio between takes is never kept.
        var leased = lease()
        buffer.frameLength = frames
        let status = render(unit, flags, time, 1, frames, buffer.mutableAudioBufferList)
        if status == noErr { leased?.onAudio(buffer) }
        if leased != nil {
            // Drop this reference before the lease, so the detaching owner,
            // not this thread, releases the sink.
            leased = nil
            slot.withLockUnchecked { $0.leases -= 1 }
        }
        if status != noErr { fail(status) }
        return noErr
    }

    func attach(_ sink: InputAudioSink) -> Bool {
        slot.withLockUnchecked { slot in
            guard slot.sink == nil else { return false }
            slot.sink = sink
            return true
        }
    }

    /// Returns false if a leased callback outlived `timeout`.
    func detach(_ sink: InputAudioSink, timeout: TimeInterval) -> Bool {
        let detached: InputAudioSink? = slot.withLockUnchecked { slot in
            guard slot.sink === sink else { return nil }
            defer { slot.sink = nil }
            return slot.sink
        }
        return withExtendedLifetime(detached) { drain(timeout: timeout) }
    }

    /// Closes admission for whatever take is attached and returns its sink.
    func detachAll() -> InputAudioSink? {
        slot.withLockUnchecked { slot in
            defer { slot.sink = nil }
            return slot.sink
        }
    }

    /// Waits off the callback thread for leased callbacks; usually none, and
    /// at most one IO cycle.
    func drain(timeout: TimeInterval) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while slot.withLockUnchecked({ $0.leases }) > 0 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            usleep(200)
        }
        return true
    }

    func markStarted() {
        let now = mach_absolute_time()
        slot.withLockUnchecked { $0.lastCallback = now }
    }

    var secondsSinceLastCallback: TimeInterval {
        let last = slot.withLockUnchecked { $0.lastCallback }
        let now = mach_absolute_time()
        return now > last ? Double(AudioConvertHostTimeToNanos(now - last)) / 1_000_000_000 : 0
    }

    private func lease() -> InputAudioSink? {
        let now = mach_absolute_time()
        return slot.withLockUnchecked { slot in
            slot.lastCallback = now
            guard let sink = slot.sink, sink.request.acceptsAudio else { return nil }
            slot.leases += 1
            return sink
        }
    }

    private func fail(_ status: OSStatus) {
        failed = true
        onError(status) // Enqueues one teardown on the capture worker, never here.
    }
}

private extension InputAudioUnitOperations {
    typealias Render = (AudioUnit, UnsafeMutablePointer<AudioUnitRenderActionFlags>, UnsafePointer<AudioTimeStamp>, UInt32, UInt32, UnsafeMutablePointer<AudioBufferList>) -> OSStatus
}
