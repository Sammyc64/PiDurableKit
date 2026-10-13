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
/// a model's availability (`SystemLanguageModel.default.availability`) before offering it. Small context windows want
/// smaller compaction thresholds: see ``Settings/Compaction/forContextWindow(_:)``.
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
        let messages = try (request["messages"] ?? []).decode(as: [Message].self)
        // A tool whose schema Foundation Models cannot express, such as one with untyped properties, is not offered.
        let tools = (request["tools"]?.arrayValue ?? []).compactMap { try? Self.tool($0) }
        let options = request["options"] ?? [:]

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
        for message in history { entries += try Self.entries(for: message) }
        // The on-device model counts tokens locally: an overflow is reported before the request, in the same words on
        // every platform, so pi-durable compacts and retries.
        if let system = model as? SystemLanguageModel {
            let counted = entries + [.prompt(Transcript.Prompt(segments: try Self.segments(prompt?.content ?? [])))]
            if let tokens = try? await system.tokenCount(for: counted), tokens > system.contextSize {
                return Self.answer(
                    stopReason: "error", usage: LanguageModelSession.Usage(input: .init(totalTokenCount: 0, cachedTokenCount: 0), output: .init(totalTokenCount: 0, reasoningTokenCount: 0)),
                    error: "Input of \(tokens) tokens exceeds the context window of \(system.contextSize) tokens")
            }
        }
        let session = LanguageModelSession(model: model, tools: tools, transcript: Transcript(entries: entries))
        session.transcriptErrorHandlingPolicy = .preserveTranscript
        let start = session.transcript.count

        var generation = GenerationOptions(
            samplingMode: nil, temperature: options["temperature"]?.doubleValue,
            maximumResponseTokens: options["maxTokens"]?.intValue, toolCallingMode: Self.toolCallingMode(options["toolChoice"]))
        if tools.isEmpty { generation.toolCallingMode = nil }
        let context = ContextOptions(
            reasoningLevel: model.capabilities.contains(.reasoning) ? Self.reasoningLevel(options["reasoning"]?.stringValue) : nil)

        var text = ""
        var thinking = ""
        var usage: LanguageModelSession.Usage?
        do {
            let stream = session.streamResponse(
                to: try Self.prompt(prompt), options: generation, contextOptions: context, metadata: [:])
            for try await snapshot in stream {
                usage = snapshot.usage
                let reasoning = snapshot.transcriptEntries.compactMap { entry -> String? in
                    if case .reasoning(let reasoning) = entry { return Self.text(of: reasoning.segments) }
                    return nil
                }.joined(separator: "\n")
                if reasoning.count > thinking.count, reasoning.hasPrefix(thinking) {
                    emit(["type": "thinking", "delta": .string(String(reasoning.dropFirst(thinking.count)))])
                    thinking = reasoning
                }
                let content = snapshot.content
                if content.count > text.count, content.hasPrefix(text) {
                    emit(["type": "text", "delta": .string(String(content.dropFirst(text.count)))])
                    text = content
                }
            }
            return Self.answer(stopReason: "stop", usage: usage ?? session.usage)
        } catch let error as LanguageModelSession.ToolCallError where error.underlyingError is ToolCallsRequested {
            let calls = session.transcript.dropFirst(start).compactMap { entry -> Transcript.ToolCalls? in
                if case .toolCalls(let calls) = entry { return calls }
                return nil
            }.last
            let toolCalls: [JSONValue] = try (calls.map(Array.init) ?? []).map { call in
                [
                    "id": .string(call.id), "name": .string(call.toolName),
                    "arguments": try JSONValue(json: call.arguments.jsonString),
                ]
            }
            return Self.answer(stopReason: "toolUse", usage: session.usage, toolCalls: toolCalls)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return Self.answer(stopReason: "error", usage: usage ?? session.usage, error: Self.message(for: error))
        }
    }

    static func answer(
        stopReason: String, usage: LanguageModelSession.Usage, toolCalls: [JSONValue] = [], error: String? = nil
    ) -> JSONValue {
        var answer: JSONObject = [
            "stopReason": .string(stopReason),
            "toolCalls": .array(toolCalls),
            "usage": [
                "input": .number(Double(usage.input.totalTokenCount)),
                "cachedInput": .number(Double(usage.input.cachedTokenCount)),
                "output": .number(Double(usage.output.totalTokenCount)),
                "reasoning": .number(Double(usage.output.reasoningTokenCount)),
            ],
        ]
        if let error { answer["errorMessage"] = .string(error) }
        return .object(answer)
    }

    /// Error text pi-ai classifies: a context overflow in the words it recognizes, so pi-durable compacts and retries.
    static func message(for error: Error) -> String {
        if case .contextSizeExceeded(let exceeded)? = error as? LanguageModelError {
            return "Input of \(exceeded.tokenCount) tokens exceeds the context window of \(exceeded.contextSize) tokens"
        }
        if case .exceededContextWindowSize? = error as? LanguageModelSession.GenerationError {
            return "The input exceeds the context window. \(error.localizedDescription)"
        }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
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

    static func entries(for message: Message) throws -> [Transcript.Entry] {
        switch message {
        case .user(let user):
            return [.prompt(Transcript.Prompt(segments: try segments(user.content)))]
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
            return [.toolOutput(Transcript.ToolOutput(id: result.toolCallId, toolName: result.toolName, segments: try segments(result.content)))]
        default:
            return []
        }
    }

    static func segments(_ content: [ContentBlock]) throws -> [Transcript.Segment] {
        content.compactMap { block in
            switch block {
            case .text(let text): return .text(.init(content: text))
            case .image(let image):
                guard let cgImage = cgImage(image) else { return .text(.init(content: "[image: \(image.mimeType)]")) }
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

    static func prompt(_ message: UserMessage?) throws -> Prompt {
        guard let message else { return Prompt("") }
        let parts = message.content.compactMap { block -> PromptPart? in
            switch block {
            case .text(let text): return PromptPart(text: text, image: nil)
            case .image(let image): return cgImage(image).map { PromptPart(text: "", image: $0) }
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
