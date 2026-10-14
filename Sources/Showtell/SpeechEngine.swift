@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import ShowtellCore

/// Live local transcription: microphone → FluidAudio streaming Parakeet, with your
/// terms boosted, for English; Apple's on-device recogniser for French (`FrenchRecognizer`).
/// An actor, so start, stop and cancel never overlap.
actor SpeechEngine {
    enum State: Equatable, Sendable { case notLoaded, loading(String), ready, failed(String) }

    /// Transcript so far, end times of newly timed words, and the audio time the transcript covers.
    typealias Update = @Sendable (_ text: String, _ wordStarts: [Double], _ time: Double) -> Void

    struct NoMicrophone: LocalizedError {
        var errorDescription: String? { "no microphone input is available" }
    }

    struct NeedsMacOS26: LocalizedError {
        var errorDescription: String? { "French dictation needs macOS 26" }
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
    private var vad: VadManager?
    private var meter: SpeechMeter?
    /// The recording's French recogniser (a `FrenchRecognizer`); nil while English runs.
    private var french: AnyObject?

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
            // Tells a silent recording from speech; without it, loudness alone decides.
            vad = try? await VadManager()
            setState(.ready)
        } catch {
            setState(.failed("Speech model failed to load: \(error.localizedDescription)"))
        }
    }

    /// Seconds of microphone audio captured since `start` (the clock screenshots are stamped with).
    nonisolated var captured: Double { clock.captured }

    /// Downloads the language's recogniser if this Mac doesn't have it yet. English is loaded by `load`.
    func prepare(_ language: DictationLanguage) async throws {
        guard language.isFrench else { return }
        guard #available(macOS 26.0, *) else { throw NeedsMacOS26() }
        try await FrenchRecognizer.prepare(Locale(identifier: language.localeIdentifier))
    }

    func start(language: DictationLanguage = .english, terms: [VocabularyTerm], onUpdate: @escaping Update) async throws {
        await stopAudio()
        if #available(macOS 26.0, *), let leftover = french as? FrenchRecognizer { await leftover.cancel() }  // a start that failed
        french = nil
        if language.isFrench {
            guard #available(macOS 26.0, *) else { throw NeedsMacOS26() }
            let locale = Locale(identifier: language.localeIdentifier)
            try await FrenchRecognizer.prepare(locale)
            french = try await FrenchRecognizer(locale: locale, terms: terms.map(\.text))
        } else {
            try await asr.reset()
            sawFirstToken = false
            await configureBoost(terms)
        }

        let engine = AVAudioEngine()  // fresh each time: picks up the current input device
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NoMicrophone() }
        clock.reset(rate: format.sampleRate)
        let meter = SpeechMeter(vad: vad)
        self.meter = meter

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

        if #available(macOS 26.0, *), let french = french as? FrenchRecognizer {
            pump = Task {
                var last = Date.distantPast
                for await buffer in stream {
                    french.append(buffer)
                    await meter.add(buffer)
                    clock.didProcess(buffer.frameLength, rate: buffer.format.sampleRate)
                    guard Date().timeIntervalSince(last) >= 0.25, !Task.isCancelled else { continue }
                    last = Date()
                    if !Task.isCancelled { onUpdate(french.transcript, french.consumeWordStarts(), clock.processed) }
                }
            }
            return
        }

        // One consumer keeps audio in order; the transcript is refreshed about 4 times a second.
        pump = Task { [asr] in
            var last = Date.distantPast
            for await buffer in stream {
                try? await asr.appendAudio(buffer)
                await meter.add(buffer)
                clock.didProcess(buffer.frameLength, rate: buffer.format.sampleRate)
                guard Date().timeIntervalSince(last) >= 0.25, !Task.isCancelled else { continue }
                last = Date()
                try? await asr.processBufferedAudio()
                let text = await asr.getPartialTranscript()
                let ends = await newWordStarts()
                if !Task.isCancelled { onUpdate(text, ends, clock.processed) }
            }
        }
    }

    /// Stops listening and returns the final transcript (the tail is rescored),
    /// the last word timings, the audio time it covers and the seconds of it that were speech.
    func stop() async -> (text: String, wordStarts: [Double], time: Double, speech: Double) {
        await stopAudio(drain: true)
        if #available(macOS 26.0, *), let recognizer = french as? FrenchRecognizer {
            french = nil
            let text = await recognizer.finish()
            return (text, recognizer.consumeWordStarts(), clock.processed, await takeSpeechSeconds())
        }
        var text = await asr.getPartialTranscript()
        if let final = try? await asr.finish() { text = final }
        return (text, await newWordStarts(), clock.processed, await takeSpeechSeconds())
    }

    private func takeSpeechSeconds() async -> Double {
        let speech = await meter?.speechSeconds() ?? 0
        meter = nil
        return speech
    }

    func cancel() async {
        await stopAudio()
        if #available(macOS 26.0, *), let recognizer = french as? FrenchRecognizer {
            french = nil
            await recognizer.cancel()
            return
        }
        try? await asr.reset()
        sawFirstToken = false
    }

    /// Self-test: streams an audio file through the same recogniser, in quarter-second chunks.
    func transcribeFile(_ url: URL, language: DictationLanguage = .english, terms: [VocabularyTerm],
                        onUpdate: Update) async throws -> (text: String, speech: Double) {
        if language.isFrench { return try await transcribeFrenchFile(url, language: language, terms: terms, onUpdate: onUpdate) }
        try await asr.reset()
        sawFirstToken = false
        await configureBoost(terms)
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate * 0.25)
        let meter = SpeechMeter(vad: vad)
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            try file.read(into: buffer, frameCount: chunk)
            try await asr.appendAudio(buffer)
            await meter.add(buffer)
            try await asr.processBufferedAudio()
            let seconds = Double(file.framePosition) / format.sampleRate
            onUpdate(await asr.getPartialTranscript(), await newWordStarts(), seconds)
        }
        let text = try await asr.finish()
        onUpdate(text, await newWordStarts(), Double(file.length) / format.sampleRate)
        return (text, await meter.speechSeconds())
    }

    private func transcribeFrenchFile(_ url: URL, language: DictationLanguage, terms: [VocabularyTerm],
                                      onUpdate: Update) async throws -> (text: String, speech: Double) {
        guard #available(macOS 26.0, *) else { throw NeedsMacOS26() }
        let locale = Locale(identifier: language.localeIdentifier)
        try await FrenchRecognizer.prepare(locale)
        let recognizer = try await FrenchRecognizer(locale: locale, terms: terms.map(\.text))
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate * 0.25)
        let meter = SpeechMeter(vad: vad)
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            try file.read(into: buffer, frameCount: chunk)
            recognizer.append(buffer)
            await meter.add(buffer)
            onUpdate(recognizer.transcript, recognizer.consumeWordStarts(), Double(file.framePosition) / format.sampleRate)
        }
        let text = await recognizer.finish()
        onUpdate(text, recognizer.consumeWordStarts(), Double(file.length) / format.sampleRate)
        return (text, await meter.speechSeconds())
    }

    /// Start times of the words begun since the last call. FluidAudio's own word grouping restarts
    /// with every batch, so a word split across two batches would count twice; a word starts only
    /// at a token carrying the `▁` boundary (or the very first token).
    private var sawFirstToken = false
    private func newWordStarts() async -> [Double] {
        var starts: [Double] = []
        for t in await asr.consumeTokenTimings() where !t.token.isEmpty && t.token != "<blank>" && t.token != "<pad>" {
            if !sawFirstToken || t.token.hasPrefix("▁") || t.token.hasPrefix(" ") { starts.append(t.startTime) }
            sawFirstToken = true
        }
        return starts
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
        // Stricter than FluidAudio's defaults (0.52 / 0.54, acoustic rescue on), which turned
        // "how well" into Showtell and "header" into herdr in testing. Aliases bypass these checks.
        let tokenized = terms.compactMap { t -> CustomVocabularyTerm? in
            let ids = tokenizer.encode(t.text)
            return ids.isEmpty ? nil : CustomVocabularyTerm(text: t.text, aliases: t.aliases, ctcTokenIds: ids)
        }
        guard !tokenized.isEmpty else { return }
        try? await asr.configureVocabularyBoosting(
            vocabulary: CustomVocabularyContext(terms: tokenized, minSimilarity: 0.7, minCombinedConfidence: 0.7),
            ctcModels: ctcModels,
            config: VocabularyRescorer.Config(spotterRescueEnabled: false))
    }

    private func setState(_ s: State) {
        state = s
        onState(s)
    }
}

