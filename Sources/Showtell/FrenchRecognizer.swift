@preconcurrency import AVFoundation
import Foundation
import Speech

/// French on Apple's on-device recogniser (SpeechAnalyzer + SpeechTranscriber, macOS 26). Measured
/// against FluidAudio's multilingual Nemotron on the same clips, it made about half the errors, and
/// Nemotron missed words spoken right at the start.
/// One instance per recording: feed it microphone buffers, read the transcript, finish once.
@available(macOS 26.0, *)
final class FrenchRecognizer: @unchecked Sendable {
    struct Unsupported: LocalizedError {
        let locale: String
        var errorDescription: String? { "this Mac has no on-device recogniser for \(locale)" }
    }

    /// Whether the language's model is on this Mac already (otherwise `prepare` downloads it).
    static func isInstalled(_ locale: Locale) async -> Bool {
        let id = locale.identifier(.bcp47)
        return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == id }
    }

    /// Downloads the language's model if needed (once; macOS keeps it for every app).
    static func prepare(_ locale: Locale) async throws {
        let id = locale.identifier(.bcp47)
        guard await SpeechTranscriber.supportedLocales.contains(where: { $0.identifier(.bcp47) == id }) else {
            throw Unsupported(locale: id)
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [makeTranscriber(locale)]) {
            try await request.downloadAndInstall()
        }
    }

    /// `fastResults`: without it, guesses arrive only once you pause (5–6 s late in testing);
    /// with it, about once a second.
    private static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                          attributeOptions: [.audioTimeRange])
    }

    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?
    private var reader: Task<Void, Never>?

    private let lock = NSLock()
    private var finalText = ""
    private var volatileText = ""
    private var finalWords = 0
    private var pendingStarts: [Double] = []

    /// `terms` are offered to the recogniser as likely words.
    init(locale: Locale, terms: [String]) async throws {
        let transcriber = Self.makeTranscriber(locale)
        analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Unsupported(locale: locale.identifier(.bcp47))
        }
        self.format = format
        if !terms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = terms
            try? await analyzer.setContext(context)
        }
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        self.input = input
        reader = Task { [weak self] in
            do {
                for try await result in transcriber.results { self?.received(result) }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Converts a microphone buffer to the recogniser's format and queues it.
    func append(_ buffer: AVAudioPCMBuffer) {
        if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
        guard let converter else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
    }

    /// The transcript so far: settled text plus the recogniser's current guess.
    var transcript: String {
        lock.lock(); defer { lock.unlock() }
        return Self.join(finalText, volatileText)
    }

    /// Start times of words settled since the last call.
    func consumeWordStarts() -> [Double] {
        lock.lock(); defer { lock.unlock() }
        defer { pendingStarts = [] }
        return pendingStarts
    }

    /// Waits for the recogniser to settle everything it was given; returns the final transcript.
    func finish() async -> String {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await reader?.value
        return transcript
    }

    func cancel() async {
        input.finish()
        await analyzer.cancelAndFinishNow()
        reader?.cancel()
    }

    private func received(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
        lock.lock(); defer { lock.unlock() }
        guard result.isFinal else {
            volatileText = text
            return
        }
        finalText = Self.join(finalText, text)
        volatileText = ""
        // A word starts at the first character after a space; one start per word keeps the count
        // in step with the transcript's words (an untimed run borrows the previous time).
        var atWordStart = true
        var starts: [Double] = []
        for run in result.text.runs {
            let piece = String(result.text[run.range].characters)
            for ch in piece {
                if ch.isWhitespace {
                    atWordStart = true
                } else if atWordStart {
                    atWordStart = false
                    starts.append(run.audioTimeRange?.start.seconds ?? starts.last ?? pendingStarts.last ?? 0)
                }
            }
        }
        pendingStarts += starts
    }

    private static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}
