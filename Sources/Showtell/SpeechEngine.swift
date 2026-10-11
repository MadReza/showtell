@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import ShowtellCore

/// Live local transcription: microphone → FluidAudio streaming Parakeet, with your
/// terms boosted. Reports the transcript so far and when each new word ended.
final class SpeechEngine: @unchecked Sendable {
    enum State: Equatable { case notLoaded, loading(String), ready, failed(String) }

    private(set) var state: State = .notLoaded
    var onState: ((State) -> Void)?

    private let asr = StreamingUnifiedAsrManager()
    private var ctcModels: CtcModels?
    private var tokenizer: CtcTokenizer?
    private let audio = AVAudioEngine()
    private var pump: Task<Void, Never>?
    private var feed: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var samplesIn: Int64 = 0
    private var inputRate: Double = 48_000
    private let lock = NSLock()

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

    /// Seconds of audio captured since `start`.
    var elapsed: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(samplesIn) / inputRate
    }

    /// Starts listening. `onUpdate` gets the full transcript and the end times of newly timed words.
    func start(terms: [VocabularyTerm], onUpdate: @escaping @Sendable (String, [Double], Double) -> Void) async throws {
        try await asr.reset()
        await configureBoost(terms)

        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        resetClock(rate: format.sampleRate)
        let (stream, feed) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.feed = feed
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock(); self.samplesIn += Int64(buffer.frameLength); self.lock.unlock()
            feed.yield(buffer)
        }
        audio.prepare()
        try audio.start()

        // One consumer keeps audio in order; the transcript is refreshed about 4 times a second.
        pump = Task { [asr, unowned self] in
            var last = Date.distantPast
            for await buffer in stream {
                try? await asr.appendAudio(buffer)
                guard Date().timeIntervalSince(last) >= 0.25 else { continue }
                last = Date()
                try? await asr.processBufferedAudio()
                let text = await asr.getPartialTranscript()
                let ends = await asr.consumeWordTimings().map(\.endTime)
                onUpdate(text, ends, self.elapsed)
            }
        }
    }

    /// Stops listening and returns the final transcript (the tail is rescored),
    /// the last word timings and the audio time it covers.
    func stop() async -> (text: String, wordEnds: [Double], time: Double) {
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        feed?.finish()
        await pump?.value  // every captured buffer is appended before the flush
        pump = nil
        var text = await asr.getPartialTranscript()
        if let final = try? await asr.finish() { text = final }
        return (text, await asr.consumeWordTimings().map(\.endTime), elapsed)
    }

    func cancel() async {
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        feed?.finish()
        pump?.cancel()
        pump = nil
        try? await asr.reset()
    }

    /// Self-test: streams an audio file through the same path as the microphone, in real-time-sized chunks.
    func transcribeFile(_ url: URL, terms: [VocabularyTerm], onUpdate: @escaping @Sendable (String, [Double], Double) -> Void) async throws -> String {
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

    private func resetClock(rate: Double) {
        lock.lock(); defer { lock.unlock() }
        samplesIn = 0
        inputRate = rate
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
        DispatchQueue.main.async { self.onState?(s) }
    }
}