/// Measures how much of a recording is speech, as it is captured: the loudness of each 20 ms frame,
/// and the voice detector's verdict on each 256 ms chunk (until it has heard plenty).
actor SpeechMeter {
    private let vad: VadManager?
    private let converter = AudioConverter()
    private var vadState: VadStreamState?
    private var levels: [Float] = []
    private var frame: [Float] = []
    private var chunk: [Float] = []
    private var probabilities: [Float] = []
    private var vadFailed = false

    init(vad: VadManager?) {
        self.vad = vad
    }

    func add(_ buffer: AVAudioPCMBuffer) async {
        guard let samples = try? converter.resampleBuffer(buffer) else { return }
        let frameLength = Int(SpeechGate.frameSeconds * Double(VadManager.sampleRate))
        frame += samples
        while frame.count >= frameLength {
            levels.append(SpeechGate.level(of: frame.prefix(frameLength)))
            frame.removeFirst(frameLength)
        }
        guard vad != nil, !vadFailed, vadSeconds < 2 else { chunk = []; return }
        chunk += samples
        while chunk.count >= VadManager.chunkSize {
            await detect(Array(chunk.prefix(VadManager.chunkSize)))
            chunk.removeFirst(VadManager.chunkSize)
        }
    }

    /// Seconds of speech heard, by the voice detector if it ran and by loudness.
    func speechSeconds() async -> Double {
        if chunk.count >= VadManager.sampleRate / 10 { await detect(chunk) }  // the last 0.1 s or more
        chunk = []
        let energy = SpeechGate.voicedSeconds(levels: levels)
        guard vad != nil, !vadFailed else { return energy }
        return SpeechGate.speechSeconds(energy: energy, vad: vadSeconds)
    }

    private var vadSeconds: Double {
        SpeechGate.vadSeconds(probabilities: probabilities, chunkSeconds: Double(VadManager.chunkSize) / Double(VadManager.sampleRate))
    }

    private func detect(_ samples: [Float]) async {
        guard let vad else { return }
        do {
            let state: VadStreamState
            if let vadState { state = vadState } else { state = await vad.makeStreamState() }
            let result = try await vad.processStreamingChunk(samples, state: state)
            vadState = result.state
            probabilities.append(result.probability)
        } catch {
            vadFailed = true
        }
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
