#if canImport(FoundationModels) && !os(tvOS) && !os(watchOS)
import CoreGraphics
import Foundation
import FoundationModels
import ImageIO

/// Apple's Foundation Models as a model provider: the on-device system model, Private Cloud Compute, or any other
/// `LanguageModel`, used by conversations like any other provider.
///
/// ```swift
/// let models = Models()
/// try await models.register(FoundationModelsProvider())
/// let harness = try await Harness.open(.sqlite(at: url), models: models, extensions: [assistant])
/// let root = try await harness.root(agent: AgentChange(model: .appleOnDevice))
/// ```
///
/// Requests run in a `LanguageModelSession` over the conversation's transcript. Tool calls return to pi-durable, which
/// runs them durably like any other provider's; the session never runs a tool itself. Tools whose parameters Foundation
/// Models cannot express, such as untyped properties, are not offered to these models. No credentials are needed; check
/// ``Model/isAvailable`` before offering a model. The on-device window (8,192 tokens) is too small for pi-durable's
/// default compaction: open the harness with ``Settings/Compaction/forContextWindow(_:)``.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
public struct FoundationModelsProvider: Sendable {
    /// One model of the provider: a `LanguageModel` under an ID.
    public struct Model: Sendable {
        /// The model ID conversations select it by.
        public let id: String
        public var name: String
        /// Tokens of context; by default the model's own size.
        public var contextWindow: Int?
        let model: any LanguageModel

        /// - Parameters:
        ///   - id: The model ID conversations select it by.
        ///   - name: A display name.
        ///   - contextWindow: Tokens of context; by default the model's own size where it reports one, else 4096.
        ///   - model: The model, such as a `SystemLanguageModel` configured for a use case.
        public init(_ id: String, name: String? = nil, contextWindow: Int? = nil, model: some LanguageModel) {
            self.id = id
            self.name = name ?? id
            self.contextWindow = contextWindow
            self.model = model
        }

        /// The on-device system model (Apple Foundation Model), or one configured for a use case or guardrails.
        public static func onDevice(_ model: SystemLanguageModel = .default, id: String = ModelRef.appleOnDevice.modelId) -> Model {
            Model(id, name: "On-Device", model: model)
        }

        /// Apple's larger model on Private Cloud Compute.
        public static var privateCloudCompute: Model {
            Model(ModelRef.applePrivateCloudCompute.modelId, name: "Private Cloud Compute", model: PrivateCloudComputeLanguageModel())
        }

        /// Whether the model can answer now: Apple Intelligence is enabled and the model downloaded, or Private Cloud
        /// Compute is reachable. Other models are assumed available.
        public var isAvailable: Bool {
            if let system = model as? SystemLanguageModel { return system.isAvailable }
            if let cloud = model as? PrivateCloudComputeLanguageModel { return cloud.isAvailable }
            return true
        }

        /// The model's context window, as reported.
        func resolvedContextWindow() async -> Int {
            if let contextWindow { return contextWindow }
            if let system = model as? SystemLanguageModel { return system.contextSize }
            if let cloud = model as? PrivateCloudComputeLanguageModel, let size = try? await cloud.contextSize { return size }
            return 4096
        }
    }

    public let id: ProviderID
    public var name: String
    public var models: [Model]

    /// - Parameters:
    ///   - id: The provider ID; `apple` by default, which ``ModelRef/appleOnDevice`` and
    ///     ``ModelRef/applePrivateCloudCompute`` name.
    ///   - name: A display name.
    ///   - models: The models; by default the on-device model and Private Cloud Compute.
    public init(id: ProviderID = .apple, name: String = "Apple", models: [Model] = [.onDevice(), .privateCloudCompute]) {
        self.id = id
        self.name = name
        self.models = models
    }

    /// A reference to one of the provider's models.
    public func model(_ id: String) -> ModelRef { ModelRef(provider: self.id, modelId: id) }
}

extension ProviderID {
    /// Apple's Foundation Models (``FoundationModelsProvider``).
    public static let apple: ProviderID = "apple"
}

