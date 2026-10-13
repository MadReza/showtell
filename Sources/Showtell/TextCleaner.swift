import Foundation
import ShowtellCore
import llama
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Tidies a dictated message with the model picked in Settings, and downloads the models that
/// need it. The text never leaves the Mac.
@MainActor
final class TextCleaner: ObservableObject {
    enum Status: Equatable {
        case ready
        case needsDownload
        case downloading(Double)
        /// Can't be used yet; the reason says what to do.
        case unavailable(String)
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @Published private(set) var downloads: [String: Double] = [:]
    @Published private(set) var downloadErrors: [String: String] = [:]
    /// The model's answer before the safety checks (for the --tidy self-test).
    private(set) var lastRaw = ""

    private let storage: Storage
    private let llama = LlamaRunner()
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var observations: [String: NSKeyValueObservation] = [:]

    init(storage: Storage) {
        self.storage = storage
    }

    func fileURL(_ model: CleanupModel) -> URL? {
        guard case .download(_, let file, _) = model.kind else { return nil }
        return storage.modelsURL.appendingPathComponent(file)
    }

    func status(_ model: CleanupModel) -> Status {
        switch model.kind {
        case .apple:
            if let reason = Self.appleUnavailableReason() { return .unavailable(reason) }
            return .ready
        case .download(_, _, let bytes):
            if let p = downloads[model.id] { return .downloading(p) }
            guard let url = fileURL(model),
                  let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64,
                  size == bytes else { return .needsDownload }
            return .ready
        }
    }

    // MARK: Downloads

    func download(_ model: CleanupModel) {
        guard case .download(let remote, _, let bytes) = model.kind, let dest = fileURL(model),
              tasks[model.id] == nil else { return }
        downloadErrors[model.id] = nil
        downloads[model.id] = 0
        try? FileManager.default.createDirectory(at: storage.modelsURL, withIntermediateDirectories: true)
        let id = model.id
        let task = URLSession.shared.downloadTask(with: remote) { [weak self] tmp, response, error in
            // The temporary file is gone once this returns, so move it here.
            var problem: String?
            if let error {
                problem = (error as NSError).code == NSURLErrorCancelled ? nil : error.localizedDescription
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                problem = "the server answered \(http.statusCode)"
            } else if let tmp {
                let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.size] as? Int64
                if size != bytes {
                    problem = "the download was incomplete"
                } else {
                    try? FileManager.default.removeItem(at: dest)
                    do { try FileManager.default.moveItem(at: tmp, to: dest) } catch { problem = error.localizedDescription }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.tasks[id] = nil
                    self.observations[id] = nil
                    self.downloads[id] = nil
                    if let problem { self.downloadErrors[id] = "Download failed: \(problem)" }
                }
            }
        }
        observations[id] = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self?.tasks[id] != nil { self?.downloads[id] = fraction }
                }
            }
        }
        tasks[id] = task
        task.resume()
    }

    func cancelDownload(_ model: CleanupModel) {
        tasks[model.id]?.cancel()
    }

    func delete(_ model: CleanupModel) {
        guard let url = fileURL(model) else { return }
        Task { await llama.unload(path: url.path) }
        try? FileManager.default.removeItem(at: url)
        objectWillChange.send()
    }

    /// Call before the app exits.
    nonisolated func shutdownBlocking() {
        let llama = MainActor.assumeIsolated { self.llama }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await llama.shutdown()
            done.signal()
        }
        done.wait()
    }

    // MARK: Cleaning

    /// Gets the model ready while you are still talking, so the clean-up starts at once.
    func prepare(_ model: CleanupModel) {
        guard status(model) == .ready else { return }
        switch model.kind {
        case .apple:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) { LanguageModelSession(instructions: "").prewarm() }
            #endif
        case .download:
            guard let path = fileURL(model)?.path else { return }
            let llama = llama
            Task.detached { try? await llama.load(path: path) }
        }
    }

    func clean(_ text: String, terms: [String], with model: CleanupModel) async -> Result<String, Failure> {
        switch status(model) {
        case .ready: break
        case .needsDownload: return .failure(Failure(description: "\(model.name) isn't downloaded yet (Settings → Tidy up text)"))
        case .downloading: return .failure(Failure(description: "\(model.name) is still downloading"))
        case .unavailable(let reason): return .failure(Failure(description: reason))
        }
        let instructions = Cleanup.instructions(terms: terms)
        do {
            let raw = try await run(model, instructions: instructions, input: Cleanup.modelText(text))
            lastRaw = raw
            if let cleaned = Cleanup.accept(original: text, cleaned: raw, terms: terms) { return .success(cleaned) }
            // A screenshot or a word went missing: tidy the text between screenshots piece by piece,
            // so every screenshot stays exactly where it was.
            var parts = Cleanup.split(text)
            var changed = false
            for i in parts.indices where !Cleanup.isMarker(parts[i]) && Cleanup.wordCount(parts[i]) >= 2 {
                let raw = try await run(model, instructions: instructions, input: parts[i])
                if let cleaned = Cleanup.accept(original: parts[i], cleaned: raw, terms: terms) {
                    parts[i] = cleaned
                    changed = true
                }
            }
            guard changed else {
                return .failure(Failure(description: "the tidied text dropped a screenshot or one of your words"))
            }
            return .success(Cleanup.join(parts))
        } catch {
            return .failure(Failure(description: "\(model.name) failed: \(error.localizedDescription)"))
        }
    }

    private func run(_ model: CleanupModel, instructions: String, input: String) async throws -> String {
        switch model.kind {
        case .apple:
            return try await Self.appleClean(input, instructions: instructions)
        case .download:
            guard let path = fileURL(model)?.path else { throw Failure(description: "no model file") }
            let llama = llama
            return try await Task.detached {
                try await llama.generate(path: path, system: instructions, user: input)
            }.value
        }
    }

    // MARK: Apple Intelligence

    static func appleUnavailableReason() -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Apple Intelligence is switched off: turn it on in System Settings → Apple Intelligence & Siri"
            case .unavailable(.modelNotReady):
                return "Apple Intelligence is still downloading its model; try again in a few minutes"
            case .unavailable(.deviceNotEligible):
                return "This Mac can't run Apple Intelligence"
            case .unavailable:
                return "Apple Intelligence isn't available right now"
            }
        }
        #endif
        return "Apple Intelligence needs macOS 26"
    }

    private static func appleClean(_ text: String, instructions: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: text, options: GenerationOptions(sampling: .greedy))
            return response.content
        }
        #endif
        throw Failure(description: "Apple Intelligence needs macOS 26")
    }
}

