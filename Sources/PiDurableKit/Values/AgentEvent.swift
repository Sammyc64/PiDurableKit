import Foundation

/// A coding-agent style event derived from one conversation's commits (pi-durable `watchEvents`).
///
/// The first event of every stream is a ``snapshot(_:)``; later events apply on top of it. A consumer that falls
/// far behind receives a fresh snapshot instead of the events it missed.
public enum AgentEvent: Sendable, Hashable {
    case snapshot(Snapshot)
    case runStart(inputs: [SubmissionID])
    case runEnd(inputs: [SubmissionID])
    case turnStart
    case turnEnd
    case messageStart(Message)
    /// Changes to the in-flight assistant message, with its current usage.
    case messageUpdate(changes: [MessageChange], usage: Usage)
    case messageEnd(Entry)
    case toolExecutionStart(ToolEventCall, arguments: JSONObject)
    /// `diagnostics` is the call's whole diagnostics list, when it changed.
    case toolExecutionUpdate(ToolEventCall, output: OutputChange?, details: JSONValue?, diagnostics: [ToolDiagnostic]?)
    /// A model-issued call ends with its result `entry`, a nested call with its `result`. Both are absent when the
    /// tool task faulted or was orphaned, or when the call ended unfinished.
    case toolExecutionEnd(ToolEventCall, entry: Entry?, result: NestedToolResult?)
    case inboxUpdate([QueuedItem])
    case submission(SubmissionRecord)
    case autoRetryStart(attempt: Int, at: Date, errorMessage: String)
    case autoRetryEnd(attempt: Int)
    /// A provider-side deferred response is polled next at `pollAt`.
    case deferredPoll(pollAt: Date)
    case entryAppended(Entry)
    case agentChanged(AgentState)
    case usageChanged(UsageState)
    case taskFailed(taskId: TaskID, kind: String, message: String)
    case compactionStart(taskId: TaskID, reason: CompactionReason, blocking: Bool)
    /// `error` is set when the compaction failed, faulted, or was orphaned.
    case compactionEnd(taskId: TaskID, reason: CompactionReason, error: String?)
    /// An event this version of PiDurableKit does not know.
    case other(type: String, JSONValue)

    /// The state of the conversation when the stream attached.
    public struct Snapshot: Decodable, Sendable, Hashable {
        public let entries: [Entry]
        /// The inputs of the running run, if busy.
        public let run: [SubmissionID]?
        /// The current generation attempt: its in-flight partial, retry backoff, or deferred poll.
        public let generation: GenerationStatus?
        /// The in-flight partial response, if a generation is streaming.
        public var message: AssistantMessage? { generation?.message }
        public let tools: [LiveState.ToolSlot]
        /// Nested calls of running tool calls.
        public let nestedTools: [LiveState.NestedToolSlot]
        /// Live compactions with their attempt and retry backoff.
        public let compactions: [CompactionStatus]
        /// The newest compaction failure since a compaction last produced a summary.
        public let compactionFailure: CompactionFailure?
        public let inbox: [QueuedItem]
        public let agent: AgentState
        public let usage: UsageState

        private enum CodingKeys: String, CodingKey {
            case entries, run, generation, tools, nestedTools, compactions, compactionFailure, inbox, agent, usage
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            entries = try container.decodeIfPresent([Entry].self, forKey: .entries) ?? []
            run = try container.decodeIfPresent(JSONValue.self, forKey: .run)?["inputs"].flatMap { try? $0.decode(as: [SubmissionID].self) }
            generation = try? container.decodeIfPresent(GenerationStatus.self, forKey: .generation)
            tools = (try? container.decodeIfPresent([LiveState.ToolSlot].self, forKey: .tools)) ?? []
            nestedTools = (try? container.decodeIfPresent([LiveState.NestedToolSlot].self, forKey: .nestedTools)) ?? []
            compactions = (try? container.decodeIfPresent([CompactionStatus].self, forKey: .compactions)) ?? []
            compactionFailure = try? container.decodeIfPresent(CompactionFailure.self, forKey: .compactionFailure)
            inbox = (try? container.decodeIfPresent([QueuedItem].self, forKey: .inbox)) ?? []
            agent = (try? container.decodeIfPresent(AgentState.self, forKey: .agent)) ?? AgentState()
            usage = (try? container.decodeIfPresent(UsageState.self, forKey: .usage)) ?? UsageState()
        }
    }

