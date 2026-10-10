import Foundation

/// An error raised by pi-durable or by the PiDurableKit bridge.
public enum PiDurableError: Error, Sendable, LocalizedError, CustomStringConvertible {
    /// A submission with `whenBusy: .reject` reached this busy conversation (pi-durable `ConversationBusy`).
    case conversationBusy(ConversationID)
    /// A transaction read a table (conversations, entries, tasks) after its first table write. Read first, then write.
    case readAfterWrite(String)
    /// Storage rejected a commit before any durable effect; the harness can continue.
    case storageRejected(String)
    /// JSONL storage found a damaged file (pi-durable `JsonlCorruptionError`).
    case jsonlCorrupted(String)
    /// JSONL storage failed in a way that leaves its state uncertain; reopen it (pi-durable `JsonlStoragePoisonedError`).
    case jsonlPoisoned(String)
    /// An execution environment's file operation failed (pi-durable `FileError`): `code` is `not_found`,
    /// `permission_denied`, `not_directory`, `is_directory`, `invalid`, `not_supported`, `aborted`, or `unknown`.
    case file(code: String, message: String, path: String?)
    /// An execution environment's command failed (pi-durable `ExecutionError`): `code` is `aborted`, `timeout`,
    /// `shell_unavailable`, `spawn_error`, `callback_error`, or `unknown`. `spillPath` holds the complete output of a
    /// command whose output crossed the spill thresholds.
    case execution(code: String, message: String, spillPath: String?)
    /// The conversation, submission, or entry does not exist.
    case notFound(String)
    /// A wait or operation was cancelled.
    case cancelled
    /// Any other JavaScript error thrown by pi-durable or pi-ai, with its `code` property if it has one.
    case javaScript(name: String, message: String, stack: String?, code: String?)
    /// The JavaScript runtime could not be started.
    case runtime(String)
    /// A value returned by pi-durable did not have the expected shape.
    case decoding(method: String, underlying: any Error, json: String)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .conversationBusy(let id): "Conversation \(id) is busy"
        case .readAfterWrite(let message): message
        case .storageRejected(let message): "Storage rejected the commit: \(message)"
        case .jsonlCorrupted(let message): "JSONL storage is corrupted: \(message)"
        case .jsonlPoisoned(let message): message
        case .file(_, let message, _): message
        case .execution(_, let message, _): message
        case .notFound(let message): message
        case .cancelled: "Cancelled"
        case .javaScript(let name, let message, _, _): "\(name): \(message)"
        case .runtime(let message): message
        case .decoding(let method, let underlying, let json):
            "Could not decode the result of \(method): \(underlying)\n\(json.prefix(2000))"
        }
    }

    init(javaScriptJSON json: String) {
        struct Info: Decodable {
            var name: String?
            var message: String?
            var stack: String?
            var code: JSONValue?
            var conversationId: Int?
            var path: String?
            var spillPath: String?
        }
        let info = (try? JSONDecoder().decode(Info.self, from: Data(json.utf8))) ?? Info(message: json)
        let name = info.name ?? "Error"
        let message = info.message ?? ""
        let code = info.code.flatMap { $0.stringValue ?? ($0.isNull ? nil : $0.jsonString) }
        switch name {
        case "ConversationBusy": self = .conversationBusy(ConversationID(info.conversationId ?? 0))
        case "ReadAfterWrite": self = .readAfterWrite(message)
        case "StorageRejected": self = .storageRejected(message)
        case "JsonlCorruptionError": self = .jsonlCorrupted(message)
        case "JsonlStoragePoisonedError": self = .jsonlPoisoned(message)
        case "FileError": self = .file(code: code ?? "unknown", message: message, path: info.path)
        case "ExecutionError": self = .execution(code: code ?? "unknown", message: message, spillPath: info.spillPath)
        case "NotFound": self = .notFound(message)
        case "AbortError" where message.localizedCaseInsensitiveContains("abort"): self = .cancelled
        default: self = .javaScript(name: name, message: message, stack: info.stack, code: code)
        }
    }
}
