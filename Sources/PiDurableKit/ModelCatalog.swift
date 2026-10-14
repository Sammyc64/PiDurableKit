import Foundation
import os

/// Where built-in providers find models released after this package was built: pi.dev's catalog, as pi uses it.
///
/// Each built-in provider's bundled models get an overlay of the catalog's (OpenRouter's is narrowed to what its key
/// can use). Catalogs fetched are kept in ``directory``, so they're there offline and after a relaunch, and
/// ``Models/refresh(providers:allowNetwork:force:)`` checks for newer ones (at most every four hours per provider,
/// revalidated with ETags). A catalog older than the bundled models is ignored.
///
/// ```swift
/// let models = Models(credentials: .keychain)   // pi.dev's catalog, kept in Caches
/// try await models.refresh()                    // at launch, say; then list the models again
/// ```
public struct ModelCatalog: Sendable {
    /// The catalog server: `GET /api/models/providers/<provider>` answers with a provider's pi-ai models.
    public var url: URL
    /// Where catalogs are kept between launches; `nil` keeps them in memory.
    public var directory: URL?

    public init(url: URL = URL(string: "https://pi.dev")!, directory: URL? = ModelCatalog.defaultDirectory) {
        self.url = url
        self.directory = directory
    }

    /// pi.dev's catalog, kept in ``defaultDirectory``.
    public static let piDev = ModelCatalog()

    /// `PiDurableKit/Models` in the app's Caches directory.
    public static var defaultDirectory: URL { URL.cachesDirectory.appending(path: "PiDurableKit/Models", directoryHint: .isDirectory) }
}

/// The catalogs fetched, by provider: one JSON file each in a directory, or in memory.
final class ModelCatalogStore: Sendable {
    private let directory: URL?
    private let memory = OSAllocatedUnfairLock<[ProviderID: JSONValue]>(initialState: [:])

    init(directory: URL?) {
        self.directory = directory
    }

    func read(_ provider: ProviderID) -> JSONValue? {
        guard let file = file(for: provider) else { return memory.withLock { $0[provider] } }
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? decodeJSON(JSONValue.self, from: data)
    }

    /// Stores the entry, or with `nil`, removes it.
    func write(_ entry: JSONValue?, for provider: ProviderID) throws {
        guard let file = file(for: provider) else { return memory.withLock { $0[provider] = entry } }
        guard let entry else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try BridgeArguments.json(entry).write(to: file, options: .atomic)
    }

    private func file(for provider: ProviderID) -> URL? {
        let name = provider.rawValue.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(["-", "_", "."])) ?? provider.rawValue
        return directory?.appending(path: "\(name).json", directoryHint: .notDirectory)
    }
}
