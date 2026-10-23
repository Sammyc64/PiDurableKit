import Foundation
import Testing
@testable import PiDurableKit

/// pi-ai's sign-in errors never quote an OAuth response, which can hold an access token or a device code, and a
/// provider error's diagnostic keeps no stack (Quorum M0-90b). A failed sign-in's error reaches the app.
extension MockServerTests {
@Suite struct OAuthErrorTextTests {
    static let runtime = Runtime(configuration: .init(urlSessionConfiguration: MockServer.configuration))
    /// Built at run time, so no scan of the source finds it.
    static let secret = "SECRET-\(UUID().uuidString)"
    static let refusal = json(#"{"error":"invalid_request","error_description":"\#(secret)","message":"\#(secret)"}"#, status: 400)

    static func json(_ text: String, status: Int = 200) -> MockServer.Response {
        .init(status: status, headers: ["content-type": "application/json"], chunks: [text])
    }

    /// A device-code sign-in: picks the device code where there's a choice, and waits on its page until it ends.
    static let deviceCode = LoginInteraction(
        presentSignInPage: { _ in while !Task.isCancelled { try await Task.sleep(for: .milliseconds(20)) } },
        prompt: { prompt in
            if case .select(_, let options) = prompt, let device = options.first(where: { $0.id.contains("device") }) {
                return device.id
            }
            return try await prompt.defaultAnswer()
        })

    @Test func kimiChecksNameTheirFields() async throws {
        let invalid = #"{"device_code":"\#(Self.secret)","user_code":"CODE","verification_uri":"not a page"}"#
        MockServer.handle(host: "auth.kimi.com") { _ in Self.json(invalid) }
        try await Self.expectNaming(["verification_uri", "verification_uri_complete"], signingIn: "kimi-coding")

        // A token poll that answers with an access token but no refresh token, as RFC 6749 §6 lets a refresh do.
        let token = #"{"access_token":"\#(Self.secret)","expires_in":3600}"#
        MockServer.handle(host: "auth.kimi.com") { request in
            request.url.path().hasSuffix("/device_authorization") ? Self.json(Self.kimiDevice) : Self.json(token)
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

    /// A refused sign-in request says its status and at most an OAuth error code: never the response, its URL or a
    /// stack.
    @Test func refusedSignInRequestsSayOnlyTheirStatus() async throws {
        // Anthropic's token exchange, refused, and answered with something that isn't JSON.
        MockServer.handle(host: "platform.claude.com") { _ in Self.refusal }
        try await Self.expectNoSecret(signingIn: .anthropic, interaction: LoginTests.browser(code: "code"))
        MockServer.handle(host: "platform.claude.com") { _ in Self.json("\(Self.secret) isn't JSON") }
        try await Self.expectNoSecret(signingIn: .anthropic, interaction: LoginTests.browser(code: "code"))
        // Sign in with ChatGPT's token request.
        MockServer.handle(host: "auth.openai.com") { _ in Self.refusal }
        try await Self.expectNoSecret(signingIn: .openAI, interaction: LoginTests.browser(code: "code"))
        // OpenAI Codex: its device code request, its device authorization, and its token request.
        try await Self.expectNoSecret(signingIn: "openai-codex")
        let device = #"{"device_auth_id":"device","user_code":"CODE","interval":0}"#
        MockServer.handle(host: "auth.openai.com") { request in
            request.url.path().hasSuffix("/usercode") ? Self.json(device) : Self.refusal
        }
        try await Self.expectNoSecret(signingIn: "openai-codex")
        let grant = #"{"authorization_code":"code","code_verifier":"verifier"}"#
        MockServer.handle(host: "auth.openai.com") { request in
            let path = request.url.path()
            if path.hasSuffix("/usercode") { return Self.json(device) }
            return path.hasSuffix("/deviceauth/token") ? Self.json(grant) : Self.refusal
        }
        try await Self.expectNoSecret(signingIn: "openai-codex")
        // Kimi Code: its device authorization, and its token poll refused and failing.
        MockServer.handle(host: "auth.kimi.com") { _ in Self.refusal }
        try await Self.expectNoSecret(signingIn: "kimi-coding")
        for poll in [Self.refusal, Self.json(Self.secret, status: 500)] {
            MockServer.handle(host: "auth.kimi.com") { request in
                request.url.path().hasSuffix("/device_authorization") ? Self.json(Self.kimiDevice) : poll
            }
            try await Self.expectNoSecret(signingIn: "kimi-coding")
        }
        // GitHub Copilot: its device code request, and its poll failing with a description.
        MockServer.handle(host: "github.com") { _ in Self.refusal }
        try await Self.expectNoSecret(signingIn: "github-copilot")
        let copilotDevice = #"{"device_code":"dev","user_code":"CODE","verification_uri":"https://github.com/login/device","interval":0,"expires_in":60}"#
        MockServer.handle(host: "github.com") { request in
            request.url.path().hasSuffix("/device/code")
                ? Self.json(copilotDevice) : Self.json(#"{"error":"bad_verification_code","error_description":"\#(Self.secret)"}"#)
        }
        try await Self.expectNoSecret(signingIn: "github-copilot")
        // xAI's device authorization; Radius's device authorization, answered with something that isn't JSON.
        MockServer.handle(host: "auth.x.ai") { _ in Self.refusal }
        try await Self.expectNoSecret(signingIn: "xai")
        MockServer.handle(host: "radius.pi.dev") { _ in Self.json("\(Self.secret) isn't JSON", status: 400) }
        try await Self.expectNoSecret(signingIn: "radius")
        // A sign-in page that returns an error with a description, for a provider and for Sign in with ChatGPT.
        let returned = [URLQueryItem(name: "error", value: Self.secret), URLQueryItem(name: "error_description", value: Self.secret)]
        try await Self.expectNoSecret(
            signingIn: .anthropic, interaction: LoginTests.browser(code: "code", extra: returned), saying: "authorization failed")
        try await Self.expectNoSecret(
            signingIn: .openAI, interaction: LoginTests.browser(code: "code", extra: returned), saying: "authorization failed")
        // A token response that isn't JSON: JavaScriptCore's parse error quotes the text it stopped at.
        MockServer.handle(host: "auth.openai.com") { request in
            let path = request.url.path()
            if path.hasSuffix("/usercode") { return Self.json(device) }
            return path.hasSuffix("/deviceauth/token") ? Self.json(grant) : Self.json("\(Self.secret) isn't JSON")
        }
        try await Self.expectNoSecret(signingIn: "openai-codex", saying: "isn't valid JSON")
        // Meta signs in, then issues no key, with a setup link of its own.
        MockServer.handle(host: "auth.meta.com") { request in
            request.url.path().contains("/device/authorization")
                ? Self.json(#"{"device_code":"dev","user_code":"CODE","verification_uri":"https://auth.meta.com/device","interval":1,"expires_in":60}"#)
                : Self.json(#"{"access_token":"identity"}"#)
        }
        MockServer.handle(host: "api.meta.ai") { _ in Self.json(#"{"action_url":"https://setup.meta.test/?state=\#(Self.secret)"}"#) }
        try await Self.expectNoSecret(signingIn: "meta", saying: "did not issue an API key")
        // OpenRouter's key exchange.
        MockServer.handle(host: "openrouter.ai") { _ in Self.json(#"{"error":{"message":"\#(Self.secret)"},"message":"\#(Self.secret)"}"#, status: 400) }
        try await Self.expectNoSecret(signingIn: "openrouter", interaction: Self.openRouterBrowser)
    }

    /// The bridge's own OAuth for a custom provider: its token exchange, its device authorization and its poll.
    @Test func customProviderSignInSaysOnlyItsStatus() async throws {
        MockServer.handle(host: "auth.custom.test") { _ in Self.refusal }
        let browser = CustomProvider.OAuth(
            signIn: .browser(
                authorizationURL: URL(string: "https://auth.custom.test/authorize")!,
                redirectURI: URL(string: "http://localhost:51234/callback")!),
            tokenURL: URL(string: "https://auth.custom.test/token")!, clientID: "custom-client", scope: "chat")
        try await Self.expectNoSecret(signingIn: "custom", oauth: browser, interaction: LoginTests.browser(code: "code"))
        let device = CustomProvider.OAuth(
            signIn: .deviceCode(deviceAuthorizationURL: URL(string: "https://auth.custom.test/device")!),
            tokenURL: URL(string: "https://auth.custom.test/token")!, clientID: "custom-client", scope: "chat")
        try await Self.expectNoSecret(signingIn: "custom", oauth: device)
        MockServer.handle(host: "auth.custom.test") { request in
            request.url.path() == "/device"
                ? Self.json(#"{"device_code":"dev","user_code":"CODE","verification_uri":"https://auth.custom.test/activate","interval":0,"expires_in":60}"#)
                : Self.refusal
        }
        try await Self.expectNoSecret(signingIn: "custom", oauth: device)
    }

    /// A provider error's diagnostic, which the transcript keeps, holds no stack: one holds the bundle's path, a
    /// user's home folder on a Mac. OpenAI Codex tries a WebSocket first, which JavaScriptCore lacks, so every turn
    /// records one, a successful one too.
    @Test func diagnosticsKeepNoStack() async throws {
        let item = #"{"id":"msg_1","type":"message","status":"in_progress","role":"assistant","content":[]}"#
        let done = #"{"id":"msg_1","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hi","annotations":[]}]}"#
        let response = { (status: String, output: String) in
            #"{"id":"resp_1","object":"response","created_at":1,"status":"\#(status)","model":"gpt-5","output":\#(output),"usage":{"input_tokens":7,"output_tokens":2,"total_tokens":9,"input_tokens_details":{"cached_tokens":0},"output_tokens_details":{"reasoning_tokens":0}}}"#
        }
        let events: [String] = [
            .sse(#"{"type":"response.created","sequence_number":0,"response":\#(response("in_progress", "[]"))}"#, event: "response.created"),
            .sse(#"{"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":\#(item)}"#, event: "response.output_item.added"),
            .sse(#"{"type":"response.output_item.done","sequence_number":2,"output_index":0,"item":\#(done)}"#, event: "response.output_item.done"),
            .sse(#"{"type":"response.completed","sequence_number":3,"response":\#(response("completed", "[" + done + "]"))}"#, event: "response.completed"),
        ]
        MockServer.handle(host: "chatgpt.com") { _ in .init(chunks: events) }
        let store = InMemoryCredentialStore([
            "openai-codex": .oauth(accessToken: Self.chatGPTToken, refreshToken: "refresh", expiresAt: .now.addingTimeInterval(3600))
        ])
        let models = Models(credentials: store, runtime: Self.runtime)
        let model = try #require(try await models.models(for: "openai-codex").first)
        let directory = FileManager.default.temporaryDirectory.appending(path: "m0-90b-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = try await Harness.open(.sqlite(at: directory.appending(path: "harness.sqlite")), models: models)
        let root = try await harness.root(agent: AgentChange(model: model.ref))
        let answer = try await ask(root, "Hi")
        try await harness.close()

        #expect(answer.text == "Hi")
        let stored = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
        #expect(stored.contains("provider_transport_failure"), "the turn recorded its diagnostic")
        #expect(!stored.contains("\"stack\""), "\(stored)")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).map { try Data(contentsOf: $0) }
        for marker in ["pi-durable.js", "file://", "/Users/"] {
            #expect(!files.isEmpty && files.allSatisfy { $0.range(of: Data(marker.utf8)) == nil }, "\(marker) in the harness's file")
        }
    }

    static let kimiDevice = #"""
        {"device_code":"dev","user_code":"CODE","verification_uri":"https://auth.kimi.com/device",
        "verification_uri_complete":"https://auth.kimi.com/device?code=CODE","interval":1,"expires_in":60}
        """#

    /// OpenRouter's sign-in page, which returns to the `callback_url` it was given with a code and no `state`.
    static let openRouterBrowser = LoginInteraction(presentSignInPage: { url in
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var callback = try #require(items.first { $0.name == "callback_url" }?.value.flatMap(URLComponents.init(string:)))
        callback.queryItems = [URLQueryItem(name: "code", value: "code")]
        _ = try await URLSession.shared.data(from: try #require(callback.url))
        while !Task.isCancelled { try await Task.sleep(for: .milliseconds(20)) }
    })

    /// An unsigned JWT with the ChatGPT account claim OpenAI Codex reads.
    static let chatGPTToken: String = {
        func encoded(_ json: String) -> String {
            Data(json.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return encoded(#"{"alg":"none"}"#) + "."
            + encoded(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"account"},"exp":9999999999}"#) + ".sig"
    }()

    /// Signs in to `provider` (a custom one with `oauth`) and expects it to fail with an error that quotes none of the
    /// response, its URL or a stack.
    static func expectNoSecret(
        signingIn provider: ProviderID, oauth: CustomProvider.OAuth? = nil, interaction: LoginInteraction = deviceCode,
        saying expected: String? = nil
    ) async throws {
        let models = Models(credentials: InMemoryCredentialStore(), runtime: runtime)
        if let oauth {
            try await models.register(CustomProvider(
                id: provider, baseURL: URL(string: "https://api.custom.test/v1")!, oauth: oauth, models: [.init(id: "m")]))
        }
        do {
            try await withTimeout(20) { try await models.login(to: provider, interaction: interaction) }
            Issue.record("\(provider): the sign-in should fail")
        } catch {
            let text = String(reflecting: error)
            #expect(!text.contains(secret), "\(provider): the error quotes the response")
            for marker in ["url=", "stack=", "pi-durable.js", "file://"] {
                #expect(!text.contains(marker), "\(provider): the error holds \(marker)")
            }
            // The failure the case is about, not an earlier one.
            if let expected { #expect(text.contains(expected), "\(provider): \(expected)") }
        }
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
