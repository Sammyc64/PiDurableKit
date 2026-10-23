import Foundation
import Testing
@testable import PiDurableKit

/// A token refresh that fails during a turn (Quorum M0-90b). Its error becomes the turn's error message, a transcript
/// entry stored in the harness's file, and pi-ai's refresh errors quoted the provider's response, which can hold a token.
/// Now the message names the status, an OAuth error code or a transport failure, and no sink holds the response.
extension MockServerTests {
@Suite struct OAuthRefreshErrorTests {
    static let logs = Mutex<[String]>([])
    static let runtime = Runtime(configuration: .init(
        urlSessionConfiguration: MockServer.configuration, log: { _, line in logs.update { $0.append(line) } }))
    /// Built at run time, so no scan of the source finds it.
    static let secret = "SECRET-\(UUID().uuidString)"
    /// What a quoted response, URL or stack would leave behind.
    static let markers = [secret, "oauth/token", "url=", "stack=", "file://", "pi-durable.js"]
    static let refusal = #"{"error":"invalid_grant","error_description":"\#(secret)"}"#
    static let retries = Settings(retry: .init(maxRetries: 2, baseDelay: .milliseconds(1), maxDelay: .milliseconds(1)))

    static func json(_ text: String, status: Int = 200) -> MockServer.Response {
        .init(status: status, headers: ["content-type": "application/json"], chunks: [text])
    }

    /// A provider whose token endpoint refuses a refresh, and the message the turn ends with.
    struct Refresh: Sendable, CustomTestStringConvertible {
        let provider: ProviderID
        let host: String
        let expected: String
        var serve: @Sendable () -> Void = {}
        var testDescription: String { "\(provider.rawValue) at \(host)" }
    }

    static let refreshes: [Refresh] = [
        .init(provider: .anthropic, host: "platform.claude.com", expected: "HTTP error (400)") {
            MockServer.handle(host: "platform.claude.com") { _ in json(refusal, status: 400) }
        },
        .init(provider: .openAI, host: "auth.openai.com", expected: "HTTP error (400)") {
            MockServer.handle(host: "auth.openai.com") { _ in json(refusal, status: 400) }
        },
        .init(provider: "openai-codex", host: "auth.openai.com", expected: "HTTP error (400)") {
            MockServer.handle(host: "auth.openai.com") { _ in json(refusal, status: 400) }
        },
        .init(provider: "kimi-coding", host: "auth.kimi.com", expected: "HTTP error (401), invalid_grant") {
            MockServer.handle(host: "auth.kimi.com") { _ in json(refusal, status: 401) }
        },
        .init(provider: "github-copilot", host: "api.github.com", expected: "HTTP error (400)") {
            MockServer.handle(host: "api.github.com") { _ in json(refusal, status: 400) }
        },
        // Copilot's token comes back, and its models list refuses.
        .init(provider: "github-copilot", host: "api.individual.githubcopilot.com", expected: "HTTP error (400)") {
            let token = #"{"token":"tid=1;exp=9999999999;proxy-ep=proxy.individual.githubcopilot.com","expires_at":9999999999}"#
            MockServer.handle(host: "api.github.com") { _ in json(token) }
            MockServer.handle(host: "api.individual.githubcopilot.com") { _ in json(refusal, status: 400) }
        },
        .init(provider: "xai", host: "auth.x.ai", expected: "HTTP error (400), invalid_grant") {
            MockServer.handle(host: "auth.x.ai") { _ in json(refusal, status: 400) }
        },
        // Meta's refresh mints a new key.
        .init(provider: "meta", host: "api.meta.ai", expected: "HTTP error (400), invalid_grant") {
            MockServer.handle(host: "api.meta.ai") { _ in json(refusal, status: 400) }
        },
        .init(provider: "radius", host: "radius.pi.dev", expected: "HTTP error (400), invalid_grant") {
            MockServer.handle(host: "radius.pi.dev") { _ in json(refusal, status: 400) }
        },
        // A custom provider's OAuth, which the bridge implements.
        .init(provider: "oauth-custom", host: "token.custom.test", expected: "HTTP error (400), invalid_grant") {
            MockServer.handle(host: "token.custom.test") { _ in json(refusal, status: 400) }
        },
    ]

    @Test(arguments: refreshes)
    func refusedRefreshQuotesNothing(_ refresh: Refresh) async throws {
        refresh.serve()
        let trace = try await Self.turn(on: refresh.provider, settings: Self.retries)
        #expect(trace.message.errorMessage == "OAuth refresh failed for \(refresh.provider.rawValue): \(refresh.expected)")
        Self.expectQuotesNothing(trace)
        // A refused refresh isn't retried: a dead token stays dead.
        #expect(MockServer.requests(to: refresh.host).count - trace.requestsBefore[refresh.host, default: 0] == 1)
        #expect(!trace.events.contains { if case .autoRetryStart = $0 { true } else { false } })
    }

    /// A 200 that echoes a token but lacks a field, or isn't JSON: the response is never quoted.
    @Test func echoedTokenIsNotQuoted() async throws {
        let token = #"{"access_token":"\#(Self.secret)","expires_in":3600}"#
        let cases: [(ProviderID, String, MockServer.Response)] = [
            ("openai-codex", "auth.openai.com", Self.json(token)),
            ("kimi-coding", "auth.kimi.com", Self.json(token)),
            (.anthropic, "platform.claude.com", Self.json("\(Self.secret) isn't JSON")),
        ]
        for (provider, host, response) in cases {
            MockServer.handle(host: host) { _ in response }
            let trace = try await Self.turn(on: provider, settings: Self.retries)
            #expect(trace.message.errorMessage == "OAuth refresh failed for \(provider.rawValue): invalid token response")
            Self.expectQuotesNothing(trace)
        }
    }

