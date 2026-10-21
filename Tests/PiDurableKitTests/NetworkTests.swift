import Foundation
import Testing
import os
@testable import PiDurableKit

/// End-to-end requests through the real pi-ai provider implementations and their SDKs, served by `MockServer`.
/// These exercise `fetch()`, streaming bodies, `TextDecoder`, `ReadableStream`, and `AbortController` in JavaScriptCore.
extension MockServerTests {
@Suite struct NetworkTests {
    static let runtime = Runtime(configuration: .init(urlSessionConfiguration: MockServer.configuration))

    @Test func openAICompatibleProvider() async throws {
        MockServer.handle(host: "local.test") { _ in
            func chunk(_ delta: String, finish: String? = nil) -> String {
                let finishJSON = finish.map { "\"\($0)\"" } ?? "null"
                return .sse(
                    #"{"id":"c1","object":"chat.completion.chunk","created":1,"model":"local-model","choices":[{"index":0,"delta":{"content":"\#(delta)"},"finish_reason":\#(finishJSON)}]}"#
                )
            }
            return .init(chunks: [
                chunk("Hello"), chunk(" from"), chunk(" the server", finish: "stop"),
                .sse(#"{"id":"c1","object":"chat.completion.chunk","created":1,"model":"local-model","choices":[],"usage":{"prompt_tokens":12,"completion_tokens":4,"total_tokens":16}}"#),
                "data: [DONE]\n\n",
            ])
        }

        let models = Models(builtinProviders: false, runtime: Self.runtime)
        try await models.register(CustomProvider(
            id: "local", baseURL: URL(string: "https://local.test/v1")!, apiKey: "secret",
            models: [.init(id: "local-model")]))
        let harness = try await Harness.open(models: models)
        let root = try await harness.root(agent: AgentChange(model: ModelRef(provider: "local", modelId: "local-model")))
        let answer = try await ask(root, "Hi")
        #expect(answer.text == "Hello from the server")
        #expect(answer.usage.input == 12)

        let request = try #require(MockServer.requests(to: "local.test").last)
        #expect(request.url.path() == "/v1/chat/completions")
        #expect(request.header("Authorization") == "Bearer secret")
        #expect(request.json?["model"] == "local-model")
        #expect(request.json?["stream"] == true)
        try await harness.close()
    }

    /// Provider requests say which app they're from (`Runtime.Client`), not "pi".
    @Test func requestsCarryTheAppsUserAgent() async throws {
        MockServer.handle(host: "agent.test") { _ in
            .init(chunks: [
                .sse(#"{"id":"c1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":"stop"}]}"#),
                "data: [DONE]\n\n",
            ])
        }
        let client = Runtime.Client(name: "Example App", version: "2.1")
        let runtime = Runtime(configuration: .init(urlSessionConfiguration: MockServer.configuration, client: client))
        let models = Models(builtinProviders: false, runtime: runtime)
        try await models.register(CustomProvider(
            id: "agent", baseURL: URL(string: "https://agent.test/v1")!, apiKey: "secret", models: [.init(id: "m")]))
        let harness = try await Harness.open(models: models)
        let root = try await harness.root(agent: AgentChange(model: ModelRef(provider: "agent", modelId: "m")))
        #expect(try await ask(root, "Hi").text == "Hi")

        let request = try #require(MockServer.requests(to: "agent.test").last)
        #expect(request.header("User-Agent") == client.userAgent)
        #expect(client.userAgent.hasPrefix("Example-App/2.1 ("))
        try await harness.close()
    }

    /// A custom provider used with tokens from a sign-in made elsewhere: an expired access token is refreshed through
    /// its token URL before the request, which sends the new one.
    @Test func customProviderTokensRefresh() async throws {
        MockServer.handle(host: "tokens.test") { _ in
            .init(
                headers: ["content-type": "application/json"],
                chunks: [#"{"access_token":"fresh-access","refresh_token":"next-refresh","expires_in":3600,"token_type":"Bearer"}"#])
        }
        MockServer.handle(host: "subscription.test") { _ in
            .init(chunks: [
                .sse(#"{"id":"c1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"Refreshed"},"finish_reason":"stop"}]}"#),
                "data: [DONE]\n\n",
            ])
        }
        let models = Models(builtinProviders: false, runtime: Self.runtime)
        try await models.register(CustomProvider(
            id: "subscription", baseURL: URL(string: "https://subscription.test/v1")!,
            headers: ["x-client": "example"],
            oauth: .init(signIn: nil, tokenURL: URL(string: "https://tokens.test/oauth/token")!, clientID: "client-1", scope: "chat"),
            models: [.init(id: "m")]))
        try await models.setCredential(
            .oauth(accessToken: "stale-access", refreshToken: "first-refresh", expiresAt: .distantPast), for: "subscription")
        #expect(try await models.providers().first?.acceptsAPIKey == true)

        let harness = try await Harness.open(models: models)
        let root = try await harness.root(agent: AgentChange(model: ModelRef(provider: "subscription", modelId: "m")))
        #expect(try await ask(root, "Hi").text == "Refreshed")

        let grant = try #require(MockServer.requests(to: "tokens.test").last)
        #expect(grant.header("Content-Type") == "application/x-www-form-urlencoded")
        let form = URLComponents(string: "?" + String(decoding: grant.body, as: UTF8.self))?.queryItems ?? []
        #expect(form.first { $0.name == "grant_type" }?.value == "refresh_token")
        #expect(form.first { $0.name == "refresh_token" }?.value == "first-refresh")
        #expect(form.first { $0.name == "client_id" }?.value == "client-1")
        // The sign-in's scope carries over; it isn't sent again.
        #expect(form.first { $0.name == "scope" } == nil)

        let request = try #require(MockServer.requests(to: "subscription.test").last)
        #expect(request.header("Authorization") == "Bearer fresh-access")
        #expect(request.header("x-client") == "example")
        let stored = try #require(try await models.credential(for: "subscription"))
        #expect(stored.kind == .oauth)
        #expect(stored.json["refresh"] == "next-refresh")
        #expect((stored.expiresAt ?? .distantPast) > .now)
        try await harness.close()
    }

    /// A custom provider serving a built-in provider's models: its catalog, pointed at the custom provider's address.
    @Test func customProviderFollowsABuiltInCatalog() async throws {
        let models = Models(catalog: nil, runtime: Self.runtime)
        let builtin = try await models.models(for: .anthropic)
        #expect(!builtin.isEmpty)
        try await models.register(CustomProvider(
            id: "claude-gateway", baseURL: URL(string: "https://gateway.test")!, api: .anthropicMessages, apiKey: "secret",
            catalog: .anthropic))
        let following = try await models.models(for: "claude-gateway")
        #expect(following.map { $0.modelId } == builtin.map { $0.modelId })
        #expect(following.allSatisfy { $0.provider == "claude-gateway" && $0.baseUrl == "https://gateway.test" })
        #expect(following.first?.contextWindow == builtin.first?.contextWindow)
    }

    @Test func unregisteringAProvider() async throws {
        let models = Models(builtinProviders: false, runtime: Self.runtime)
        try await models.register(CustomProvider(
            id: "gone", baseURL: URL(string: "https://gone.test/v1")!, apiKey: "secret", models: [.init(id: "m")]))
        try await models.register(CustomProvider(
            id: "kept", baseURL: URL(string: "https://kept.test/v1")!, models: [.init(id: "m")]))
        #expect(try await models.models(for: "gone").map(\.modelId) == ["m"])

        try await models.unregister("gone")
        #expect(try await models.models(for: "gone").isEmpty)
        #expect(try await models.providers().map(\.id) == ["kept"])
        #expect(try await models.models().map(\.provider) == ["kept"])
        // The credential stays until logging out.
        #expect(try await models.credential(for: "gone")?.apiKey == "secret")
        try await models.logout(from: "gone")
        #expect(try await models.credential(for: "gone") == nil)

        let harness = try await Harness.open(models: models, settings: Settings(retry: .init(enabled: false)))
        let root = try await harness.root(agent: AgentChange(model: ModelRef(provider: "gone", modelId: "m")))
        await #expect(throws: (any Error).self) { _ = try await ask(root, "Hi") }
        try await harness.close()

        // Unregistering one that isn't there does nothing, and the same ID can be registered again.
        try await models.unregister("never")
        try await models.register(CustomProvider(
            id: "gone", baseURL: URL(string: "https://gone.test/v1")!, models: [.init(id: "again")]))
        #expect(try await models.models(for: "gone").map(\.modelId) == ["again"])
    }

    @Test func unregisteringAFauxProvider() async throws {
        let faux = FauxProvider(id: "scripted")
        let models = Models(builtinProviders: false, runtime: Self.runtime)
        try await models.register(faux)
        try await faux.append(.text("Hi"))
        try await models.unregister("scripted")
        #expect(try await models.providers().isEmpty)
        await #expect(throws: (any Error).self) { try await faux.append(.text("Again")) }
    }

    @Test func providerAndModelHeaders() async throws {
        let completion = #"{"id":"c1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":"stop"}]}"#
        MockServer.handle(host: "headers.test") { _ in .init(chunks: [.sse(completion), "data: [DONE]\n\n"]) }
        MockServer.handle(host: "anthropic.headers.test") { _ in
            .init(chunks: [
                .sse(#"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":1}}}"#, event: "message_start"),
                .sse(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#, event: "content_block_start"),
                .sse(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#, event: "content_block_delta"),
                .sse(#"{"type":"content_block_stop","index":0}"#, event: "content_block_stop"),
                .sse(#"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":1}}"#, event: "message_delta"),
                .sse(#"{"type":"message_stop"}"#, event: "message_stop"),
            ])
        }
        let models = Models(builtinProviders: false, runtime: Self.runtime)
        try await models.register(CustomProvider(
            id: "gateway", baseURL: URL(string: "https://headers.test/v1")!, apiKey: "key",
            headers: ["X-Tenant": "acme", "X-Shared": "provider"],
            models: [
                .init(id: "chat", headers: ["X-Shared": "model"], compat: ["supportsDeveloperRole": false]),
                .init(id: "claude", api: .anthropicMessages, baseURL: URL(string: "https://anthropic.headers.test")!),
            ]))
        let listed = try await models.models(for: "gateway")
        #expect(Set(listed.map(\.api)) == ["openai-completions", "anthropic-messages"])

        let harness = try await Harness.open(models: models)
        let root = try await harness.root(agent: AgentChange(model: ModelRef(provider: "gateway", modelId: "chat")))
        #expect(try await ask(root, "Hi").text == "Hi")
        let request = try #require(MockServer.requests(to: "headers.test").last)
        #expect(request.header("X-Tenant") == "acme")
        #expect(request.header("X-Shared") == "model")

        try await root.configure(AgentChange(model: ModelRef(provider: "gateway", modelId: "claude")))
        #expect(try await ask(root, "Hi again").text == "Hello")
        let anthropic = try #require(MockServer.requests(to: "anthropic.headers.test").last)
        #expect(anthropic.url.path() == "/v1/messages")
        #expect(anthropic.header("X-Tenant") == "acme")
        #expect(anthropic.header("X-Shared") == "provider")
        try await harness.close()
    }

    @Test func anthropicBuiltinProvider() async throws {
        MockServer.handle(host: "api.anthropic.com") { _ in
            .init(chunks: [
                .sse(#"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-haiku-4-5","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":1}}}"#, event: "message_start"),
                .sse(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#, event: "content_block_start"),
                .sse(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Bonjour"}}"#, event: "content_block_delta"),
                .sse(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" à tous"}}"#, event: "content_block_delta"),
                .sse(#"{"type":"content_block_stop","index":0}"#, event: "content_block_stop"),
                .sse(#"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":5}}"#, event: "message_delta"),
                .sse(#"{"type":"message_stop"}"#, event: "message_stop"),
            ])
        }

        let models = Models(credentials: InMemoryCredentialStore([.anthropic: .apiKey("sk-ant-test")]), runtime: Self.runtime)
        #expect(try await models.credential(for: .anthropic)?.apiKey == "sk-ant-test")
        #expect(try await models.models(for: .anthropic).contains { $0.modelId == "claude-haiku-4-5" })
        let harness = try await Harness.open(models: models)
        let root = try await harness.root(agent: AgentChange(model: .anthropic("claude-haiku-4-5")))
        let answer = try await ask(root, "Say hello in French")
        #expect(answer.text == "Bonjour à tous")
        #expect(answer.provider == .anthropic)

        // Login tests also talk to this host in parallel; find this test's request by its key.
        let request = try #require(MockServer.requests(to: "api.anthropic.com").first { $0.header("x-api-key") == "sk-ant-test" })
        #expect(request.url.path() == "/v1/messages")
        try await harness.close()
    }

    static func serveOpenAIResponses(text: String) {
        MockServer.handle(host: "api.openai.com") { _ in
            let item = #"{"id":"msg_1","type":"message","status":"in_progress","role":"assistant","content":[]}"#
            let done = #"{"id":"msg_1","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"\#(text)","annotations":[]}]}"#
            let response = { (status: String, output: String) in
                #"{"id":"resp_1","object":"response","created_at":1,"status":"\#(status)","model":"gpt-4.1","output":\#(output),"usage":{"input_tokens":7,"output_tokens":2,"total_tokens":9,"input_tokens_details":{"cached_tokens":0},"output_tokens_details":{"reasoning_tokens":0}}}"#
            }
            return .init(chunks: [
                .sse(#"{"type":"response.created","sequence_number":0,"response":\#(response("in_progress", "[]"))}"#, event: "response.created"),
                .sse(#"{"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":\#(item)}"#, event: "response.output_item.added"),
                .sse(#"{"type":"response.content_part.added","sequence_number":2,"item_id":"msg_1","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}"#, event: "response.content_part.added"),
                .sse(#"{"type":"response.output_text.delta","sequence_number":3,"item_id":"msg_1","output_index":0,"content_index":0,"delta":"\#(text)"}"#, event: "response.output_text.delta"),
                .sse(#"{"type":"response.output_item.done","sequence_number":5,"output_index":0,"item":\#(done)}"#, event: "response.output_item.done"),
                .sse(#"{"type":"response.completed","sequence_number":6,"response":\#(response("completed", "[" + done + "]"))}"#, event: "response.completed"),
            ])
        }
    }

    @Test func openAIResponsesBuiltinProvider() async throws {
        Self.serveOpenAIResponses(text: "Hi there")
        let models = Models(credentials: InMemoryCredentialStore([.openAI: .apiKey("sk-test")]), runtime: Self.runtime)
        let harness = try await Harness.open(models: models)
        let root = try await harness.root(agent: AgentChange(model: .openAI("gpt-4.1")))
        let answer = try await ask(root, "Hello")
        #expect(answer.text == "Hi there")
        let request = try #require(MockServer.requests(to: "api.openai.com").last)
        #expect(request.url.path() == "/v1/responses")
        #expect(request.header("Authorization") == "Bearer sk-test")
        try await harness.close()
    }

    @Test func abortingCancelsTheStreamingRequest() async throws {
        MockServer.handle(host: "slow.test") { _ in
            var chunks: [String] = []
            for index in 0..<2000 {
                chunks.append(.sse(#"{"id":"c1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"\#(index) "},"finish_reason":null}]}"#))
            }
            return .init(chunks: chunks)
        }
        let models = Models(builtinProviders: false, runtime: Self.runtime)
        try await models.register(CustomProvider(
            id: "slow", baseURL: URL(string: "https://slow.test/v1")!, models: [.init(id: "m")]))
        let harness = try await Harness.open(models: models)
        let root = try await harness.root(agent: AgentChange(model: ModelRef(provider: "slow", modelId: "m")))
        let submission = try await root.submit("Count forever")
        try await withTimeout(5) {
            for try await view in root.views() {
                if !(view.streamingMessage?.text.isEmpty ?? true) { break }
                if !view.isBusy, view.entries.count > 1 { Issue.record("Run ended early: \(view.entries.last!.text) \(String(describing: view.entries.last?.assistantMessage?.errorMessage))"); break }
            }
        }
        try await withTimeout { try await root.abort() }
        let record = try await submission.wait()
        guard case .unanswered(_, let reason, _) = record.status else {
            Issue.record("Expected unanswered, got \(record.status)")
            return
        }
        #expect(reason == "aborted")
        let aborted = try #require(try await root.view().entries.last?.assistantMessage)
        #expect(aborted.stopReason == .aborted)
        #expect(!aborted.text.isEmpty)
        try await harness.close()
    }

    @Test func httpErrorsBecomeUnansweredInputs() async throws {
        MockServer.handle(host: "broken.test") { _ in
            .init(status: 401, headers: ["content-type": "application/json"], chunks: [#"{"error":{"message":"bad key","type":"invalid_request_error"}}"#])
        }
        let models = Models(builtinProviders: false, runtime: Self.runtime)
        try await models.register(CustomProvider(
            id: "broken", baseURL: URL(string: "https://broken.test/v1")!, apiKey: "nope", models: [.init(id: "m")]))
        let harness = try await Harness.open(models: models, settings: Settings(retry: .init(enabled: false)))
        let root = try await harness.root(agent: AgentChange(model: ModelRef(provider: "broken", modelId: "m")))
        let error = await #expect(throws: Unanswered.self) {
            _ = try await ask(root, "Hi")
        }
        let status = String(describing: error?.record.status)
        #expect(status.contains("401") || status.contains("bad key"))
        try await harness.close()
    }
}
}

// Exit tests run only where Swift Testing has them (not the iOS simulator).
#if os(macOS)
/// `URLSession` keeps its delegate until it is invalidated, so `Network` can outlive its engine.
@Suite struct NetworkLifetimeTests {
    /// A response that arrives after the engine is gone is turned away, not delivered to the freed engine. In a process
    /// of its own, as delivering it traps.
    @Test func aResponseAfterTheEngineIsGone() async {
        await #expect(processExitsWith: .success) {
            try receiveAResponseAfterTheEngineIsGone()
        }
    }

    /// Data that arrives after the engine is gone cancels its request. The response was already allowed, and a body
    /// that keeps streaming never goes idle long enough to time out, so it would keep downloading with nothing reading
    /// it. No public signal says when the session has allowed a response, so the test hands the delegate the chunk
    /// itself, on the engine's queue as the session does, for a request the server holds open. In a process of its own,
    /// as delivering it traps.
    @Test func dataAfterTheEngineIsGone() async {
        await #expect(processExitsWith: .success) {
            try cancelDataAfterTheEngineIsGone()
        }
    }
}
#endif

/// Starts a request whose response `HeldResponse` holds, frees the engine, then lets the response arrive.
private func receiveAResponseAfterTheEngineIsGone() throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HeldResponse.self]
    var engine: Engine? = Engine(configuration: .init(urlSessionConfiguration: configuration))
    weak let observed = engine
    let network = Network(engine: try #require(engine), configuration: configuration)
    let queue = try #require(engine).queue
    queue.sync { network.start(id: 1, url: "https://held.test/", method: "GET", headersJSON: "[]", body: nil) }
    try #require(HeldResponse.started.wait(timeout: .now() + 10) == .success, "The request reaches the server")
    engine = nil
    try #require(observed == nil, "The engine is gone")
    HeldResponse.release.signal()
    // The body never ends, so only the delegate turning the response away (cancelling) stops the loading.
    try #require(HeldResponse.stopped.wait(timeout: .now() + 10) == .success, "The response is turned away")
}

/// Starts a request that `OpenRequest` holds open, frees the engine, then hands the delegate a chunk for the request.
private func cancelDataAfterTheEngineIsGone() throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OpenRequest.self]
    var engine: Engine? = Engine(configuration: .init(urlSessionConfiguration: configuration))
    weak let observed = engine
    let network = Network(engine: try #require(engine), configuration: configuration)
    let queue = try #require(engine).queue
    queue.sync { network.start(id: 1, url: "https://open.test/", method: "GET", headersJSON: "[]", body: nil) }
    try #require(OpenRequest.started.wait(timeout: .now() + 10) == .success, "The request reaches the server")
    let task = try #require(OpenRequest.task.withLock { $0 }, "The server sees the request's task")
    engine = nil
    try #require(observed == nil, "The engine is gone")
    queue.sync { network.urlSession(.shared, dataTask: task, didReceive: Data(String.sse("{}").utf8)) }
    try #require(OpenRequest.stopped.wait(timeout: .now() + 10) == .success, "The request is cancelled")
}

/// Serves one response, held until released, with a body that never ends; says when the client stops loading.
private final class HeldResponse: URLProtocol, @unchecked Sendable {
    static let started = DispatchSemaphore(value: 0)
    static let release = DispatchSemaphore(value: 0)
    static let stopped = DispatchSemaphore(value: 0)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.started.signal()
        _ = Self.release.wait(timeout: .now() + 10)
        let headers = ["content-type": "text/event-stream"]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(String.sse("{}").utf8))
    }

    override func stopLoading() {
        Self.stopped.signal()
    }
}

/// Holds one request open without answering it; says when the client stops loading.
private final class OpenRequest: URLProtocol, @unchecked Sendable {
    static let started = DispatchSemaphore(value: 0)
    static let stopped = DispatchSemaphore(value: 0)
    static let task = OSAllocatedUnfairLock<URLSessionDataTask?>(initialState: nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.task.withLock { $0 = task as? URLSessionDataTask }
        Self.started.signal()
    }

    override func stopLoading() {
        Self.stopped.signal()
    }
}
