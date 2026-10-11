@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import ShowtellCore

/// Live local transcription: microphone → FluidAudio streaming Parakeet, with your
/// terms boosted. An actor, so start, stop and cancel never overlap.
actor SpeechEngine {
    enum State: Equatable, Sendable { case notLoaded, loading(String), ready, failed(String) }

    /// Transcript so far, end times of newly timed words, and the audio time the transcript covers.
    typealias Update = @Sendable (_ text: String, _ wordEnds: [Double], _ time: Double) -> Void

    struct NoMicrophone: LocalizedError {
        var errorDescription: String? { "no microphone input is available" }
    }

    private(set) var state: State = .notLoaded
    private let onState: @Sendable (State) -> Void

    private let asr = StreamingUnifiedAsrManager()
    private var ctcModels: CtcModels?
    private var tokenizer: CtcTokenizer?
    private var audio: AVAudioEngine?
    private var pump: Task<Void, Never>?
    private var feed: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var configObserver: NSObjectProtocol?
    private let clock = AudioClock()

    init(onState: @escaping @Sendable (State) -> Void) {
        self.onState = onState
    }

    /// Downloads (first run only) and loads the speech and word-boost models.
    func load() async {
        setState(.loading("Loading speech model… (the first run downloads about 700 MB)"))
        do {
            try await asr.loadModels()
            setState(.loading("Loading word booster…"))
            ctcModels = try await CtcModels.downloadAndLoad()
            tokenizer = try await CtcTokenizer.load()
            setState(.ready)
        } catch {
            setState(.failed("Speech model failed to load: \(error.localizedDescription)"))
        }
    }

    /// Seconds of microphone audio captured since `start` (the clock screenshots are stamped with).
    nonisolated var captured: Double { clock.captured }

    func start(terms: [VocabularyTerm], onUpdate: @escaping Update) async throws {
        await stopAudio()
        try await asr.reset()
        await configureBoost(terms)

        let engine = AVAudioEngine()  // fresh each time: picks up the current input device
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NoMicrophone() }
        clock.reset(rate: format.sampleRate)

        let (stream, feed) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.feed = feed
        let clock = clock
        let tap: AVAudioNodeTapBlock = { buffer, _ in
            clock.didCapture(buffer.frameLength)
            feed.yield(buffer)
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format, block: tap)
        engine.prepare()
        try engine.start()
        audio = engine

        // A headset plugged in or removed stops the engine: reinstall the tap in the new format.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in
            let fmt = engine.inputNode.outputFormat(forBus: 0)
            engine.inputNode.removeTap(onBus: 0)
            guard fmt.sampleRate > 0, fmt.channelCount > 0 else { return }
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: fmt, block: tap)
            try? engine.start()
        }

        // One consumer keeps audio in order; the transcript is refreshed about 4 times a second.
        pump = Task { [asr] in
            var last = Date.distantPast
            for await buffer in stream {
                try? await asr.appendAudio(buffer)
                clock.didProcess(buffer.frameLength, rate: buffer.format.sampleRate)
                guard Date().timeIntervalSince(last) >= 0.25, !Task.isCancelled else { continue }
                last = Date()
                try? await asr.processBufferedAudio()
                let text = await asr.getPartialTranscript()
                let ends = await asr.consumeWordTimings().map(\.endTime)
                if !Task.isCancelled { onUpdate(text, ends, clock.processed) }
            }
        }
    }

    /// Stops listening and returns the final transcript (the tail is rescored),
    /// the last word timings and the audio time it covers.
    func stop() async -> (text: String, wordEnds: [Double], time: Double) {
        await stopAudio(drain: true)
        var text = await asr.getPartialTranscript()
        if let final = try? await asr.finish() { text = final }
        return (text, await asr.consumeWordTimings().map(\.endTime), clock.processed)
    }

    func cancel() async {
        await stopAudio()
        try? await asr.reset()
    }

    /// Self-test: streams an audio file through the same recogniser, in quarter-second chunks.
    func transcribeFile(_ url: URL, terms: [VocabularyTerm], onUpdate: Update) async throws -> String {
        try await asr.reset()
        await configureBoost(terms)
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate * 0.25)
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            try file.read(into: buffer, frameCount: chunk)
            try await asr.appendAudio(buffer)
            try await asr.processBufferedAudio()
            let seconds = Double(file.framePosition) / format.sampleRate
            onUpdate(await asr.getPartialTranscript(), await asr.consumeWordTimings().map(\.endTime), seconds)
        }
        let text = try await asr.finish()
        onUpdate(text, await asr.consumeWordTimings().map(\.endTime), Double(file.length) / format.sampleRate)
        return text
    }

    /// Stops the microphone. With `drain`, waits until every captured buffer reached the recogniser.
    private func stopAudio(drain: Bool = false) async {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        audio?.inputNode.removeTap(onBus: 0)
        audio?.stop()
        audio = nil
        feed?.finish()
        feed = nil
        if !drain { pump?.cancel() }
        await pump?.value
        pump = nil
    }

    private func configureBoost(_ terms: [VocabularyTerm]) async {
        guard let ctcModels, let tokenizer, !terms.isEmpty else { return }
        let tokenized = terms.compactMap { t -> CustomVocabularyTerm? in
            let ids = tokenizer.encode(t.text)
            return ids.isEmpty ? nil : CustomVocabularyTerm(text: t.text, aliases: t.aliases, ctcTokenIds: ids)
        }
        guard !tokenized.isEmpty else { return }
        try? await asr.configureVocabularyBoosting(
            vocabulary: CustomVocabularyContext(terms: tokenized), ctcModels: ctcModels)
    }

    private func setState(_ s: State) {
        state = s
        onState(s)
    }
}

/// Sample counters shared with the real-time audio thread.
final class AudioClock: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedFrames: Int64 = 0
    private var rate: Double = 48_000
    private var processedSeconds: Double = 0

    func reset(rate: Double) {
        lock.lock(); defer { lock.unlock() }
        capturedFrames = 0
        processedSeconds = 0
        self.rate = rate
    }

    func didCapture(_ frames: AVAudioFrameCount) {
        lock.lock(); defer { lock.unlock() }
        capturedFrames += Int64(frames)
    }

    func didProcess(_ frames: AVAudioFrameCount, rate: Double) {
        lock.lock(); defer { lock.unlock() }
        processedSeconds += Double(frames) / rate
    }

    var captured: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(capturedFrames) / rate
    }

    var processed: Double {
        lock.lock(); defer { lock.unlock() }
        return processedSeconds
    }
}
