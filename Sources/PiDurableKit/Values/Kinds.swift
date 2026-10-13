import Foundation

/// Why a compaction runs (pi-durable `CompactionReason`).
public struct CompactionReason: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    /// ``Conversation/compact(instructions:)``.
    public static let manual: CompactionReason = "manual"
    /// The context crossed the settings' threshold before a request.
    public static let threshold: CompactionReason = "threshold"
    /// A provider rejected a request because the context was too long.
    public static let overflow: CompactionReason = "overflow"
}

/// A durable backoff before the next attempt of a generation or a compaction.
public struct RetryBackoff: Decodable, Sendable, Hashable {
    /// When the next attempt starts.
    public let at: Date
    /// The error of the failed attempt.
    public let error: String

    private enum CodingKeys: String, CodingKey { case at, error }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        at = try container.decodeMilliseconds(forKey: .at)
        error = try container.decodeIfPresent(String.self, forKey: .error) ?? ""
    }
}

/// A provider-side deferred response being polled.
public struct DeferredPoll: Decodable, Sendable, Hashable {
    /// When the response is polled next.
    public let pollAt: Date

    private enum CodingKeys: String, CodingKey { case pollAt }

    public init(from decoder: Decoder) throws {
        pollAt = try decoder.container(keyedBy: CodingKeys.self).decodeMilliseconds(forKey: .pollAt)
    }
}

/// The current generation attempt of a conversation's run (pi-durable `LiveState.generation`).
public struct GenerationStatus: Decodable, Sendable, Hashable {
    public let attempt: Int
    /// The partial response, committed periodically while it streams.
    public let message: AssistantMessage?
    /// A durable backoff before the next attempt.
    public let retry: RetryBackoff?
    /// A provider-side deferred response being polled.
    public let deferred: DeferredPoll?

    private enum CodingKeys: String, CodingKey { case attempt, message, retry, deferred }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attempt = (try? container.decodeIfPresent(Int.self, forKey: .attempt)) ?? 0
        message = try? container.decodeIfPresent(AssistantMessage.self, forKey: .message)
        retry = try? container.decodeIfPresent(RetryBackoff.self, forKey: .retry)
        deferred = try? container.decodeIfPresent(DeferredPoll.self, forKey: .deferred)
    }
}

/// One live compaction task (pi-durable `CompactionStatus`).
public struct CompactionStatus: Decodable, Sendable, Hashable {
    public let taskId: TaskID
    public let reason: CompactionReason
    /// Whether a generation waits for it.
    public let blocking: Bool
    public let attempt: Int
    /// A durable backoff before the next summarization attempt.
    public let retry: RetryBackoff?

    private enum CodingKeys: String, CodingKey { case taskId, reason, blocking, attempt, retry }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskId = try container.decode(TaskID.self, forKey: .taskId)
        reason = try container.decodeIfPresent(CompactionReason.self, forKey: .reason) ?? .manual
        blocking = try container.decodeIfPresent(Bool.self, forKey: .blocking) ?? false
        attempt = (try? container.decodeIfPresent(Int.self, forKey: .attempt)) ?? 0
        retry = try? container.decodeIfPresent(RetryBackoff.self, forKey: .retry)
    }
}

/// The newest compaction that failed since a compaction last produced a summary (pi-durable `CompactionFailure`).
public struct CompactionFailure: Decodable, Sendable, Hashable {
    public let taskId: TaskID
    public let reason: CompactionReason
    /// The error message, or why the task was orphaned.
    public let error: String
}

/// How a nested call ended (pi-durable `NestedToolSummary`).
public struct NestedToolSummary: Decodable, Sendable, Hashable {
    public let isError: Bool
    public let duration: Duration?
    public let usage: Usage?
    /// Up to 500 characters of error text.
    public let error: String?

    private enum CodingKeys: String, CodingKey { case isError, durationMs, usage, error }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        duration = try container.decodeIfPresent(Double.self, forKey: .durationMs).map { .milliseconds($0) }
        usage = try? container.decodeIfPresent(Usage.self, forKey: .usage)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}
