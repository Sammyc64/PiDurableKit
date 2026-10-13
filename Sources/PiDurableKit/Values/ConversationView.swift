import Foundation

/// Everything a UI needs to show one conversation: its active transcript and live state. Each committed
/// change produces a new view; see ``Conversation/views()``.
public struct ConversationView: Decodable, Sendable, Hashable {
    public let conversation: ConversationRecord
    /// The active transcript: the head marker (if any), then every entry from its head onward.
    public let entries: [Entry]
    /// The running generation and tool calls (`pi.live`).
    public let live: LiveState
    /// Queued submissions (`pi.inbox`).
    public let inbox: [InboxItem]
    /// The conversation's spend (`pi.usage`).
    public let usage: UsageState
    /// The stored agent choices (`pi.agent`).
    public let agent: AgentState
    /// The provider-facing session identity (`pi.provider`).
    public let providerSessionId: String?
    /// Every built-in document, raw, keyed by kind.
    public let documents: JSONObject

    private enum CodingKeys: String, CodingKey { case conversation, entries, docs }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            conversation: try container.decode(ConversationRecord.self, forKey: .conversation),
            entries: try container.decodeIfPresent([Entry].self, forKey: .entries) ?? [],
            docs: try container.decodeIfPresent(JSONObject.self, forKey: .docs) ?? [:])
    }

    init(conversation: ConversationRecord, entries: [Entry], docs: JSONObject) {
        self.conversation = conversation
        self.entries = entries
        documents = docs
        live = (try? docs["pi.live"].map { try $0.decode(as: LiveState.self) }) ?? LiveState()
        inbox = (try? docs["pi.inbox"]?["items"].map { try $0.decode(as: [InboxItem].self) }) ?? []
        usage = (try? docs["pi.usage"].map { try $0.decode(as: UsageState.self) }) ?? UsageState()
        agent = (try? docs["pi.agent"].map { try $0.decode(as: AgentState.self) }) ?? AgentState()
        providerSessionId = docs["pi.provider"]?["sessionId"]?.stringValue
    }

    /// Whether a run is working on an input.
    public var isBusy: Bool { live.run != nil }

    /// The answer being generated right now, as last committed.
    public var streamingMessage: AssistantMessage? { live.generation?.message }

    /// The transcript's user, assistant, and tool result messages, in order.
    public var messages: [Message] {
        entries.flatMap { entry -> [Message] in
            guard entry.kind != .system else { return [] }
            return (entry.model ?? []).filter { if case .system = $0 { false } else { true } }
        }
    }
}

/// Live presentation of the current run (`pi.live`).
public struct LiveState: Decodable, Sendable, Hashable {
    public struct Run: Decodable, Sendable, Hashable {
        /// The task that settles the run's inputs.
        public let taskId: TaskID
        public let inputs: [SubmissionID]
    }

    public typealias Generation = GenerationStatus
    public typealias Retry = RetryBackoff
    public typealias Compaction = CompactionStatus

    /// One tool call of the current round.
    public struct ToolSlot: Decodable, Sendable, Hashable, Identifiable {
        public enum Status: String, Decodable, Sendable {
            case pending, running, done
        }

        public var id: String { callId }
        public let callId: String
        public let name: String
        public let taskId: TaskID?
        public let status: Status
        /// The output the tool streamed so far, within the tool's output limits.
        public let output: String?
        /// Bytes of output the limits dropped.
        public let droppedBytes: Int?
        /// Lines of output the limits dropped.
        public let droppedLines: Int?
        public let details: JSONValue?
        /// Diagnostics recorded with ``ToolCallContext/diagnostic(_:)``.
        public let diagnostics: [ToolDiagnostic]?
        /// The result entry, once done; absent when the tool task faulted or was orphaned.
        public let entry: EntryID?
    }

    /// One nested call: a call a running tool made with ``ToolCallContext/executeTool(_:arguments:key:progress:)-(_,JSONObject,_,_)``
    /// (pi-durable `NestedToolSlot`).
    public struct NestedToolSlot: Decodable, Sendable, Hashable, Identifiable {
        public var id: String { callId }
        /// `<parentCallId>/<key>`, the call's ID in tool events.
        public let callId: String
        public let name: String
        /// The calling tool call.
        public let parentCallId: String
        public let parentTaskId: TaskID
        /// The nested call's tool task.
        public let taskId: TaskID
        public let status: ToolSlot.Status
        /// The arguments the call runs with, once it starts executing.
        public let arguments: JSONObject
        public let output: String?
        public let droppedBytes: Int?
        public let droppedLines: Int?
        public let details: JSONValue?
        public let diagnostics: [ToolDiagnostic]?
        /// Once done: how the call ended.
        public let summary: NestedToolSummary?
    }

    /// Present exactly while the conversation is busy.
    public let run: Run?
    public let generation: Generation?
    public let tools: [ToolSlot]
    /// Nested calls of running tool calls, parents before their children.
    public let nestedTools: [NestedToolSlot]
    public let compactions: [Compaction]
    /// The newest compaction failure since a compaction last produced a summary.
    public let compactionFailure: CompactionFailure?

    init() {
        run = nil
        generation = nil
        tools = []
        nestedTools = []
        compactions = []
        compactionFailure = nil
    }

    private enum CodingKeys: String, CodingKey { case run, generation, tools, nestedTools, compactions, compactionFailure }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        run = try? container.decodeIfPresent(Run.self, forKey: .run)
        generation = try? container.decodeIfPresent(Generation.self, forKey: .generation)
        tools = (try? container.decodeIfPresent([ToolSlot].self, forKey: .tools)) ?? []
        nestedTools = (try? container.decodeIfPresent([NestedToolSlot].self, forKey: .nestedTools)) ?? []
        compactions = (try? container.decodeIfPresent([Compaction].self, forKey: .compactions)) ?? []
        compactionFailure = try? container.decodeIfPresent(CompactionFailure.self, forKey: .compactionFailure)
    }
}

/// One update of ``Conversation/views()`` on the wire: the whole transcript, or the entries appended since the last
/// update after keeping the first `keep` of its entries.
struct ConversationViewUpdate: Decodable, Sendable {
    let conversation: ConversationRecord
    let entries: [Entry]?
    let keep: Int?
    let append: [Entry]?
    let docs: JSONObject?

    func view(after previous: [Entry]) -> ConversationView {
        var transcript = entries ?? []
        if entries == nil, let keep {
            transcript = Array(previous.prefix(keep)) + (append ?? [])
        }
        return ConversationView(conversation: conversation, entries: transcript, docs: docs ?? [:])
    }
}
