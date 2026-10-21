import Foundation
import Testing
@testable import PiDurableKit

/// Classifier providers: a ``CustomProvider``'s classifier models answer ``Models/classify(_:context:)`` through pi-ai's
/// TypeSafe System One API, here served by `MockServer`.
extension MockServerTests {
@Suite struct ClassifierTests {
    static let runtime = Runtime(configuration: .init(urlSessionConfiguration: MockServer.configuration))
    static let model = ModelRef(provider: "clef", modelId: "clef-1")
    static let context = ClassifierContext(
        state: ["text": "Your invoice is overdue"],
        questions: [
            "spam": .bool(instructions: "Is this message spam?", whenTrue: "Unsolicited bulk mail", whenFalse: "Anything else"),
            "topic": .choice(
                instructions: "What is it about?", labels: ["billing": "Payments and invoices", "support": "Help with the product"]),
            "urgency": .score(instructions: "How urgent is it?", levels: ["Whenever", "This week", "Today"]),
        ])

    /// A System One service: answers each question of a request (a `bool` question arrives as System One's `noul`),
    /// except `skipped`, and reports the tokens used.
    static func serveSystemOne(host: String, skipping skipped: String? = nil) {
        MockServer.handle(host: host) { request in
            var answers: JSONObject = [:]
            for (id, question) in request.json?["questions"]?.objectValue ?? [:] where id != skipped {
                switch question["type"]?.stringValue {
                case "noul": answers[id] = ["type": "noul", "noul": 0.9]
                case "choice":
                    answers[id] = ["type": "choice", "choice": "billing", "probabilities": ["billing": 0.7, "support": 0.3], "confidence": 0.8]
                case "score": answers[id] = ["type": "score", "score": 2, "confidence": 0.6]
                default: break
                }
            }
            let body: JSONValue = ["answers": .object(answers), "usage": ["input_tokens": 12, "output_tokens": 3]]
            return .init(headers: ["content-type": "application/json"], chunks: [body.jsonString])
        }
    }

    /// Models with a keyless classifier service at `host`, which also serves a chat model.
    static func clef(host: String, api: CustomProvider.API = .typesafeSystemOne) async throws -> Models {
        let models = Models(builtinProviders: false, runtime: runtime)
        try await models.register(CustomProvider(
            id: "clef", baseURL: URL(string: "https://\(host)/v1")!,
            models: [.init(id: "clef-1", type: .classifier, api: api), .init(id: "chat-1")]))
        return models
    }

