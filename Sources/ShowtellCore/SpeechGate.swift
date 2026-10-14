import Foundation

/// Whether a recording held speech at all. The recogniser invents a word ("Yeah.") for a quick
/// press or a silent room; its transcript is thrown away unless the audio says someone spoke.
public enum SpeechGate {
    /// Shorter recordings are a press and a second press, not a message.
    public static let minimumDuration = 0.6
    /// Less speech than this (seconds) counts as none.
    public static let minimumSpeech = 0.15
    /// A transcript that is only a filler word needs this much speech to be kept: a spoken
    /// "Yeah." lasts about 0.3–0.5 s.
    public static let fillerSpeech = 0.3
    /// Silero's usual speech probability threshold.
    public static let vadThreshold: Float = 0.5
    /// The words the recogniser makes up from noise, or that you'd say only to yourself
    /// (English, then French).
    public static let fillers: Set<String> = [
        "yeah", "yes", "yep", "uh", "um", "umm", "uhm", "mm", "mhm", "hmm", "ah", "oh",
        "okay", "ok", "the", "a",
        "oui", "ouais", "euh", "heu", "hum", "ben", "bah", "bon", "hein", "le", "la",
    ]

    /// Keep the transcript of a recording `duration` seconds long holding `speech` seconds of speech?
    public static func keeps(_ transcript: String, duration: Double, speech: Double) -> Bool {
        guard duration >= minimumDuration, speech >= minimumSpeech else { return false }
        return !isLoneFiller(transcript) || speech >= fillerSpeech
    }

    public static func isLoneFiller(_ text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" })
        return words.count == 1 && fillers.contains(String(words[0]))
    }

    /// Seconds of speech by both measures. The voice detector, when there is one, decides whether
    /// anyone spoke (noise and clicks can be loud); the energy measure times it more finely.
    public static func speechSeconds(energy: Double, vad: Double?) -> Double {
        guard let vad else { return energy }
        return vad > 0 ? max(energy, vad) : 0
    }

    /// Seconds of voice-detector chunks that are likely speech.
    public static func vadSeconds(probabilities: [Float], chunkSeconds: Double) -> Double {
        Double(probabilities.filter { $0 >= vadThreshold }.count) * chunkSeconds
    }

    /// Frame length for `level(of:)`, in seconds.
    public static let frameSeconds = 0.02

    /// RMS level of one frame of samples, in dBFS (silence is -120).
    public static func level<C: Collection>(of samples: C) -> Float where C.Element == Float {
        guard !samples.isEmpty else { return -120 }
        let power = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        return power > 0 ? max(-120, 10 * log10(power)) : -120
    }

    /// Seconds of frames loud enough to be a voice: 12 dB over the room's noise floor (the quietest
    /// tenth of the recording), and never quieter than -55 dBFS. A frame of -38 dBFS or louder always
    /// counts, so a recording that is all speech (no quiet part to learn the floor from) still passes.
    public static func voicedSeconds(levels: [Float], frameSeconds: Double = frameSeconds) -> Double {
        guard !levels.isEmpty else { return 0 }
        let sorted = levels.sorted()
        let floor = sorted[sorted.count / 10]
        let threshold = min(max(floor + 12, -55), -38)
        return Double(levels.filter { $0 >= threshold }.count) * frameSeconds
    }
}