extension ModelRef {
    /// The on-device system model of ``FoundationModelsProvider``.
    public static let appleOnDevice = ModelRef(provider: .apple, modelId: "on-device")
    /// Private Cloud Compute, of ``FoundationModelsProvider``.
    public static let applePrivateCloudCompute = ModelRef(provider: .apple, modelId: "private-cloud-compute")
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
extension Models {
    /// Registers Apple Foundation Models (or replaces a provider with the same ID).
    public func register(_ provider: FoundationModelsProvider) async throws {
        try await prepare()
        runtime.engine.host.removeLanguageModels(models: id, provider: provider.id)
        var specifications: [JSONValue] = []
        for model in provider.models {
            let capabilities = model.model.capabilities
            let contextWindow = await model.resolvedContextWindow()
            specifications.append([
                "id": .string(model.id),
                "name": .string(model.name),
                "contextWindow": .number(Double(contextWindow)),
                "maxTokens": .number(Double(contextWindow)),
                "reasoning": .bool(capabilities.contains(.reasoning)),
                "input": capabilities.contains(.vision) ? ["text", "image"] : ["text"],
            ])
            let responder = FoundationModelsResponder(model: model.model)
            runtime.engine.host.setLanguageModel(models: id, provider: provider.id, model: model.id) { request, emit in
                try await responder.respond(to: request, emit: emit)
            }
        }
        try await perform(
            "models.addFoundationModels", ["provider": provider.id, "name": provider.name, "models": specifications])
    }
}

// MARK: Requests

/// Answers pi-ai requests with a `LanguageModelSession` over the request's messages.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
struct FoundationModelsResponder: Sendable {
    let model: any LanguageModel

    /// Thrown by every tool, so the session stops at the model's tool calls and pi-durable runs them.
    struct ToolCallsRequested: Error {}

    /// A pi tool as the session sees it: its definition only.
    struct HostTool: FoundationModels.Tool {
        let name: String
        let description: String
        let parameters: GenerationSchema

        func call(arguments: GeneratedContent) async throws -> String {
            throw ToolCallsRequested()
        }
    }