    @Test func aClassifierProviderClassifies() async throws {
        Self.serveSystemOne(host: "clef.test")
        let models = try await Self.clef(host: "clef.test")

        // Listings are of chat models unless they ask for classifiers.
        let chat = try await models.models(for: "clef")
        #expect(chat.map(\.modelId) == ["chat-1"])
        #expect(chat.map(\.type) == [.chat])
        let classifiers = try await models.models(for: "clef", type: .classifier)
        #expect(classifiers.map(\.modelId) == ["clef-1"])
        #expect(classifiers.map(\.type) == [.classifier])
        #expect(classifiers.map(\.api) == ["typesafe-system-one"])

        let result = try await models.classify(Self.model, context: Self.context)
        #expect(result.provider == "clef")
        #expect(result.model == "clef-1")
        #expect(result.answers["spam"] == .bool(probability: 0.9))
        #expect(result.answers["topic"] == .choice("billing", probabilities: ["billing": 0.7, "support": 0.3], confidence: 0.8))
        #expect(result.answers["urgency"] == .score(2, confidence: 0.6))
        #expect(result.usage?.input == 12)
        #expect(result.usage?.output == 3)

        let request = try #require(MockServer.requests(to: "clef.test").last)
        #expect(request.method == "POST")
        #expect(request.url.path() == "/v1/systemone")
        // A keyless service gets the placeholder key the chat APIs get: System One refuses to send without one.
        #expect(request.header("Authorization") == "Bearer unused")
        #expect(request.json?["model"] == "clef-1")
        #expect(request.json?["state"] == ["text": "Your invoice is overdue"])
        #expect(request.json?["questions"] == [
            "spam": ["type": "noul", "instructions": "Is this message spam?", "criteria": ["true": "Unsolicited bulk mail", "false": "Anything else"]],
            "topic": [
                "type": "choice", "instructions": "What is it about?",
                "criteria": ["billing": "Payments and invoices", "support": "Help with the product"],
            ],
            "urgency": ["type": "score", "instructions": "How urgent is it?", "criteria": ["Whenever", "This week", "Today"]],
        ])
    }

    @Test func anErrorResponseThrows() async throws {
        MockServer.handle(host: "rejecting.clef.test") { _ in
            .init(status: 400, headers: ["content-type": "application/json"], chunks: [#"{"error":"questions must not be empty"}"#])
        }
        let models = try await Self.clef(host: "rejecting.clef.test")
        let error = await #expect(throws: ClassifierError.self) {
            _ = try await models.classify(Self.model, context: Self.context)
        }
        guard case .failed(let message, let usage)? = error else {
            Issue.record("Expected a failure, got \(String(describing: error))")
            return
        }
        #expect(message.contains("400"), "\(message)")
        #expect(usage == nil)
    }

    /// Answers that don't parse fail the classification, which still reports the tokens the service billed.
    @Test func anUnansweredQuestionThrowsWithItsUsage() async throws {
        Self.serveSystemOne(host: "partial.clef.test", skipping: "topic")
        let models = try await Self.clef(host: "partial.clef.test")
        let error = await #expect(throws: ClassifierError.self) {
            _ = try await models.classify(Self.model, context: Self.context)
        }
        guard case .failed(let message, let usage)? = error else {
            Issue.record("Expected a failure, got \(String(describing: error))")
            return
        }
        #expect(message.contains("topic"), "\(message)")
        #expect(usage?.input == 12)
    }

    @Test func cancellingAClassificationAborts() async throws {
        // An answer that trickles in for seconds.
        MockServer.handle(host: "slow.clef.test") { _ in
            .init(headers: ["content-type": "application/json"], chunks: Array(repeating: " ", count: 1000) + [#"{"answers":{}}"#])
        }
        let models = try await Self.clef(host: "slow.clef.test")
        let classification = Task { try await models.classify(Self.model, context: Self.context) }
        try await withTimeout {
            while MockServer.requests(to: "slow.clef.test").isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        }
        classification.cancel()
        let outcome = try await withTimeout { await classification.result }
        guard case .failure(ClassifierError.aborted) = outcome else {
            Issue.record("Expected an abort, got \(outcome)")
            return
        }
    }

    @Test func anUnsupportedClassifierAPIIsRefused() async throws {
        let error = await #expect(throws: PiDurableError.self) {
            _ = try await Self.clef(host: "unsupported.clef.test", api: "made-up-classifier")
        }
        #expect(String(describing: error).contains(#"Unsupported classifier API "made-up-classifier""#))
    }

    @Test func classifyingNeedsAClassifierModel() async throws {
        let models = try await Self.clef(host: "clef.test")
        let error = await #expect(throws: PiDurableError.self) {
            _ = try await models.classify(ModelRef(provider: "clef", modelId: "chat-1"), context: Self.context)
        }
        guard case .notFound? = error else {
            Issue.record("Expected notFound, got \(String(describing: error))")
            return
        }
    }

    /// A custom provider following a built-in catalog classifies with the catalog's System One classifiers, pointed at
    /// it, and lists none it has no classifier API for (OpenAI's use its Decisions API).
    @Test func aProviderFollowingACatalogClassifies() async throws {
        Self.serveSystemOne(host: "gateway.clef.test")
        let models = Models(catalog: nil, runtime: Self.runtime)
        try await models.register(CustomProvider(
            id: "gateway", baseURL: URL(string: "https://gateway.clef.test/v1")!, catalog: .openRouter))
        let classifiers = try await models.models(for: "gateway", type: .classifier)
        let classifier = try #require(classifiers.first)
        #expect(classifiers.allSatisfy { $0.api == "typesafe-system-one" && $0.baseUrl == "https://gateway.clef.test/v1" })

        let result = try await models.classify(classifier.ref, context: Self.context)
        #expect(result.answers["spam"] == .bool(probability: 0.9))
        let request = try #require(MockServer.requests(to: "gateway.clef.test").last)
        #expect(request.url.path() == "/v1/systemone")
        #expect(request.json?["model"] == .string(classifier.modelId))

        // The catalog has classifiers to leave out.
        #expect(try await models.models(for: .openAI, type: .classifier).isEmpty == false)
        try await models.register(CustomProvider(
            id: "decisions-gateway", baseURL: URL(string: "https://decisions.gateway.clef.test/v1")!, catalog: .openAI))
        #expect(try await models.models(for: "decisions-gateway").isEmpty == false)
        #expect(try await models.models(for: "decisions-gateway", type: .classifier).isEmpty)
    }

    /// Code mode's `models.classify()` resolves the model by provider and ID, and classifies with the harness's models.
    @Test func codeModeScriptsClassify() async throws {
        Self.serveSystemOne(host: "codemode.clef.test")
        let setup = try await FauxSetup.make(extensions: [.codemode()], runtime: Self.runtime)
        try await setup.models.register(CustomProvider(
            id: "clef", baseURL: URL(string: "https://codemode.clef.test/v1")!, api: .typesafeSystemOne,
            models: [.init(id: "clef-1", type: .classifier)]))
        let script = """
            const model = await models.getModelOfType("classifier", "clef", "clef-1");
            const result = await models.classify(model, {
              state: { text: "Win a prize" },
              questions: { spam: { type: "bool", instructions: "Is this spam?", criteria: { true: "Spam", false: "Not spam" } } },
            });
            return `${result.stopReason} ${result.answers.spam.type} ${result.answers.spam.probability}`;
            """
        try await setup.faux.append(.toolCall("codemode", ["code": .string(script)]))
        try await setup.faux.append(.text("done"))
        let root = try await setup.root()
        _ = try await withTimeout(30) { try await ask(root, "Classify") }
        let result = try #require(try await root.view().entries.compactMap(\.toolResult).first)
        #expect(result.isError == false, "\(result.text)")
        #expect(result.text.contains("stop bool 0.9"), "\(result.text)")
        #expect(MockServer.requests(to: "codemode.clef.test").last?.json?["questions"]?["spam"]?["type"] == "noul")
        try await setup.harness.close()
    }
}
}
