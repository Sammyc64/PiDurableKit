import Foundation
import Testing
@testable import PiDurableKit

/// Newer models for the built-in providers from a catalog server, served by `MockServer`: fetched, kept for the next
/// launch, revalidated, and ignored when older than the bundled models.
extension MockServerTests {
@Suite struct ModelCatalogTests {
    static let runtime = Runtime(configuration: .init(urlSessionConfiguration: MockServer.configuration))

    /// A catalog of one new Anthropic model, as pi.dev serves it.
    static func serveCatalog(lastModified: String, etag: String = "\"v1\"") {
        MockServer.handle(host: "catalog.test") { request in
            guard request.url.path() == "/api/models/providers/anthropic" else {
                return .init(status: 404, headers: [:], chunks: ["not found"])
            }
            if request.header("if-none-match") == etag { return .init(status: 304, headers: [:], chunks: []) }
            let model = #"""
                [{"id":"claude-next","name":"Claude Next","api":"anthropic-messages","provider":"anthropic",
                "baseUrl":"https://api.anthropic.com","reasoning":true,"input":["text","image"],
                "cost":{"input":3,"output":15,"cacheRead":0.3,"cacheWrite":3.75},"contextWindow":1000000,"maxTokens":64000}]
                """#
            return .init(headers: ["content-type": "application/json", "last-modified": lastModified, "etag": etag], chunks: [model])
        }
    }

    static func catalog(_ directory: URL?) -> ModelCatalog {
        ModelCatalog(url: URL(string: "https://catalog.test")!, directory: directory)
    }

    /// A custom provider following Anthropic's catalog gets its newer models by refreshing itself, with its own
    /// credential, while Anthropic has none.
    @Test func aCustomProviderFollowingACatalogRefreshesIt() async throws {
        Self.serveCatalog(lastModified: "Fri, 01 Jan 2100 00:00:00 GMT")
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = Models(catalog: Self.catalog(directory), runtime: Self.runtime)
        try await models.register(CustomProvider(
            id: "claude-gateway", baseURL: URL(string: "https://gateway.test")!, api: .anthropicMessages, apiKey: "secret",
            catalog: .anthropic))
        #expect(try await models.credential(for: .anthropic) == nil)
        #expect(try await !models.models(for: "claude-gateway").contains { $0.modelId == "claude-next" })

        let result = try await models.refresh(providers: ["claude-gateway"])
        #expect(result.errors.isEmpty)
        let added = try #require(try await models.models(for: "claude-gateway").first { $0.modelId == "claude-next" })
        #expect(added.provider == "claude-gateway")
        #expect(added.baseUrl == "https://gateway.test")
        #expect(added.contextWindow == 1_000_000)
    }

    @Test func addsNewerModelsAndKeepsThemForTheNextLaunch() async throws {
        Self.serveCatalog(lastModified: "Fri, 01 Jan 2100 00:00:00 GMT")
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Catalogs are only fetched for providers with a credential, as in pi.
        let models = Models(catalog: Self.catalog(directory), runtime: Self.runtime)
        try await models.setAPIKey("key", for: .anthropic)
        #expect(try await !models.models(for: .anthropic).contains { $0.modelId == "claude-next" })
        let result = try await models.refresh(providers: [.anthropic])
        #expect(result.errors.isEmpty)
        let added = try #require(try await models.models(for: .anthropic).first { $0.modelId == "claude-next" })
        #expect(added.name == "Claude Next")
        #expect(added.contextWindow == 1_000_000)
        // The bundled models are still there.
        #expect(try await models.models(for: .anthropic).count > 1)

        // Next launch: there before any refresh, offline.
        let relaunched = Models(credentials: models.credentials, catalog: Self.catalog(directory), runtime: Self.runtime)
        #expect(try await relaunched.models(for: .anthropic).contains { $0.modelId == "claude-next" })

        // Checked again within four hours only when forced, and then revalidated with the ETag.
        let before = MockServer.requests(to: "catalog.test").count
        try await relaunched.refresh(providers: [.anthropic])
        #expect(MockServer.requests(to: "catalog.test").count == before)
        try await relaunched.refresh(providers: [.anthropic], force: true)
        #expect(MockServer.requests(to: "catalog.test").last?.header("if-none-match") == "\"v1\"")
        #expect(try await relaunched.models(for: .anthropic).contains { $0.modelId == "claude-next" })
    }

    @Test func ignoresCatalogsOlderThanTheBundle() async throws {
        Self.serveCatalog(lastModified: "Thu, 01 Jan 2015 00:00:00 GMT")
        let models = Models(catalog: Self.catalog(nil), runtime: Self.runtime)
        try await models.setAPIKey("key", for: .anthropic)
        try await models.refresh(providers: [.anthropic])
        #expect(try await !models.models(for: .anthropic).contains { $0.modelId == "claude-next" })
    }

    @Test func withoutACatalogOnlyTheBundledModels() async throws {
        Self.serveCatalog(lastModified: "Fri, 01 Jan 2100 00:00:00 GMT")
        let models = Models(catalog: nil, runtime: Self.runtime)
        try await models.setAPIKey("key", for: .anthropic)
        try await models.refresh(providers: [.anthropic])
        #expect(try await !models.models(for: .anthropic).contains { $0.modelId == "claude-next" })
    }
}
}
