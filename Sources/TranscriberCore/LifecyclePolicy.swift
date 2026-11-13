import Foundation

public enum LifecyclePolicy {
    /// A take ends after this much time with no voice from `VoiceActivityGate`.
    /// The duration cap is `TranscriberAPI.maximumRecordingSeconds`.
    public static let silenceStopSeconds: TimeInterval = 60
}
