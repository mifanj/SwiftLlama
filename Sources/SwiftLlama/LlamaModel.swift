import Foundation
import llama

class LlamaModel {
    private let model: Model
    private let configuration: Configuration
    private let context: OpaquePointer
    private let sampler: UnsafeMutablePointer<llama_sampler>
    private var batch: Batch
    private var tokens: [Token]
    private var temporaryInvalidCChars: [CChar] = []
    private var generatedTokenAccount: Int32 = 0
    private var ended = false
    private let n_len: Int32 = 1024

    var shouldContinue: Bool {
        generatedTokenAccount < configuration.maxTokenCount && !ended
    }

    init(path: String, configuration: Configuration = .init()) throws {
        self.configuration = configuration
        llama_backend_init()
        llama_numa_init(GGML_NUMA_STRATEGY_DISABLED)
        var model_params = llama_model_default_params()
        #if targetEnvironment(simulator)
        model_params.n_gpu_layers = 0
        #endif
        guard let model = llama_load_model_from_file(path, model_params) else {
            throw SwiftLlamaError.others("Cannot load model at path \(path)")
        }
        self.model = model
        guard let context = llama_new_context_with_model(model, configuration.contextParameters) else {
            throw SwiftLlamaError.others("Cannot load model context")
        }
        self.context = context
        self.tokens = []
        self.batch = llama_batch_init(Int32(configuration.batchSize * Configuration.historySize * 2), 0, 1)
        self.sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(configuration.temperature))
        llama_sampler_chain_add(sampler, llama_sampler_init_softmax())
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(1234))
        try checkContextLength(context: context, model: model)
    }

    private func checkContextLength(context: Context, model: Model) throws {
        let n_ctx = llama_n_ctx(context)
        let n_ctx_train = llama_n_ctx_train(model)
        if n_ctx > n_ctx_train {
            throw SwiftLlamaError.others("Model was trained on \(n_ctx_train) context but tokens \(n_ctx) specified")
        }
    }

    func start(for prompt: Prompt) throws {
        ended = false
        tokens = tokenize(text: prompt.prompt, addBos: true)
        temporaryInvalidCChars = []
        batch.clear()

        tokens.enumerated().forEach { index, token in
            batch.add(token: token, position: Int32(index), seqIDs: [0], logit: false)
        }
        batch.logits[Int(batch.n_tokens) - 1] = 1 // true

        if llama_decode(context, batch) != 0 {
            throw SwiftLlamaError.decodeError
        }
        generatedTokenAccount = batch.n_tokens
    }


    func validateUTF8String(from cChars: [CChar]) -> String? {
        let data = Data(cChars.map { UInt8($0) })
        guard let validString = String(data: data, encoding: .utf8) else {
            return nil
        }
        return validString
    }

    func `continue`() throws -> String {
        let newToken =  llama_sampler_sample(sampler, context, batch.n_tokens - 1)

        if llama_token_is_eog(model, newToken) || generatedTokenAccount == n_len {
            temporaryInvalidCChars.removeAll()
            ended = true
            return ""
        }


        let newTokenCChars = tokenToCChars(token: newToken)
        temporaryInvalidCChars.append(contentsOf: newTokenCChars)

        let newTokenStr: String
        if #available(iOS 18.0, *) {
            if let validString = String(validating: temporaryInvalidCChars + [0], as: UTF8.self) {
                newTokenStr = validString
                temporaryInvalidCChars.removeAll()
            } else if let suffixIndex = temporaryInvalidCChars.firstIndex(where: { $0 != 0 }),
                    let validSuffix = String(validating: Array(temporaryInvalidCChars.suffix(from: suffixIndex)) + [0],
                                            as: UTF8.self) {
                newTokenStr = validSuffix
                temporaryInvalidCChars.removeAll()
            } else {
                newTokenStr = ""
            }
        } else {
            if let validString = validateUTF8String(from: temporaryInvalidCChars + [0]) {
                newTokenStr = validString
                temporaryInvalidCChars.removeAll()
            } else if let suffixIndex = temporaryInvalidCChars.firstIndex(where: { $0 != 0 }),
                    let validSuffix = validateUTF8String(from: Array(temporaryInvalidCChars.suffix(from: suffixIndex)) + [0]) {
                newTokenStr = validSuffix
                temporaryInvalidCChars.removeAll()
            } else {
                newTokenStr = ""
            }
        }

        batch.clear()
        batch.add(token: newToken, position: generatedTokenAccount, seqIDs: [0], logit: true)
        generatedTokenAccount += 1

        if llama_decode(context, batch) != 0 {
            throw SwiftLlamaError.decodeError
        }
        return newTokenStr
    }

    private func tokenToCChars(token: llama_token) -> [CChar] {
        var length: Int32 = 8
        var piece = Array<CChar>(repeating: 0, count: Int(length))

        let nTokens = llama_token_to_piece(model, token, &piece, length, 0, false)
        if nTokens >= 0 {
            return Array(piece.prefix(Int(nTokens)))
        } else {
            length = -nTokens
            piece = Array<CChar>(repeating: 0, count: Int(length))
            let nNewTokens = llama_token_to_piece(model, token, &piece, length, 0, false)
            return Array(piece.prefix(Int(nNewTokens)))
        }
    }

    private func tokenize(text: String, addBos: Bool) -> [Token] {
        let utf8Count = text.utf8.count
        let n_tokens = utf8Count + (addBos ? 1 : 0) + 1
        
        return Array(unsafeUninitializedCapacity: n_tokens) { buffer, initializedCount in
            initializedCount = Int(
                llama_tokenize(model, text, Int32(utf8Count), buffer.baseAddress, Int32(n_tokens), addBos, false)
            )
        }
    }

    func clear() {
        tokens.removeAll()
        temporaryInvalidCChars.removeAll()
        llama_kv_cache_clear(context)
    }

    deinit {
        llama_batch_free(batch)
        llama_free(context)
        llama_free_model(model)
        llama_backend_free()
    }
}
