import Foundation
import Observation
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
        let bounded = elapsed.isFinite ? min(LifecyclePolicy.maximumRecordingSeconds, max(0, elapsed)) : 0
        let seconds = Int(bounded)
        if seconds != elapsedSeconds { elapsedSeconds = seconds }
        let remaining = Int(LifecyclePolicy.maximumRecordingSeconds) - seconds
        let notice: RecordingLimitNotice? = (1...30).contains(remaining) ? .approaching(secondsRemaining: remaining) : nil
        if limitNotice != notice { limitNotice = notice }
    }

    func finish(atLimit: Bool) {
        let notice: RecordingLimitNotice? = atLimit ? .stopped : nil
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

enum RecordingLimitNotice: Equatable {
    case approaching(secondsRemaining: Int)
    case stopped

    var text: String {
        switch self {
        case .approaching(let seconds): "Recording limit in \(transcriberDuration(Double(seconds)))"
        case .stopped: "Stopped at the 3-minute limit"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .approaching: "Recording is approaching the three-minute limit"
        case .stopped: text
        }
    }
}
