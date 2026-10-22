import Foundation
import Testing
@testable import PiDurableKit

/// pi-ai's sign-in and refresh errors never quote an OAuth response, which can hold an access token or a device code
/// (Quorum M0-90b). A failed refresh lands in the conversation's durable transcript; a failed sign-in reaches the app.
extension MockServerTests {
@Suite struct OAuthErrorTextTests {
    static let runtime = Runtime(configuration: .init(urlSessionConfiguration: MockServer.configuration))
    /// Built at run time, so no scan of the source finds it.
    static let secret = ["SECRET", "OAUTH", String(Int.random(in: 100_000...999_999))].joined(separator: "-")

    static func json(_ text: String, status: Int = 200) -> MockServer.Response {
        .init(status: status, headers: ["content-type": "application/json"], chunks: [text])
    }

    /// A device-code sign-in: picks the device code where there's a choice, and waits on its page until it ends.
    static let deviceCode = LoginInteraction(
        presentSignInPage: { _ in while !Task.isCancelled { try await Task.sleep(for: .milliseconds(20)) } },
        prompt: { prompt in
            if case .select(_, let options) = prompt, let device = options.first(where: { $0.id == "device_code" }) {
                return device.id
            }
            return try await prompt.defaultAnswer()
        })

    @Test func failedRefreshQuotesNoResponse() async throws {
        let refusal = #"{"error":"invalid_grant","error_description":"\#(Self.secret)"}"#
        let cases: [(ProviderID, String, Int)] = [
            (.anthropic, "platform.claude.com", 400), ("kimi-coding", "auth.kimi.com", 401),
            ("openai-codex", "auth.openai.com", 400)
        ]
        for (provider, host, status) in cases {
            MockServer.handle(host: host) { _ in Self.json(refusal, status: status) }
            let store = InMemoryCredentialStore([
                provider: .oauth(accessToken: "stale", refreshToken: "refresh", expiresAt: .now.addingTimeInterval(-60))
            ])
            let models = Models(credentials: store, runtime: Self.runtime)
            let model = try #require(try await models.models(for: provider).first)
            let harness = try await Harness.open(
                models: models, settings: Settings(retry: .init(maxRetries: 0, baseDelay: .zero, maxDelay: .zero)))
            let root = try await harness.root(agent: AgentChange(model: model.ref))
            _ = try await root.submit("Hi").wait()
            let message = try #require(try await root.view().entries.compactMap(\.assistantMessage).last)
            try await harness.close()

            #expect(MockServer.requests(to: host).count > 0, "\(provider): it refreshed")
            #expect(message.errorMessage == "OAuth refresh failed for \(provider.rawValue)")
            #expect(!String(reflecting: message).contains(Self.secret), "\(provider)")
        }
    }

    @Test func kimiChecksNameTheirFields() async throws {
        let invalid = #"{"device_code":"\#(Self.secret)","user_code":"CODE","verification_uri":"not a page"}"#
        MockServer.handle(host: "auth.kimi.com") { _ in Self.json(invalid) }
        try await Self.expectNaming(["verification_uri", "verification_uri_complete"], signingIn: "kimi-coding")

        // A token poll that answers with an access token but no refresh token, as RFC 6749 §6 lets a refresh do.
        let device = #"""
            {"device_code":"dev","user_code":"CODE","verification_uri":"https://auth.kimi.com/device",
            "verification_uri_complete":"https://auth.kimi.com/device?code=CODE","interval":1,"expires_in":60}
            """#
        let token = #"{"access_token":"\#(Self.secret)","expires_in":3600}"#
        MockServer.handle(host: "auth.kimi.com") { request in
            request.url.path().hasSuffix("/device_authorization") ? Self.json(device) : Self.json(token)
        }
        try await Self.expectNaming(["refresh_token"], signingIn: "kimi-coding")
    }

    @Test func metaChecksNameTheirFields() async throws {
        let invalid = #"{"device_code":"\#(Self.secret)","user_code":"CODE","verification_uri":"not a page"}"#
        MockServer.handle(host: "auth.meta.com") { _ in Self.json(invalid) }
        try await Self.expectNaming(["verification_uri"], signingIn: "meta")
    }

    @Test func codexChecksNameTheirFields() async throws {
        let device = #"{"device_auth_id":"device","user_code":"CODE","interval":0}"#
        let grant = #"{"authorization_code":"code","code_verifier":"verifier"}"#
        let invalidDevice = #"{"device_auth_id":"\#(Self.secret)","user_code":"CODE"}"#
        MockServer.handle(host: "auth.openai.com") { _ in Self.json(invalidDevice) }
        try await Self.expectNaming(["interval"], signingIn: "openai-codex")

        let invalidGrant = #"{"authorization_code":"\#(Self.secret)"}"#
        MockServer.handle(host: "auth.openai.com") { request in
            request.url.path().hasSuffix("/usercode") ? Self.json(device) : Self.json(invalidGrant)
        }
        try await Self.expectNaming(["code_verifier"], signingIn: "openai-codex")

        let token = #"{"access_token":"\#(Self.secret)","expires_in":3600}"#
        MockServer.handle(host: "auth.openai.com") { request in
            let path = request.url.path()
            if path.hasSuffix("/usercode") { return Self.json(device) }
            return path.hasSuffix("/deviceauth/token") ? Self.json(grant) : Self.json(token)
        }
        try await Self.expectNaming(["refresh_token"], signingIn: "openai-codex")
    }

    /// Signs in to `provider` with the device code and expects it to fail with an error that names `fields` and quotes
    /// none of the response.
    static func expectNaming(_ fields: [String], signingIn provider: ProviderID) async throws {
        let models = Models(credentials: InMemoryCredentialStore(), runtime: runtime)
        do {
            try await withTimeout(20) { try await models.login(to: provider, interaction: deviceCode) }
            Issue.record("\(provider): the sign-in should fail")
        } catch {
            let text = String(reflecting: error)
            #expect(!text.contains(secret), "\(provider): the error quotes the response")
            for field in fields { #expect(text.contains(field), "\(provider): the error names \(field)") }
        }
    }
}
}