    /// What pi-ai retries still reads as retryable: a 429, a 503 and a dropped connection.
    @Test func retryableRefreshFailuresAreRetried() async throws {
        let cases: [(String, MockServer.Response)] = [
            ("HTTP error (429)", Self.json(Self.refusal, status: 429)),
            ("HTTP error (503)", Self.json(Self.refusal, status: 503)),
            ("fetch failed", .init(chunks: [], failure: .networkConnectionLost)),
        ]
        for (expected, response) in cases {
            MockServer.handle(host: "auth.openai.com") { _ in response }
            let trace = try await Self.turn(on: "openai-codex", settings: Self.retries)
            #expect(trace.message.errorMessage == "OAuth refresh failed for openai-codex: \(expected)")
            #expect(trace.events.contains { if case .autoRetryStart = $0 { true } else { false } }, "\(expected)")
            #expect(MockServer.requests(to: "auth.openai.com").count - trace.requestsBefore["auth.openai.com", default: 0] > 1)
            Self.expectQuotesNothing(trace)
        }
    }

    /// A failed refresh that Swift sees, as `isConfigured` throws it.
    @Test func refreshThrownToSwiftQuotesNothing() async throws {
        MockServer.handle(host: "platform.claude.com") { _ in Self.json(Self.refusal, status: 400) }
        let models = try await Self.models(for: .anthropic)
        do {
            _ = try await models.isConfigured(.anthropic)
            Issue.record("isConfigured should throw the failed refresh")
        } catch {
            for text in [String(describing: error), String(reflecting: error), error.localizedDescription] {
                for marker in Self.markers { #expect(!text.contains(marker), "\(marker) in \(text)") }
            }
        }
    }

    // MARK: - A turn and its sinks

    struct Trace {
        let message: AssistantMessage
        let events: [AgentEvent]
        /// Every entry's JSON, the submission, the live state, the events and the log lines.
        let texts: [String]
        /// harness.sqlite and its -wal and -shm, before and after close.
        let files: [Data]
        let requestsBefore: [String: Int]
    }

    /// Signed in with an expired token, so the turn refreshes it first.
    static func models(for provider: ProviderID) async throws -> Models {
        var credential = Credential.oauth(accessToken: "stale", refreshToken: "refresh", expiresAt: .now.addingTimeInterval(-60))
        // Sign in with ChatGPT refreshes with the client ID its sign-in was issued.
        if provider == .openAI { credential.json["clientId"] = "issued-client" }
        let models = Models(credentials: InMemoryCredentialStore([provider: credential]), runtime: runtime)
        if provider == "oauth-custom" {
            try await models.register(CustomProvider(
                id: "oauth-custom", baseURL: URL(string: "https://api.custom.test/v1")!,
                oauth: .init(
                    signIn: .deviceCode(deviceAuthorizationURL: URL(string: "https://token.custom.test/device")!),
                    tokenURL: URL(string: "https://token.custom.test/token")!, clientID: "custom-client", scope: "chat"),
                models: [.init(id: "m")]))
        }
        return models
    }

    static func turn(on provider: ProviderID, settings: Settings) async throws -> Trace {
        let hosts = ["platform.claude.com", "auth.openai.com", "auth.kimi.com", "api.github.com", "auth.x.ai", "api.meta.ai",
                     "radius.pi.dev", "token.custom.test", "api.individual.githubcopilot.com"]
        let requestsBefore = Dictionary(uniqueKeysWithValues: hosts.map { ($0, MockServer.requests(to: $0).count) })
        let logged = logs.get().count
        let directory = FileManager.default.temporaryDirectory.appending(path: "m0-90b-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = try await Self.models(for: provider)
        let model = try #require(try await models.models(for: provider).first, "\(provider)")
        let harness = try await Harness.open(.sqlite(at: directory.appending(path: "harness.sqlite")), models: models, settings: settings)
        let root = try await harness.root(agent: AgentChange(model: model.ref))
        let stream = try await harness.watchEvents(root.id)
        let events = Mutex<[AgentEvent]>([])
        let watch = Task { for try await batch in stream { events.update { $0 += batch } } }
        let submission = try await root.submit("Hi").wait()
        let view = try await root.view()
        try await withTimeout(10) {
            while !events.get().contains(where: { if case .runEnd = $0 { true } else { false } }) {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        watch.cancel()
        let files = { try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).map { try Data(contentsOf: $0) } }
        let open = try files()
        try await harness.close()
        let message = try #require(view.entries.compactMap(\.assistantMessage).last, "\(provider)")
        let encoder = JSONEncoder()
        let texts = try view.entries.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
            + [String(decoding: try encoder.encode(submission), as: UTF8.self), String(reflecting: view.live)]
            + events.get().map { String(reflecting: $0) } + Array(logs.get().dropFirst(logged))
        return Trace(message: message, events: events.get(), texts: texts, files: open + (try files()), requestsBefore: requestsBefore)
    }

    static func expectQuotesNothing(_ trace: Trace) {
        for marker in markers {
            for text in trace.texts where text.contains(marker) { Issue.record("\(marker) in \(text.prefix(300))") }
            #expect(trace.files.allSatisfy { $0.range(of: Data(marker.utf8)) == nil }, "\(marker) in the harness's files")
        }
        #expect(!trace.files.isEmpty)
    }
}
}