    func respond(to request: JSONValue, emit: @escaping @Sendable (JSONValue) -> Void) async throws -> JSONValue {
        if let unavailable = availabilityError(model) {
            return Self.answer(stopReason: "error", usage: nil, error: unavailable)
        }
        let messages = try (request["messages"] ?? []).decode(as: [Message].self)
        // A tool whose schema Foundation Models cannot express, such as one with untyped properties, is not offered.
        let tools = (request["tools"]?.arrayValue ?? []).compactMap { try? Self.tool($0) }
        let options = request["options"] ?? [:]
        let vision = model.capabilities.contains(.vision)

        // The trailing user message is the prompt; after tool results, the session continues from an empty one.
        var history = messages
        var prompt: UserMessage?
        if case .user(let last)? = history.last {
            prompt = last
            history.removeLast()
        }
        var entries: [Transcript.Entry] = []
        let instructions = request["instructions"]?.stringValue ?? ""
        if !instructions.isEmpty || !tools.isEmpty {
            entries.append(.instructions(Transcript.Instructions(
                segments: instructions.isEmpty ? [] : [.text(.init(content: instructions))],
                toolDefinitions: tools.map(Transcript.ToolDefinition.init(tool:)))))
        }
        for message in history { entries += try Self.entries(for: message, vision: vision) }
        // The on-device model counts tokens locally: an overflow is reported before the request, in the same words on
        // every platform, so pi-durable compacts and retries.
        if let system = model as? SystemLanguageModel {
            let counted = entries + [.prompt(Transcript.Prompt(segments: Self.segments(prompt?.content ?? [], vision: vision)))]
            if let tokens = try? await system.tokenCount(for: counted), tokens > system.contextSize {
                return Self.answer(stopReason: "error", usage: nil, error: Self.overflow(tokens: tokens, contextSize: system.contextSize))
            }
        }
        let session = LanguageModelSession(model: model, tools: tools, transcript: Transcript(entries: entries))
        session.transcriptErrorHandlingPolicy = .preserveTranscript
        let start = session.transcript.count

        let maxTokens = options["maxTokens"]?.intValue
        let generation = GenerationOptions(
            samplingMode: nil, temperature: options["temperature"]?.doubleValue, maximumResponseTokens: maxTokens,
            toolCallingMode: tools.isEmpty ? nil : Self.toolCallingMode(options["toolChoice"]))
        let context = ContextOptions(
            reasoningLevel: model.capabilities.contains(.reasoning) ? Self.reasoningLevel(options["reasoning"]?.stringValue) : nil)

        var text = ""
        var thinking = ""
        var usage: LanguageModelSession.Usage?
        do {
            let stream = session.streamResponse(
                to: Self.prompt(prompt, vision: vision), options: generation, contextOptions: context, metadata: [:])
            for try await snapshot in stream {
                // A Foundation Models stream runs on when its task is cancelled; stop it here.
                try Task.checkCancellation()
                usage = snapshot.usage
                let reasoning = Self.reasoning(in: snapshot.transcriptEntries)
                if reasoning.count > thinking.count, reasoning.hasPrefix(thinking) {
                    emit(["type": "thinking", "delta": .string(String(reasoning.dropFirst(thinking.count)))])
                }
                thinking = reasoning
                let content = snapshot.content
                if content.count > text.count, content.hasPrefix(text) {
                    emit(["type": "text", "delta": .string(String(content.dropFirst(text.count)))])
                }
                text = content
            }
            try Task.checkCancellation()
            let final = usage ?? session.usage
            let truncated = maxTokens.map { final.output.totalTokenCount >= $0 } ?? false
            return Self.answer(stopReason: truncated ? "length" : "stop", usage: final, text: text, thinking: thinking)
        } catch let error as LanguageModelSession.ToolCallError where error.underlyingError is ToolCallsRequested {
            let added = session.transcript.dropFirst(start)
            let calls = added.compactMap { entry -> Transcript.ToolCalls? in
                if case .toolCalls(let calls) = entry { return calls }
                return nil
            }.last
            let toolCalls: [JSONValue] = try (calls.map(Array.init) ?? []).map { call in
                [
                    "id": .string(call.id), "name": .string(call.toolName),
                    "arguments": try JSONValue(json: call.arguments.jsonString),
                ]
            }
            // Text the model wrote before its calls, as the transcript recorded it.
            let written = added.compactMap { entry -> String? in
                if case .response(let response) = entry { return Self.text(of: response.segments) }
                return nil
            }.joined()
            return Self.answer(
                stopReason: "toolUse", usage: session.usage, toolCalls: toolCalls, text: written.isEmpty ? text : written,
                thinking: Self.reasoning(in: added))
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            return Self.answer(stopReason: "error", usage: usage ?? session.usage, error: Self.message(for: error), text: text)
        }
    }

    /// Why a model cannot answer now, in words pi-ai retries when waiting helps (a model still downloading).
    func availabilityError(_ model: any LanguageModel) -> String? {
        if let system = model as? SystemLanguageModel, case .unavailable(let reason) = system.availability {
            switch reason {
            case .modelNotReady: return "Apple's on-device model is not ready yet (service unavailable while it downloads)"
            case .appleIntelligenceNotEnabled: return "Apple's on-device model is unavailable: Apple Intelligence is not enabled"
            case .deviceNotEligible: return "Apple's on-device model is unavailable: this device is not eligible"
            @unknown default: return "Apple's on-device model is unavailable: \(reason)"
            }
        }
        if let cloud = model as? PrivateCloudComputeLanguageModel, case .unavailable(let reason) = cloud.availability {
            switch reason {
            case .systemNotReady: return "Private Cloud Compute is not ready yet (service unavailable)"
            case .deviceNotEligible: return "Private Cloud Compute is unavailable: this device is not eligible"
            @unknown default: return "Private Cloud Compute is unavailable: \(reason)"
            }
        }
        return nil
    }

