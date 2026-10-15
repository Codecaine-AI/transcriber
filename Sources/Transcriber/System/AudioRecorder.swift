import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import TranscriberCore
import OSLog

/// Headerless little-endian float32 PCM, emitted on the serial writer queue.
/// Original channels are interleaved; normalized audio is 16 kHz mono.
struct CapturedAudioChunk: Sendable {
    enum Kind: Sendable { case normalized, original }

    let kind: Kind
    let data: Data
    let sampleRate: Double
    let channels: Int
}

struct CapturedAudio: Sendable {
    let url: URL
    let duration: TimeInterval
    /// Absolute sample peak, in the range 0...1 for normal microphone audio.
    let peak: Float
    /// Unmixed, unresampled PCM delivered by the selected input unit.
    let original: OriginalCapturedAudio?
    fileprivate let directory: URL

    /// The caller owns the recording after stop() succeeds, including its deletion.
    /// Fork: delete only after the server confirms the seal, or on an explicit cancel.
    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Fork: moves this take's files to Recovered Recordings and returns where
    /// they are. Blocking file I/O; call it off the main actor.
    func retain(note: String) -> URL {
        RecordingStorage.recover(directory, note: note)
    }
}

/// Fork: takes are written under the client data directory instead of the
/// temporary directory, so a crash or restart cannot purge them. Audio that the
/// server has not confirmed moves to Recovered Recordings, which is never
/// deleted automatically.
enum RecordingStorage {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var clientDataDirectory: URL?
    private static let log = Logger(subsystem: "ai.codecaine.transcriber", category: "audio-capture")
    /// An AVAudioFile WAV header is padded to 4 KiB; a larger file holds audio.
    private static let headerBytes = 4_096

