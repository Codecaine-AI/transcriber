import Foundation
import Observation
import TranscriberAPI
import TranscriberCore

/// High-frequency feedback is observed only by the waveform, clock and limit
/// note leaves, never forwarded through the dashboard's controller. Observation
/// tracks each property on its own, so the meter never redraws the clock or note.
/// Views read these values in `body` and never copy them into `@State`: a copy
/// can miss the change back to nil and leave a stale notice on screen.
@MainActor
@Observable
final class RecordingFeedback {
    private(set) var levels = Array(repeating: Float(0), count: 9)
    private(set) var elapsedSeconds = 0
    private(set) var limitNotice: RecordingLimitNotice?

    func append(_ level: Float) {
        let sample = level.isFinite ? min(1, max(0, level)) : 0
        let next = Array(levels.dropFirst()) + [sample]
        // Old peaks still drain through the history; settled silence is free.
        if next != levels { levels = next }
    }

    func updateElapsed(_ elapsed: TimeInterval) {
        let cap = TranscriberAPI.maximumRecordingSeconds
        let bounded = elapsed.isFinite ? min(TimeInterval(cap), max(0, elapsed)) : 0
        let seconds = Int(bounded)
        if seconds != elapsedSeconds { elapsedSeconds = seconds }
        let remaining = cap - seconds
        let notice: RecordingLimitNotice? = (1...30).contains(remaining) ? .approaching(secondsRemaining: remaining) : nil
        if limitNotice != notice { limitNotice = notice }
    }

    func finish(automaticStop: AutomaticStop?) {
        let notice = automaticStop.map(RecordingLimitNotice.stopped)
        if limitNotice != notice { limitNotice = notice }
    }

    func clearLevels() {
        let silence = Array(repeating: Float(0), count: 9)
        if levels != silence { levels = silence }
    }

    func reset() {
        clearLevels()
        if elapsedSeconds != 0 { elapsedSeconds = 0 }
        if limitNotice != nil { limitNotice = nil }
    }
}

/// Why the app, not the person, ended a take.
enum AutomaticStop: Equatable {
    case durationLimit
    case silence
}

enum RecordingLimitNotice: Equatable {
    case approaching(secondsRemaining: Int)
    case stopped(AutomaticStop)

    private static let capMinutes = TranscriberAPI.maximumRecordingSeconds / 60

    var text: String {
        switch self {
        case .approaching(let seconds): "Recording limit in \(transcriberDuration(Double(seconds)))"
        case .stopped(.durationLimit): "Stopped at the \(Self.capMinutes)-minute limit"
        case .stopped(.silence): "Stopped after \(Int(LifecyclePolicy.silenceStopSeconds)) s of silence"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .approaching: "Recording is approaching the \(Self.capMinutes)-minute limit"
        case .stopped: text
        }
    }
}
