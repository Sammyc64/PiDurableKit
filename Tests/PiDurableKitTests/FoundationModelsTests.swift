#if canImport(FoundationModels)
import Foundation
import FoundationModels
import Testing
@testable import PiDurableKit

/// Whether Apple's on-device model can answer here (Apple Intelligence enabled, model downloaded).
let onDeviceModelAvailable: Bool = {
    if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) { return SystemLanguageModel.default.isAvailable }
    return false
}()

/// Whether Private Cloud Compute can answer here: it needs an app with Apple's Private Cloud Compute entitlement, so
/// set `PIDURABLEKIT_TEST_PCC=1` when running the tests from such an app.
let privateCloudComputeAvailable: Bool = {
    guard ProcessInfo.processInfo.environment["PIDURABLEKIT_TEST_PCC"] == "1" else { return false }
    if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) { return PrivateCloudComputeLanguageModel().isAvailable }
    return false
}()

private struct City: Codable, Sendable { var city: String }

/// The Foundation Models provider against the real on-device model.
@Suite(.enabled(if: onDeviceModelAvailable, "Needs Apple's on-device model"), .serialized)
struct FoundationModelsTests {
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    func setup(extensions: [Extension] = []) async throws -> (Harness, Conversation) {
        let models = Models(builtinProviders: false)
        try await models.register(FoundationModelsProvider())
        let harness = try await Harness.open(
            models: models, extensions: extensions, settings: Settings(compaction: .forContextWindow(8192)))
        let root = try await harness.root(agent: AgentChange(model: .appleOnDevice))
        return (harness, root)
    }

    @Test func registersTheModels() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let models = Models(builtinProviders: false)
        try await models.register(FoundationModelsProvider())
        let catalog = try await models.models(for: .apple)
        #expect(catalog.map(\.modelId) == ["on-device", "private-cloud-compute"])
        #expect(catalog.first?.contextWindow == SystemLanguageModel.default.contextSize)
        #expect(try await models.isConfigured(.apple))
    }

    @Test func answersAndStreams() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let (harness, root) = try await setup()
        let events = try await harness.watchEvents(root.id)
        let deltas = Mutex(0)
        let collector = Task {
            for try await batch in events {
                for case .messageUpdate(let changes, _) in batch {
                    deltas.update { $0 += changes.count }
                }
            }
        }
        let answer = try await withTimeout(60) {
            try await ask(root, "Write a short paragraph about pineapples, about 80 words long.")
        }
        collector.cancel()
        #expect(answer.text.lowercased().contains("pineapple"))
        #expect(answer.provider == .apple)
        #expect(answer.usage.output > 0)
        #expect(deltas.get() > 0)
        try await harness.close()
    }

    @Test func toolCallsRunInPiDurable() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let calls = Mutex<[String]>([])
        let weather = Tool(
            "get_weather", description: "Get the current weather for a city", parameters: .object(["city": .string("The city")])
        ) { (args: City, _) in
            calls.update { $0.append(args.city) }
            return "It is 31 degrees and sunny in \(args.city)."
        }
        let (harness, root) = try await setup(extensions: [Extension("weather", tools: [weather])])
        let answer = try await withTimeout(90) {
            try await ask(root, "What is the weather in Paris right now? Use the get_weather tool, then tell me the temperature.")
        }
        #expect(calls.get().contains { $0.localizedCaseInsensitiveContains("paris") })
        let entries = try await root.view().entries
        #expect(entries.contains { $0.kind == .toolResult })
        #expect(answer.text.contains("31"))
        try await harness.close()
    }

    @Test func continuesTheConversation() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let (harness, root) = try await setup()
        _ = try await withTimeout(60) { try await ask(root, "My favorite color is teal. Just say OK.") }
        let answer = try await withTimeout(60) { try await ask(root, "What is my favorite color? Answer in one word.") }
        #expect(answer.text.lowercased().contains("teal"))
        try await harness.close()
    }

    @Test func imagesReachTheModel() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        guard SystemLanguageModel.default.capabilities.contains(.vision) else { return }
        let (harness, root) = try await setup()
        let red = try SessionEndingTests.png(width: 64, height: 64, red: true)
        let submission = try await root.submit([
            .text("What single color fills this image? Answer with one word."),
            .image(ImageContent(data: red, mimeType: "image/png")),
        ])
        let answer = try await withTimeout(60) { try await PiDurableKitTests.answer(of: submission) }
        #expect(answer.text.lowercased().contains("red"))
        try await harness.close()
    }

    @Test(.enabled(if: privateCloudComputeAvailable, "Needs Private Cloud Compute"))
    func privateCloudCompute() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let models = Models(builtinProviders: false)
        try await models.register(FoundationModelsProvider())
        let harness = try await Harness.open(models: models)
        let root = try await harness.root(agent: AgentChange(model: .applePrivateCloudCompute, thinkingLevel: .low))
        let answer = try await withTimeout(120) { try await ask(root, "What is 17 times 23? Answer with just the number.") }
        #expect(answer.text.contains("391"))
        #expect(answer.model == "private-cloud-compute")
        try await harness.close()
    }

    @Test func overflowsReadAsContextOverflows() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let message = FoundationModelsResponder.message(
            for: LanguageModelError.contextSizeExceeded(.init(contextSize: 8192, tokenCount: 9000, debugDescription: "too long")))
        #expect(message.contains("exceeds the context window"))
        let (harness, root) = try await setup()
        let long = (1...1500).map { "Note \($0): the library opens at \($0 % 12 + 1) o'clock on day \($0 % 7 + 1)." }
            .joined(separator: " ")
        let settled = try await withTimeout(120) { try await root.submit(long).wait() }
        guard case .unanswered(_, _, let detail) = settled.status else {
            Issue.record("Expected an unanswered input, got \(settled.status)")
            return
        }
        #expect(detail?.stringValue?.contains("context window") == true, "\(String(describing: detail))")
        try await harness.close()
    }

    @Test func builtinToolSchemasDecode() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let models = Models(builtinProviders: false)
        let harness = try await Harness.open(
            models: models, extensions: [.codingTools(shell: true), .toolSearch(), .codemode()])
        // Every tool the model can be offered; code mode's internal tools are only for scripts.
        for tool in try await harness.registry().tools.map(\.tool) where tool.callers.contains(.model) {
            _ = try FoundationModelsResponder.tool(["name": .string(tool.name), "description": .string(tool.description), "parameters": tool.parameters])
        }
        try await harness.close()
    }

    @Test func schemasDecode() throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        let tool = try FoundationModelsResponder.tool([
            "name": "pick", "description": "Pick one",
            "parameters": [
                "type": "object", "x-order": ["value", "mode"],
                "properties": [
                    "value": ["title": "Value", "anyOf": [["type": "string"], ["type": "number"]]],
                    "mode": ["type": "string", "enum": ["a", "b"]],
                ],
                "required": ["value"],
            ],
        ])
        #expect(tool.name == "pick")
    }
}
#endif