    /// Call before the first take. Until then, takes use the temporary directory.
    static func configure(clientDataDirectory directory: URL) {
        lock.withLock { clientDataDirectory = directory }
        // Create both folders now, so a take never changes the watched settings folder.
        for root in [activeRoot, recoveryRoot] {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
    }

    static var activeRoot: URL { root.appendingPathComponent("Active Recordings", isDirectory: true) }
    static var recoveryRoot: URL { root.appendingPathComponent("Recovered Recordings", isDirectory: true) }
    private static var root: URL { lock.withLock { clientDataDirectory } ?? FileManager.default.temporaryDirectory }

    static func newTakeDirectory() -> URL {
        activeRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Flushes a take's files to disk, writes a note saying why it was kept, and
    /// moves it to Recovered Recordings/<timestamp>/. Returns where the files
    /// are; if the move fails they stay put and the next launch recovers them.
    @discardableResult
    static func recover(_ directory: URL, note: String) -> URL {
        let files = FileManager.default
        do {
            let text = "Kept on \(Date().formatted(date: .abbreviated, time: .standard)).\n\(note)\n"
                + "microphone.wav is the 16 kHz mono transcription audio; original.wav holds every input channel, unmixed.\n"
            try Data(text.utf8).write(to: directory.appendingPathComponent("recovery.txt"))
            for entry in (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                synchronize(entry)
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let stamp = formatter.string(from: Date())
            try files.createDirectory(at: recoveryRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for attempt in 1...100 {
                let destination = recoveryRoot.appendingPathComponent(attempt == 1 ? stamp : "\(stamp) \(attempt)", isDirectory: true)
                guard !files.fileExists(atPath: destination.path) else { continue }
                try files.moveItem(at: directory, to: destination)
                synchronize(recoveryRoot)
                log.notice("Kept a recording at \(destination.path, privacy: .public): \(note, privacy: .public)")
                return destination
            }
            throw CocoaError(.fileWriteFileExists)
        } catch {
            log.error("Could not move a kept recording from \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return directory
        }
    }

    /// A take left behind by a crash or a forced quit is kept, not deleted.
    /// The listing runs synchronously, before any new take can start; the moves
    /// run in the background. Earlier builds wrote takes to the temporary
    /// directory under this prefix.
    static func recoverRemnants() {
        let files = FileManager.default
        var remnants = (try? files.contentsOfDirectory(at: activeRoot, includingPropertiesForKeys: nil)) ?? []
        let prefix = "Transcriber-Dev-recording-"
        remnants += ((try? files.contentsOfDirectory(at: files.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []).filter {
            let name = $0.lastPathComponent
            return name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
        }
        guard !remnants.isEmpty else { return }
        Task.detached(priority: .utility) {
            for remnant in remnants {
                let sizes = ((try? files.contentsOfDirectory(at: remnant, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
                    .map { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
                if sizes.contains(where: { $0 > headerBytes }) {
                    recover(remnant, note: "The app stopped during this take, before the server confirmed it. "
                        + "The WAV headers may not record the full length.")
                } else {
                    try? files.removeItem(at: remnant)
                }
            }
        }
    }

    private static func synchronize(_ url: URL) {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        if fcntl(descriptor, F_FULLFSYNC) != 0 { fsync(descriptor) }
        close(descriptor)
    }
}

struct OriginalCapturedAudio: Sendable {
    let url: URL
    let sampleRate: Double
    let channelCount: UInt32
    let frameCount: Int64
    /// WAV storage uses the input unit's PCM precision in little-endian order.
    let encoding: String
}

enum AudioRecordingError: LocalizedError {
    case permissionRequired
    case alreadyRecording
    case notRecording
    case microphoneUnavailable
    case microphoneSelectionFailed(OSStatus)
    case conversionUnavailable
    case noAudio
    case cancelled
    case processing(String)

    var errorDescription: String? {
        switch self {
        case .permissionRequired: "Allow microphone access in System Settings first."
        case .alreadyRecording: "A recording is already in progress."
        case .notRecording: "There is no recording to finish."
        case .microphoneUnavailable: "The selected microphone is unavailable. Choose another input in Transcriber."
        case .microphoneSelectionFailed(let status): "This microphone could not be opened (audio error \(status)). Choose another input in Transcriber."
        case .conversionUnavailable: "This microphone's audio format could not be converted. Try another input device."
        case .noAudio: "The microphone did not provide any audio."
        case .cancelled: "The recording was cancelled."
        case .processing(let message): "Could not save microphone audio: \(message)"
        }
    }
}

/// Owns the hardware only between explicit start() and stop()/cancel() calls.
/// Fork: or, with keepReady(_:), keeps one input running between takes.
@MainActor
final class AudioRecorder {
    var onLevel: ((Float) -> Void)?
    var onInterruption: ((String) -> Void)?
    /// Captured at start(), so changing the callback cannot redirect an active take.
    /// Enqueue network work here; this callback must not block the audio writer.
    var onChunk: (@Sendable (CapturedAudioChunk) -> Void)?

    private let worker: AudioCaptureWorker
    private let microphoneAuthorized: () -> Bool
    private let sleepNotifications: NotificationCenter
    private var request: AudioCaptureRequest?
    private var sleepObserver: NSObjectProtocol?
    // Fork: the input kept running between takes; see keepReady(_:).
    private var readyTarget: WarmInputTarget?
    private var readyObservers: [NSObjectProtocol] = []
    private var readyClosed = false

    init(worker: AudioCaptureWorker? = nil,
         microphoneAuthorized: @escaping () -> Bool = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
         sleepNotifications: NotificationCenter? = nil) {
        self.worker = worker ?? AudioCaptureWorker(makeHardware: { QueuedAudioHardware(queue: $0, warm: $1) })
        self.microphoneAuthorized = microphoneAuthorized
        self.sleepNotifications = sleepNotifications ?? NSWorkspace.shared.notificationCenter
    }

    func start(deviceID: AudioDeviceID? = nil, preserveOriginalAudio: Bool = false,
               inferenceChannels: InferenceChannelRequest? = nil) async throws {
        guard request == nil else { throw AudioRecordingError.alreadyRecording }
        guard microphoneAuthorized() else { throw AudioRecordingError.permissionRequired }
        guard !Task.isCancelled else { throw AudioRecordingError.cancelled }
        let current = AudioCaptureRequest(onChunk: onChunk, inferenceChannels: inferenceChannels)
        request = current
        sleepObserver = sleepNotifications.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.interrupt(id: current.id, message: "Recording stopped because your Mac is going to sleep.")
            }
        }
        do {
            try await worker.start(
                request: current, deviceID: deviceID,
                preserveOriginalAudio: preserveOriginalAudio,
                onLevel: { [weak self] level in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.request?.id == current.id, current.acceptsAudio else { return }
                        self.onLevel?(level)
                    }
                },
                onInterruption: { [weak self] message in
                    DispatchQueue.main.async { [weak self] in
                        self?.interrupt(id: current.id, message: message)
                    }
                }
            )
            guard !Task.isCancelled else {
                worker.cancel(request: current)
                throw AudioRecordingError.cancelled
            }
        } catch {
            if let audioError = error as? InputAudioUnitError {
                Logger(subsystem: "ai.codecaine.transcriber", category: "audio-capture")
                    .error("Capture startup failed: \(audioError.localizedDescription, privacy: .public)")
            }
            // A release can race a slow startup failure. Retain that request
            // until stop() consumes it, so a quick hold becomes noAudio rather
            // than accidentally stopping or publishing into a later take.
            if request?.id == current.id, !current.isReleased {
                request = nil
                removeSleepObserver()
                onLevel?(0)
            }
            throw error
        }
    }

    /// Call directly on key release, before scheduling the async stop task.
    /// No tap arriving after this gate closes may admit additional PCM.
    func stopAcceptingAudio() {
        request?.release()
        onLevel?(0)
    }

    func stop() async throws -> CapturedAudio {
        let stopped = stopCapture()
        return try await withTaskCancellationHandler {
            try await stopped.value
        } onCancel: { stopped.cancel() }
    }

    /// Transfer the released request synchronously, before a new hold or cancel
    /// can reach this recorder. The returned task owns only this take's teardown.
    func stopCapture() -> Task<CapturedAudio, Error> {
        guard let current = request else { return Task { throw AudioRecordingError.notRecording } }
        current.release()
        request = nil
        removeSleepObserver()
        onLevel?(0)
        return Task { try await worker.stop(request: current) }
    }

    func cancel() {
        let current = request
        current?.cancel()
        request = nil
        removeSleepObserver()
        onLevel?(0)
        if let current { worker.cancel(request: current) }
    }

    /// Fork: keeps `target`'s input running between takes, so start() only
    /// attaches this take to it; `.off` releases it. Cheap to call on every
    /// preference, device, or permission change. Sleep and an inactive user
    /// session release it too, and waking rebuilds it.
    func keepReady(_ target: WarmInputTarget) {
        guard !readyClosed, target != readyTarget else { return }
        readyTarget = target
        if readyObservers.isEmpty { observeReadySystemStates() }
        worker.setWarmTarget(target)
    }

    /// Fork: stops and disposes the ready input. Call once, when the app quits.
    func closeReadyInput() {
        guard !readyClosed else { return }
        readyClosed = true
        readyObservers.forEach { sleepNotifications.removeObserver($0) }
        readyObservers.removeAll()
        worker.closeWarm(timeout: 0.5)
    }

    private func observeReadySystemStates() {
        let worker = worker
        let changes: [(Notification.Name, @Sendable () -> Void)] = [
            (NSWorkspace.willSleepNotification, {
                worker.suspendWarm(.sleep, reason: "the Mac is going to sleep",
                                   message: "Recording stopped because your Mac is going to sleep.")
            }),
            (NSWorkspace.didWakeNotification, { worker.resumeWarm(.sleep, reason: "the Mac woke", after: 1.5) }),
            (NSWorkspace.sessionDidResignActiveNotification, {
                worker.suspendWarm(.session, reason: "this user session became inactive",
                                   message: "Recording stopped because this user session became inactive.")
            }),
            (NSWorkspace.sessionDidBecomeActiveNotification, {
                worker.resumeWarm(.session, reason: "this user session became active", after: 0.5)
            }),
        ]
        readyObservers = changes.map { name, action in
            sleepNotifications.addObserver(forName: name, object: nil, queue: .main) { _ in action() }
        }
    }

    /// Fork: an interruption is not a user cancel. The owner ends the take with
    /// stopCapture() and keeps its audio; without one, this recorder keeps it.
    private func interrupt(id: UUID, message: String) {
        guard request?.id == id else { return }
        onInterruption?(message)
        guard request?.id == id else { return }
        let stopped = stopCapture()
        Task.detached(priority: .utility) { _ = (try? await stopped.value)?.retain(note: message) }
    }

    private func removeSleepObserver() {
        if let sleepObserver { sleepNotifications.removeObserver(sleepObserver) }
        sleepObserver = nil
    }

    deinit {
        if let request { worker.cancel(request: request) }
        if let sleepObserver { sleepNotifications.removeObserver(sleepObserver) }
        readyObservers.forEach { sleepNotifications.removeObserver($0) }
    }
}

/// Capture queue ownership is independent of the Mac's default output route.
private final class QueuedAudioHardware: AudioCaptureHardware, @unchecked Sendable {
    private let queue: DispatchQueue
    /// Fork: the running input this take attaches to. Nil opens the device for
    /// this take only, as upstream does.
    private let warm: WarmInput?
    private var sink: InputAudioSink?
    private var inputUnit: InputOnlyAudioUnit?
    private var writer: RecordingWriter?
    private var request: AudioCaptureRequest?
    private var onInterruption: (@Sendable (String) -> Void)?
    private var selectedDevice: AudioDeviceID?
    private var deviceObservers: [AudioDeviceObservation] = []

    init(queue: DispatchQueue, warm: WarmInput? = nil) {
        self.queue = queue
        self.warm = warm
    }

    func start(request: AudioCaptureRequest, deviceID: AudioDeviceID?, preserveOriginalAudio: Bool,
               onLevel: @escaping @Sendable (Float) -> Void,
               onInterruption: @escaping @Sendable (String) -> Void) throws {
        try request.requireOpen()
        guard inputUnit == nil, sink == nil else { throw AudioRecordingError.alreadyRecording }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioRecordingError.permissionRequired
        }
        if let warm {
            try startWarm(warm, request: request, preserveOriginalAudio: preserveOriginalAudio,
                          onLevel: onLevel, onInterruption: onInterruption)
            return
        }
        guard let selectedDevice = deviceID ?? AudioInputHardware.defaultInputID(),
              AudioInputHardware.isAvailable(selectedDevice) else { throw AudioRecordingError.microphoneUnavailable }
        self.request = request
        self.onInterruption = onInterruption
        self.selectedDevice = selectedDevice
        let inputUnit = InputOnlyAudioUnit()
        self.inputUnit = inputUnit
        let format = try inputUnit.prepare(deviceID: selectedDevice)
        try request.requireOpen()
        let id = request.id
        let writer = try RecordingWriter(
            inputFormat: format, preserveOriginalAudio: preserveOriginalAudio, onLevel: onLevel,
            onError: { [weak self] message in self?.enqueueInterruption(id: id, message: message) },
            onChunk: request.onChunk,
            // Fork: validated against the channel count this take actually opened.
            inferenceChannels: request.inferenceChannels?.channels(channelCount: Int(format.channelCount))
        )
        self.writer = writer
        deviceObservers = [
            AudioDeviceObservation.observe(selectedDevice, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal) { [weak self] in
                self?.enqueueRouteCheck(id: id)
            },
            AudioDeviceObservation.observe(selectedDevice, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal) { [weak self] in
                self?.enqueueRouteCheck(id: id)
            },
            AudioDeviceObservation.observe(selectedDevice, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput) { [weak self] in
                self?.enqueueRouteCheck(id: id)
            },
            AudioDeviceObservation.observe(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal) { [weak self] in
                self?.enqueueRouteCheck(id: id)
            },
        ].compactMap { $0 }
        try inputUnit.start(request: request, onAudio: { buffer in writer.append(buffer) }, onError: { [weak self] status in
            self?.enqueueInterruption(id: id, message: InputAudioUnitError.driver("read input", status).localizedDescription)
        })
        guard AudioInputHardware.isAvailable(selectedDevice) else { throw AudioRecordingError.microphoneUnavailable }
    }

    /// Fork: attaches this take to the running input, which the worker has just
    /// validated against the take's device and format. The writer is built
    /// from that format; the device's route observers belong to the worker.
    private func startWarm(_ warm: WarmInput, request: AudioCaptureRequest, preserveOriginalAudio: Bool,
                           onLevel: @escaping @Sendable (Float) -> Void,
                           onInterruption: @escaping @Sendable (String) -> Void) throws {
        self.request = request
        self.onInterruption = onInterruption
        selectedDevice = warm.deviceID
        let id = request.id
        let writer = try RecordingWriter(
            inputFormat: warm.format, preserveOriginalAudio: preserveOriginalAudio, onLevel: onLevel,
            onError: { [weak self] message in self?.enqueueInterruption(id: id, message: message) },
            onChunk: request.onChunk,
            inferenceChannels: request.inferenceChannels?.channels(channelCount: Int(warm.format.channelCount))
        )
        self.writer = writer
        try request.requireOpen()
        let sink = InputAudioSink(request: request, onAudio: { buffer in writer.append(buffer) })
        try warm.attach(sink)
        self.sink = sink
    }

    func stop() -> RecordingWriter? {
        request?.release()
        let currentWriter = writer
        detachMicrophone()
        return currentWriter
    }

    func interruptInput(message: String) {
        guard let id = request?.id else { return }
        interrupt(id: id, message: message)
    }

    func cancel() {
        request?.release()
        let currentWriter = writer
        detachMicrophone()
        currentWriter?.cancel()
    }

    private func enqueueRouteCheck(id: UUID) {
        queue.async { [weak self] in
            guard let self, self.request?.id == id, self.request?.acceptsAudio == true,
                  let selectedDevice = self.selectedDevice, let inputUnit = self.inputUnit else { return }
            do {
                guard AudioInputHardware.isAvailable(selectedDevice) else { throw InputAudioUnitError.routeChanged }
                try inputUnit.validateRoute(requireRunning: true)
            } catch {
                self.interrupt(id: id, message: error.localizedDescription)
            }
        }
    }

    private func enqueueInterruption(id: UUID, message: String) {
        queue.async { [weak self] in self?.interrupt(id: id, message: message) }
    }

    private func interrupt(id: UUID, message: String) {
        guard request?.id == id, request?.acceptsAudio == true else { return }
        Logger(subsystem: "ai.codecaine.transcriber", category: "audio-capture")
            .error("Capture interrupted: \(message, privacy: .public)")
        let callback = onInterruption
        // Fork: release instead of cancel, and keep the writer. Stopping the take
        // then finishes the audio captured so far for recovery, not deletion.
        request?.release()
        releaseInput()
        callback?(message)
    }

    /// Fork: detaches from a ready input, which keeps running, or stops this
    /// take's own unit.
    private func releaseInput() {
        deviceObservers.forEach { $0.cancel() }
        deviceObservers.removeAll()
        if let sink {
            warm?.detach(sink)
            self.sink = nil
        }
        inputUnit?.stop()
        inputUnit = nil
    }

    private func detachMicrophone() {
        releaseInput()
        writer = nil
        request = nil
        selectedDevice = nil
        onInterruption = nil
    }

    deinit { cancel() }
}

/// Only the admission gate is shared between the audio callback and the caller.
/// Converter, file, counters, and errors are confined to the serial writer queue.
final class RecordingWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.codecaine.transcriber.audio-writer", qos: .userInitiated)
    private let admissionLock = NSLock()
    private var accepting = true

    private let directory: URL
    private let url: URL
    private let originalURL: URL?
    private let format: AVAudioFormat
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    /// Fork: input channels averaged into the mono inference buffer; nil lets the converter downmix.
    private let mixChannels: [Int]?
    private let onLevel: (Float) -> Void
    private let onError: (String) -> Void
    private let onChunk: (@Sendable (CapturedAudioChunk) -> Void)?
    private var file: AVAudioFile?
    private var originalFile: AVAudioFile?
    private var failure: Error?
    private var frames: AVAudioFramePosition = 0
    private var inputFrames: AVAudioFramePosition = 0
    private var peak: Float = 0
    private var meter = AudioLevelMeter()
    private var meterSumSquares = 0.0
    private var meterFrames = 0
    private let meterWindowFrames = 800 // 50 ms at the WAV's 16 kHz sample rate.

    init(inputFormat: AVAudioFormat, preserveOriginalAudio: Bool = false,
         onLevel: @escaping (Float) -> Void, onError: @escaping (String) -> Void,
         onChunk: (@Sendable (CapturedAudioChunk) -> Void)? = nil,
         inferenceChannels: [Int]? = nil) throws {
        // InputOnlyAudioUnit negotiates float32 PCM. Keep non-streaming callers
        // free to archive other PCM formats, but never label their bytes float32.
        guard !preserveOriginalAudio || onChunk == nil || inputFormat.commonFormat == .pcmFormatFloat32 else {
            throw AudioRecordingError.conversionUnavailable
        }
        // Fork: inference audio mixes only the selected channels. A selection
        // that does not fit this format falls back to Transcriber's own mix.
        let channelCount = Int(inputFormat.channelCount)
        let isPlanarFloat = inputFormat.commonFormat == .pcmFormatFloat32 && !inputFormat.isInterleaved
        let selected = inferenceChannels.flatMap { channels in
            isPlanarFloat && !channels.isEmpty && Set(channels).count == channels.count
                && channels.allSatisfy { (0..<channelCount).contains($0) } ? channels : nil
        }
        let mixChannels = selected ?? (channelCount > 2 ? Array(0..<channelCount) : nil)
        let conversionInput: AVAudioFormat
        if mixChannels != nil {
            guard isPlanarFloat,
                  let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate,
                                           channels: 1, interleaved: false) else {
                throw AudioRecordingError.conversionUnavailable
            }
            conversionInput = mono
        } else {
            conversionInput = inputFormat
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: conversionInput, to: format) else {
            throw AudioRecordingError.conversionUnavailable
        }
        self.format = format
        self.inputFormat = inputFormat
        self.converter = converter
        self.mixChannels = mixChannels
        self.onLevel = onLevel
        self.onError = onError
        self.onChunk = onChunk
        converter.downmix = true
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        // Fork: under the client data directory; see RecordingStorage.
        directory = RecordingStorage.newTakeDirectory()
        url = directory.appendingPathComponent("microphone.wav")
        originalURL = preserveOriginalAudio ? directory.appendingPathComponent("original.wav") : nil
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try queue.sync {
                file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                if let originalURL {
                    // WAV interleaves channels on disk, but no samples are mixed or
                    // resampled. AVAudioFile accepts the unit's original buffer layout.
                    var settings = inputFormat.settings
                    settings[AVLinearPCMIsNonInterleaved] = false
                    settings[AVLinearPCMIsBigEndianKey] = false
                    originalFile = try AVAudioFile(
                        forWriting: originalURL, settings: settings,
                        commonFormat: inputFormat.commonFormat, interleaved: inputFormat.isInterleaved
                    )
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: originalURL.path)
                }
            }
        } catch {
            file = nil
            originalFile = nil
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func append(_ source: AVAudioPCMBuffer) {
        // The input unit reuses its buffers. Copy only PCM memory here; never run
        // conversion, metering, UI work, or disk I/O on the real-time callback.
        guard source.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return }
        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (sourceBuffer, destinationBuffer) in zip(sourceBuffers, destinationBuffers) {
            guard let sourceData = sourceBuffer.mData, let destinationData = destinationBuffer.mData else { continue }
            memcpy(destinationData, sourceData, Int(min(sourceBuffer.mDataByteSize, destinationBuffer.mDataByteSize)))
        }

        admissionLock.lock()
        if accepting {
            queue.async { [self] in process(copy) }
        }
        admissionLock.unlock()
    }

    func finish() async throws -> CapturedAudio {
        try await withCheckedThrowingContinuation { continuation in
            admissionLock.lock()
            guard accepting else {
                admissionLock.unlock()
                continuation.resume(throwing: AudioRecordingError.cancelled)
                return
            }
            accepting = false
            queue.async { [self] in
                do {
                    if let failure { throw failure }
                    try flushConverter()
                    guard frames > 0 else { throw AudioRecordingError.noAudio }
                    file = nil // Close and finalize the WAV header before handing it off.
                    originalFile = nil
                    let original = originalURL.map {
                        let descriptor = inputFormat.streamDescription.pointee
                        let precision = descriptor.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "f" : "s"
                        return OriginalCapturedAudio(
                            url: $0, sampleRate: inputFormat.sampleRate,
                            channelCount: inputFormat.channelCount, frameCount: inputFrames,
                            encoding: "pcm_\(precision)\(descriptor.mBitsPerChannel)le"
                        )
                    }
                    continuation.resume(returning: CapturedAudio(
                        url: url, duration: Double(frames) / format.sampleRate, peak: peak,
                        original: original, directory: directory
                    ))
                } catch {
                    // Fork: a failed take keeps whatever audio reached its files.
                    if case AudioRecordingError.noAudio = error {
                        discardFile()
                    } else if frames > 0 || inputFrames > 0 {
                        file = nil
                        originalFile = nil
                        RecordingStorage.recover(directory, note: "Saving the take failed: \(error.localizedDescription)")
                    } else {
                        discardFile()
                    }
                    continuation.resume(throwing: error)
                }
            }
            admissionLock.unlock()
        }
    }

    func cancel() {
        admissionLock.lock()
        if accepting {
            accepting = false
            queue.async { [self] in discardFile() }
        }
        admissionLock.unlock()
    }

    private func process(_ input: AVAudioPCMBuffer) {
        guard failure == nil else { return }
        guard input.format == inputFormat else {
            fail(AudioRecordingError.microphoneUnavailable)
            return
        }
        // Bound both files to the same admitted input interval. This also avoids
        // converting late driver buffers after the three-minute cap is reached.
        let remainingInputFrames = AVAudioFramePosition(input.format.sampleRate * 180) - inputFrames
        guard remainingInputFrames > 0 else { return }
        input.frameLength = min(input.frameLength, AVAudioFrameCount(remainingInputFrames))
        do {
            try originalFile?.write(from: input)
            if originalFile != nil { emitOriginal(input) }
            inputFrames += AVAudioFramePosition(input.frameLength)
        } catch {
            fail(error)
            return
        }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            fail(AudioRecordingError.conversionUnavailable)
            return
        }
        // AVAudioConverter's speaker downmix produces silence for discrete
        // interface layouts. Mix the inference channels equally into a separate
        // mono buffer before resampling; `input`, already written to the
        // original recording, is only read here.
        // Fork: `mixChannels` is the take's selected channels, or every channel
        // above two, so a loopback pair is not transcribed with the microphone.
        let conversionBuffer: AVAudioPCMBuffer
        if let mixChannels {
            guard let mono = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: input.frameLength),
                  let source = input.floatChannelData, let destination = mono.floatChannelData else {
                fail(AudioRecordingError.conversionUnavailable)
                return
            }
            mono.frameLength = input.frameLength
            let frameCount = Int(input.frameLength)
            if mixChannels.count == 1 {
                destination[0].update(from: source[mixChannels[0]], count: frameCount)
            } else {
                let count = Float(mixChannels.count)
                for frame in 0..<frameCount {
                    var sample: Float = 0
                    for channel in mixChannels { sample += source[channel][frame] / count }
                    destination[0][frame] = sample
                }
            }
            conversionBuffer = mono
        } else {
            conversionBuffer = input
        }
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return conversionBuffer
        }
        if status == .error {
            fail(conversionError ?? AudioRecordingError.conversionUnavailable as NSError)
            return
        }
        do {
            try write(output)
        } catch {
            fail(error)
        }
    }

    private func flushConverter() throws {
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
            throw AudioRecordingError.conversionUnavailable
        }
        // A bounded flush avoids hanging shutdown on a malfunctioning converter.
        for _ in 0..<8 {
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if status == .error { throw conversionError ?? AudioRecordingError.conversionUnavailable as NSError }
            try write(output)
            if status == .endOfStream || status == .inputRanDry || output.frameLength == 0 { return }
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0], let file else { return }
        // The controller stops the microphone at 180 seconds, but its timer can
        // run one callback late. Keep the WAV within the helper's strict limit.
        let remainingFrames = AVAudioFramePosition(format.sampleRate * 180) - frames
        guard remainingFrames > 0 else { return }
        buffer.frameLength = min(buffer.frameLength, AVAudioFrameCount(remainingFrames))
        try file.write(from: buffer)
        onChunk?(.init(
            kind: .normalized,
            data: Data(bytes: samples, count: Int(buffer.frameLength) * MemoryLayout<Float>.size),
            sampleRate: format.sampleRate, channels: 1
        ))
        for index in 0..<Int(buffer.frameLength) {
            let sample = samples[index]
            let magnitude = sample.isFinite ? abs(sample) : 0
            peak = max(peak, magnitude)
            // Sanitize only the measurement; the PCM written above is untouched.
            let measured = Double(min(1, magnitude))
            meterSumSquares += measured * measured
            meterFrames += 1
            if meterFrames == meterWindowFrames {
                let rms = sqrt(meterSumSquares / Double(meterFrames))
                onLevel(meter.update(rms: rms, frameCount: meterFrames, sampleRate: format.sampleRate))
                meterSumSquares = 0
                meterFrames = 0
            }
        }
        frames += AVAudioFramePosition(buffer.frameLength)
    }

    private func emitOriginal(_ buffer: AVAudioPCMBuffer) {
        guard let onChunk, let samples = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        let data: Data
        if buffer.format.isInterleaved || channels == 1 {
            data = Data(bytes: samples[0], count: frameCount * channels * MemoryLayout<Float>.size)
        } else {
            // The input unit supplies planar buffers. The HTTP format is packed
            // frame-by-frame, preserving every original channel sample.
            var interleaved = [Float](repeating: 0, count: frameCount * channels)
            for frame in 0..<frameCount {
                for channel in 0..<channels {
                    interleaved[frame * channels + channel] = samples[channel][frame]
                }
            }
            data = interleaved.withUnsafeBytes { Data($0) }
        }
        onChunk(.init(kind: .original, data: data, sampleRate: buffer.format.sampleRate, channels: channels))
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        onError(error.localizedDescription)
    }

    private func discardFile() {
        file = nil
        originalFile = nil
        try? FileManager.default.removeItem(at: directory)
    }
}