/// One downloaded model, loaded with llama.cpp and kept in memory for a few minutes after use.
actor LlamaRunner {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var loadedPath: String?
    private var idleUnload: Task<Void, Never>?
    private static let contextSize: UInt32 = 4096
    private static var backendReady = false

    func load(path: String) throws {
        if loadedPath == path, model != nil { return }
        unloadNow()
        if !Self.backendReady {
            llama_log_set({ _, _, _ in }, nil)  // quiet: llama.cpp logs every layer
            llama_backend_init()
            Self.backendReady = true
        }
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 999
        guard let m = llama_model_load_from_file(path, mp) else { throw Failure("couldn't load the model file") }
        var cp = llama_context_default_params()
        cp.n_ctx = Self.contextSize
        cp.n_batch = Self.contextSize
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            throw Failure("couldn't start the model")
        }
        model = m
        context = c
        loadedPath = path
    }

    func unload(path: String) {
        if loadedPath == path { unloadNow() }
    }

    /// llama.cpp's Metal backend aborts if the process exits with a model still loaded.
    func shutdown() {
        idleUnload?.cancel()
        unloadNow()
        if Self.backendReady {
            llama_backend_free()
            Self.backendReady = false
        }
    }

    private func unloadNow() {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil
        model = nil
        loadedPath = nil
    }

    func generate(path: String, system: String, user: String) throws -> String {
        try load(path: path)
        guard let model, let context else { throw Failure("model not loaded") }
        defer { scheduleUnload() }
        let vocab = llama_model_get_vocab(model)
        let prompt = try Self.chatPrompt(model: model, system: system, user: user)

        var tokens = [llama_token](repeating: 0, count: prompt.utf8.count + 16)
        let count = llama_tokenize(vocab, prompt, Int32(prompt.utf8.count), &tokens, Int32(tokens.count), true, true)
        guard count > 0 else { throw Failure("couldn't read the text") }
        // Leave room for an answer about as long as the question.
        let maxNew = Int(Double(count) * 0.6) + 128
        guard Int(count) + maxNew < Int(Self.contextSize) else { throw Failure("the message is too long to tidy") }
        tokens = Array(tokens.prefix(Int(count)))

        llama_memory_clear(llama_get_memory(context), true)
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var status = tokens.withUnsafeMutableBufferPointer { buf in
            llama_decode(context, llama_batch_get_one(buf.baseAddress, Int32(buf.count)))
        }
        var bytes: [CChar] = []
        var piece = [CChar](repeating: 0, count: 256)
        for _ in 0..<maxNew {
            guard status == 0 else { throw Failure("the model stopped (\(status))") }
            var next = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, next) { break }
            let n = llama_token_to_piece(vocab, next, &piece, Int32(piece.count), 0, false)
            if n > 0 { bytes += piece.prefix(Int(n)) }
            status = withUnsafeMutablePointer(to: &next) { llama_decode(context, llama_batch_get_one($0, 1)) }
        }
        return String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The model's own chat format with a system and a user message, ready for the answer.
    private static func chatPrompt(model: OpaquePointer, system: String, user: String) throws -> String {
        let template = llama_model_chat_template(model, nil)
        let role1 = strdup("system"), text1 = strdup(system), role2 = strdup("user"), text2 = strdup(user)
        defer { [role1, text1, role2, text2].forEach { free(UnsafeMutableRawPointer($0)) } }
        var messages = [llama_chat_message(role: role1, content: text1), llama_chat_message(role: role2, content: text2)]
        var buffer = [CChar](repeating: 0, count: (system.utf8.count + user.utf8.count) * 2 + 1024)
        var n = llama_chat_apply_template(template, &messages, 2, true, &buffer, Int32(buffer.count))
        if n > Int32(buffer.count) {
            buffer = [CChar](repeating: 0, count: Int(n) + 1)
            n = llama_chat_apply_template(template, &messages, 2, true, &buffer, Int32(buffer.count))
        }
        guard n > 0 else { throw Failure("the model has no chat format") }
        return String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Frees the model's memory (up to 3 GB) when it hasn't been used for five minutes.
    private func scheduleUnload() {
        idleUnload?.cancel()
        idleUnload = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.unloadNow()
        }
    }
}