    public struct QueuedItem: Decodable, Sendable, Hashable {
        public let id: SubmissionID
        public let mode: InboxItem.Mode
    }

    /// A change to the running output of a tool call.
    public enum OutputChange: Sendable, Hashable {
        /// Drop `trimStart` characters from the front, then append `append`.
        case append(String, trimStart: Int)
        /// Replace the whole output.
        case set(String)
    }
}

/// Which call a tool event is about (pi-durable `ToolEventCall`). Match events by ``callId``; don't parse it.
public struct ToolEventCall: Sendable, Hashable {
    /// The provider's ID for a model-issued call, `<parent call ID>/<key>` for a nested one.
    public let callId: String
    public let toolName: String
    /// The call's tool task; `nil` for a call that never got one.
    public let taskId: TaskID?
    /// For a nested call: the call that made it.
    public let parentCallId: String?
    public let parentTaskId: TaskID?

    public var isNested: Bool { parentCallId != nil }

    init(_ json: JSONValue) {
        callId = json["toolCallId"]?.stringValue ?? ""
        toolName = json["toolName"]?.stringValue ?? ""
        taskId = json["taskId"]?.intValue.map { TaskID($0) }
        parentCallId = json["parentToolCallId"]?.stringValue
        parentTaskId = json["parentTaskId"]?.intValue.map { TaskID($0) }
    }
}

/// One change to the in-flight assistant message.
public enum MessageChange: Sendable, Hashable {
    case blockStart(index: Int, block: ContentBlock)
    case textDelta(index: Int, delta: String)
    case thinkingDelta(index: Int, delta: String)
    case toolCallDelta(index: Int, path: [JSONValue], delta: String)
    case block(index: Int, block: ContentBlock)
    case message(AssistantMessage)
    case other(JSONValue)
}

extension MessageChange: Decodable {
    public init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        let index = json["contentIndex"]?.intValue ?? 0
        switch json["type"]?.stringValue {
        case "text_start", "thinking_start", "toolcall_start", "block":
            guard let block = try? json["block"]?.decode(as: ContentBlock.self) else {
                self = .other(json)
                return
            }
            self = json["type"]?.stringValue == "block" ? .block(index: index, block: block) : .blockStart(index: index, block: block)
        case "text_delta": self = .textDelta(index: index, delta: json["delta"]?.stringValue ?? "")
        case "thinking_delta": self = .thinkingDelta(index: index, delta: json["delta"]?.stringValue ?? "")
        case "toolcall_delta":
            self = .toolCallDelta(index: index, path: json["path"]?.arrayValue ?? [], delta: json["delta"]?.stringValue ?? "")
        case "message":
            if let message = try? json["message"]?.decode(as: AssistantMessage.self) {
                self = .message(message)
            } else {
                self = .other(json)
            }
        default: self = .other(json)
        }
    }
}