    static func answer(
        stopReason: String, usage: LanguageModelSession.Usage?, toolCalls: [JSONValue] = [], error: String? = nil,
        text: String = "", thinking: String = ""
    ) -> JSONValue {
        var answer: JSONObject = [
            "stopReason": .string(stopReason),
            "toolCalls": .array(toolCalls),
            "text": .string(text),
            "thinking": .string(thinking),
            "usage": [
                "input": .number(Double(usage?.input.totalTokenCount ?? 0)),
                "cachedInput": .number(Double(usage?.input.cachedTokenCount ?? 0)),
                "output": .number(Double(usage?.output.totalTokenCount ?? 0)),
                "reasoning": .number(Double(usage?.output.reasoningTokenCount ?? 0)),
            ],
        ]
        if let error { answer["errorMessage"] = .string(error) }
        return .object(answer)
    }

    static func reasoning(in entries: some Sequence<Transcript.Entry>) -> String {
        entries.compactMap { entry -> String? in
            if case .reasoning(let reasoning) = entry { return text(of: reasoning.segments) }
            return nil
        }.joined(separator: "\n")
    }

    /// Error text in the words pi-ai classifies: a context overflow as one, so pi-durable compacts and retries, and
    /// transient failures (rate limits, timeouts, network, a busy service) as retryable; refusals and guardrail
    /// violations are not retried.
    static func message(for error: Error) -> String {
        let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        if let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded(let exceeded):
                return overflow(tokens: exceeded.tokenCount, contextSize: exceeded.contextSize)
            case .rateLimited: return "Rate limit reached: \(detail)"
            case .timeout: return "Request timed out: \(detail)"
            case .guardrailViolation: return "Guardrail violation: \(detail)"
            case .refusal: return "The model refused: \(detail)"
            default: return detail
            }
        }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return "The input exceeds the context window: \(detail)"
            case .rateLimited: return "Rate limit reached: \(detail)"
            case .assetsUnavailable: return "The model's assets are unavailable (service unavailable): \(detail)"
            case .concurrentRequests: return "The model is busy with other requests (service unavailable): \(detail)"
            default: return detail
            }
        }
        if let error = error as? PrivateCloudComputeLanguageModel.Error {
            switch error {
            case .networkFailure: return "Network error reaching Private Cloud Compute: \(detail)"
            case .serviceUnavailable: return "Private Cloud Compute: service unavailable: \(detail)"
            case .quotaLimitReached: return "Private Cloud Compute quota limit reached: \(detail)"
            @unknown default: return detail
            }
        }
        if case .assetsUnavailable? = error as? SystemLanguageModel.Error {
            return "Apple's on-device model assets are unavailable (service unavailable): \(detail)"
        }
        return detail
    }

    /// A context overflow in pi-ai's words, with what lets pi-durable compact a window this small.
    static func overflow(tokens: Int, contextSize: Int) -> String {
        "Input of \(tokens) tokens exceeds the context window of \(contextSize) tokens. To compact conversations this "
            + "small, open the harness with Settings(compaction: .forContextWindow(\(contextSize)))."
    }

    static func toolCallingMode(_ choice: JSONValue?) -> GenerationOptions.ToolCallingMode? {
        switch choice?.stringValue {
        case "none"?: .disallowed
        case "required"?, "any"?: .required
        default: nil
        }
    }

    static func reasoningLevel(_ level: String?) -> ContextOptions.ReasoningLevel? {
        switch level {
        case "minimal"?, "low"?: .light
        case "medium"?: .moderate
        case "high"?, "xhigh"?, "max"?: .deep
        default: nil
        }
    }

    // MARK: Conversion

    static func tool(_ json: JSONValue) throws -> HostTool {
        let name = json["name"]?.stringValue ?? ""
        let parameters: GenerationSchema
        do {
            let schema = normalizedSchema(json["parameters"] ?? [:], path: name.isEmpty ? "Arguments" : name)
            parameters = try JSONDecoder().decode(GenerationSchema.self, from: JSONEncoder().encode(schema))
        } catch {
            throw PiDurableError.runtime("Foundation Models cannot use the parameters of tool \(name): \(error)")
        }
        return HostTool(name: name, description: json["description"]?.stringValue ?? "", parameters: parameters)
    }

    /// A JSON schema as every Foundation Models version decodes it: objects state `additionalProperties`, and every
    /// `anyOf` has a `title`. (Property order arrives as `x-order` from JavaScript, where key order survives.)
    static func normalizedSchema(_ schema: JSONValue, path: String) -> JSONValue {
        switch schema {
        case .array(let items):
            return .array(items.enumerated().map { normalizedSchema($1, path: "\(path)\($0)") })
        case .object(var object):
            for (key, value) in object {
                if key == "properties", case .object(let properties) = value {
                    object[key] = .object(properties.reduce(into: [:]) { $0[$1.key] = normalizedSchema($1.value, path: "\(path)_\($1.key)") })
                } else {
                    object[key] = normalizedSchema(value, path: "\(path)_\(key)")
                }
            }
            let title = JSONValue.string(String(path.map { $0.isLetter || $0.isNumber ? $0 : "_" }))
            if object["type"]?.stringValue == "object" {
                let properties = object["properties"]?.objectValue ?? [:]
                if object["properties"] == nil { object["properties"] = [:] }
                if object["additionalProperties"] == nil { object["additionalProperties"] = false }
                if object["required"] == nil { object["required"] = [] }
                if object["x-order"] == nil { object["x-order"] = .array(properties.keys.sorted().map(JSONValue.string)) }
                if object["title"] == nil { object["title"] = title }
            }
            if object["anyOf"] != nil, object["title"] == nil { object["title"] = title }
            return .object(object)
        default:
            return schema
        }
    }

    static func entries(for message: Message, vision: Bool) throws -> [Transcript.Entry] {
        switch message {
        case .user(let user):
            return [.prompt(Transcript.Prompt(segments: segments(user.content, vision: vision)))]
        case .assistant(let assistant):
            // Failed and aborted attempts without content add nothing; thinking is not replayed.
            var entries: [Transcript.Entry] = []
            let text = assistant.content.compactMap(\.text).joined()
            if !text.isEmpty { entries.append(.response(Transcript.Response(segments: [.text(.init(content: text))]))) }
            let calls = try assistant.toolCalls.map { call in
                Transcript.ToolCall(
                    id: call.id, toolName: call.name, arguments: try GeneratedContent(json: JSONValue.object(call.arguments).jsonString))
            }
            if !calls.isEmpty { entries.append(.toolCalls(Transcript.ToolCalls(calls))) }
            return entries
        case .toolResult(let result):
            var segments = segments(result.content, vision: vision)
            // The model sees that a call failed, as providers with an error flag would tell it.
            if result.isError { segments.insert(.text(.init(content: "Error:")), at: 0) }
            return [.toolOutput(Transcript.ToolOutput(id: result.toolCallId, toolName: result.toolName, segments: segments))]
        default:
            return []
        }
    }

    /// Text and images; a model without vision gets a placeholder for each image.
    static func segments(_ content: [ContentBlock], vision: Bool) -> [Transcript.Segment] {
        content.compactMap { block in
            switch block {
            case .text(let text): return .text(.init(content: text))
            case .image(let image):
                guard vision, let cgImage = cgImage(image) else {
                    return .text(.init(content: "[image omitted: \(image.mimeType); this model does not take images]"))
                }
                return .attachment(.init(content: .image(.init(cgImage))))
            default: return nil
            }
        }
    }

    /// One part of a prompt: text, or an image.
    struct PromptPart: PromptRepresentable {
        let text: String
        let image: CGImage?

        var promptRepresentation: Prompt {
            if let image {
                Attachment(image)
            } else {
                text
            }
        }
    }

    static func prompt(_ message: UserMessage?, vision: Bool) -> Prompt {
        guard let message else { return Prompt("") }
        let parts = message.content.compactMap { block -> PromptPart? in
            switch block {
            case .text(let text): return PromptPart(text: text, image: nil)
            case .image(let image):
                guard vision, let cgImage = cgImage(image) else {
                    return PromptPart(text: "[image omitted: \(image.mimeType); this model does not take images]", image: nil)
                }
                return PromptPart(text: "", image: cgImage)
            default: return nil
            }
        }
        return Prompt(parts)
    }

    static func cgImage(_ image: ImageContent) -> CGImage? {
        guard let data = image.bytes, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func text(of segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment in
            if case .text(let text) = segment { return text.content }
            return nil
        }.joined()
    }
}

extension JSONValue {
    /// Parses JSON text.
    init(json: String) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }
}
#endif
