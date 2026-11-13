import Foundation

/// Hears sustained voice in short RMS windows, so a forgotten take can end.
/// An energy gate over an adaptive noise floor, not a speech model: steady
/// noise such as a fan sets the floor, and only louder sound that lasts
/// `minimumVoiceSeconds` counts. A click or a key press is shorter. Timing
/// comes from captured samples, never wall-clock time.
public struct VoiceActivityGate: Sendable {
    /// Voice is at least this far above the noise floor.
    static let marginDecibels = 10.0
    /// Voice also reaches this absolute level.
    static let minimumDecibels = -55.0
    static let minimumVoiceSeconds = 0.2
    /// The floor follows louder steady noise this slowly, far slower than a word.
    static let floorRiseDecibelsPerSecond = 1.0

    private var noiseFloor: Double?
    private var voicedFrames = 0

    public init() {}

    /// Returns true for each window that ends at least `minimumVoiceSeconds` of continuous voice.
    public mutating func update(rms: Double, frameCount: Int, sampleRate: Double) -> Bool {
        guard frameCount > 0, sampleRate.isFinite, sampleRate > 0 else { return false }
        let decibels = rms.isFinite && rms > 0 ? max(-100, 20 * log10(rms)) : -100
        let floor = noiseFloor ?? decibels
        let isVoice = decibels >= max(Self.minimumDecibels, floor + Self.marginDecibels)
        // Fall at once to quieter sound. Rise slowly toward louder sound, so
        // the pauses between words keep the floor at the room's noise.
        let rise = Self.floorRiseDecibelsPerSecond * Double(frameCount) / sampleRate
        noiseFloor = decibels < floor ? decibels : floor + min(decibels - floor, rise)
        voicedFrames = isVoice ? voicedFrames + frameCount : 0
        return Double(voicedFrames) >= (Self.minimumVoiceSeconds * sampleRate).rounded()
    }
}