extension AgentEvent: Decodable {
    public init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        do {
            self = try Self.decode(json)
        } catch {
            // Never fail a stream over one event whose shape changed upstream.
            self = .other(type: json["type"]?.stringValue ?? "", json)
        }
    }

    private static func decode(_ json: JSONValue) throws -> AgentEvent {
        let type = json["type"]?.stringValue ?? ""
        func value<T: Decodable>(_ key: String, as: T.Type = T.self) throws -> T {
            guard let field = json[key] else {
                throw DecodingError.keyNotFound(AnyKey(key), .init(codingPath: [], debugDescription: "\(type).\(key)"))
            }
            return try field.decode(as: T.self)
        }
        let string = { (key: String) in json[key]?.stringValue ?? "" }

        switch type {
        case "snapshot": return .snapshot(try json.decode(as: Snapshot.self))
        case "run_start": return .runStart(inputs: try value("inputs"))
        case "run_end": return .runEnd(inputs: try value("inputs"))
        case "turn_start": return .turnStart
        case "turn_end": return .turnEnd
        case "message_start": return .messageStart(try value("message"))
        case "message_update":
            return .messageUpdate(changes: try value("changes"), usage: (try? value("usage")) ?? Usage())
        case "message_end": return .messageEnd(try value("entry"))
        case "tool_execution_start":
            return .toolExecutionStart(ToolEventCall(json), arguments: json["args"]?.objectValue ?? [:])
        case "tool_execution_update":
            var output: OutputChange?
            if let set = json["output"]?["set"]?.stringValue {
                output = .set(set)
            } else if let change = json["output"] {
                output = .append(change["append"]?.stringValue ?? "", trimStart: change["trimStart"]?.intValue ?? 0)
            }
            return .toolExecutionUpdate(
                ToolEventCall(json), output: output, details: json["details"],
                diagnostics: json["diagnostics"].flatMap { try? $0.decode(as: [ToolDiagnostic].self) })
        case "tool_execution_end":
            return .toolExecutionEnd(
                ToolEventCall(json), entry: try? value("entry", as: Entry.self),
                result: try? value("result", as: NestedToolResult.self))
        case "inbox_update": return .inboxUpdate(try value("items"))
        case "submission": return .submission(try value("record"))
        case "auto_retry_start":
            return .autoRetryStart(
                attempt: json["attempt"]?.intValue ?? 0,
                at: Date(timeIntervalSince1970: (json["at"]?.doubleValue ?? 0) / 1000),
                errorMessage: string("errorMessage"))
        case "auto_retry_end": return .autoRetryEnd(attempt: json["attempt"]?.intValue ?? 0)
        case "deferred_poll": return .deferredPoll(pollAt: Date(timeIntervalSince1970: (json["pollAt"]?.doubleValue ?? 0) / 1000))
        case "entry_appended": return .entryAppended(try value("entry"))
        case "agent_changed": return .agentChanged(try value("agent"))
        case "usage_changed": return .usageChanged(try value("usage"))
        case "task_failed":
            return .taskFailed(taskId: try value("taskId"), kind: string("kind"), message: string("message"))
        case "compaction_start":
            return .compactionStart(
                taskId: try value("taskId"), reason: CompactionReason(rawValue: string("reason")),
                blocking: json["blocking"]?.boolValue ?? false)
        case "compaction_end":
            return .compactionEnd(
                taskId: try value("taskId"), reason: CompactionReason(rawValue: string("reason")), error: json["error"]?.stringValue)
        default: return .other(type: type, json)
        }
    }
}

/// One conversation's agent events (pi-durable `AgentEventStream`): the snapshot at attachment, then one batch per
/// commit. When a consumer falls far behind, a batch holds a fresh ``AgentEvent/snapshot(_:)`` instead of the events it
/// missed. Iterate once; stopping the iteration (or cancelling its task) stops the stream.
public struct AgentEventStream: AsyncSequence, Sendable {
    public typealias Element = [AgentEvent]

    /// The `snapshot` event at attachment.
    public let snapshot: AgentEvent.Snapshot
    private let box: IteratorBox

    init(snapshot: AgentEvent.Snapshot, iterator: AsyncThrowingStream<[AgentEvent], Error>.AsyncIterator) {
        self.snapshot = snapshot
        box = IteratorBox(iterator)
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(box: box)
    }

    public struct Iterator: AsyncIteratorProtocol {
        let box: IteratorBox

        public mutating func next() async throws -> [AgentEvent]? {
            try await box.next()
        }
    }

    /// Holds the single underlying iterator.
    final class IteratorBox: @unchecked Sendable {
        private var iterator: AsyncThrowingStream<[AgentEvent], Error>.AsyncIterator

        init(_ iterator: AsyncThrowingStream<[AgentEvent], Error>.AsyncIterator) {
            self.iterator = iterator
        }

        func next() async throws -> [AgentEvent]? {
            try await iterator.next()
        }
    }
}
