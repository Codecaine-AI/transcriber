import AppKit
import CoreAudio
import Foundation

/// Small injection boundary so mute/restore tests never touch the Mac's output.
struct SystemOutputClient {
    let defaultOutputDevice: () -> AudioDeviceID?
    /// Elements whose mute can be set: the main element, or each channel when a
    /// device only exposes per-channel mute.
    let muteElements: (AudioDeviceID) -> [AudioObjectPropertyElement]
    let isMuted: (AudioDeviceID, AudioObjectPropertyElement) -> Bool?
    let setMuted: (AudioDeviceID, AudioObjectPropertyElement, Bool) -> Bool
}

/// Fork: mute and restore return at once. Their HAL reads and writes run in
/// call order on one serial queue, off the dictation start and stop path, so a
/// take's mute always lands before its restore. Each muted element records the
/// mute call that owns it, and a restore only unmutes elements owned by mutes
/// issued before it: an older take's restore never unmutes a newer take.
@MainActor
final class SystemOutputMuter {
    private let worker: SystemOutputMuteWorker
    private let terminationObserver: NSObjectProtocol
    private var generation: UInt64 = 0

    init(client: SystemOutputClient = .live) {
        let worker = SystemOutputMuteWorker(client: client)
        self.worker = worker
        // Quitting must not outrun a queued restore and leave the Mac muted.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in worker.drain() }
    }

    func mute() {
        generation &+= 1
        let owner = generation
        let worker = worker
        worker.queue.async { worker.mute(owner: owner) }
    }

    func restore() {
        let owner = generation
        let worker = worker
        worker.queue.async { worker.restore(through: owner) }
    }

    deinit {
        NotificationCenter.default.removeObserver(terminationObserver)
    }
}

/// The muted-element ledger. Its state is touched only on `queue`.
private final class SystemOutputMuteWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "ai.codecaine.transcriber.output-muter", qos: .userInitiated)
    private let client: SystemOutputClient
    private var muted: [(device: AudioDeviceID, element: AudioObjectPropertyElement, owner: UInt64)] = []

    init(client: SystemOutputClient) {
        self.client = client
    }

    func mute(owner: UInt64) {
        guard let device = client.defaultOutputDevice() else { return }
        // Only elements this muter silenced are restored; anything the user had
        // already muted stays muted.
        for element in client.muteElements(device)
        where client.isMuted(device, element) == false && client.setMuted(device, element, true) {
            muted.append((device, element, owner))
        }
    }

    func restore(through owner: UInt64) {
        // An unmute that fails (e.g. the output dropped mid-take) stays pending
        // so the next restore retries it instead of leaving the Mac muted.
        muted = muted.filter { entry in
            entry.owner > owner || !client.setMuted(entry.device, entry.element, false)
        }
    }

    /// Waits for every queued mute and restore to finish.
    func drain() {
        queue.sync {}
    }
}

extension SystemOutputClient {
    static var live: Self {
        Self(defaultOutputDevice: SystemOutputHardware.defaultOutputID, muteElements: SystemOutputHardware.muteElements,
             isMuted: SystemOutputHardware.isMuted, setMuted: SystemOutputHardware.setMuted)
    }
}

/// Uses the same mute control as the menu bar and keyboard, on the default
/// output device. Volume levels are never changed.
enum SystemOutputHardware {
    static func defaultOutputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func muteElements(_ device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        if isSettable(device, kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        let channels = AudioInputHardware.channelCount(device, scope: kAudioObjectPropertyScopeOutput)
        guard channels > 0 else { return [] }
        return (1...AudioObjectPropertyElement(channels)).filter { isSettable(device, $0) }
    }

    static func isMuted(_ device: AudioDeviceID, _ element: AudioObjectPropertyElement) -> Bool? {
        var address = muteAddress(element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<UInt32>.size else { return nil }
        return value != 0
    }

    static func setMuted(_ device: AudioDeviceID, _ element: AudioObjectPropertyElement, _ muted: Bool) -> Bool {
        var address = muteAddress(element)
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private static func muteAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    }

    private static func isSettable(_ device: AudioDeviceID, _ element: AudioObjectPropertyElement) -> Bool {
        var address = muteAddress(element)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }
}
