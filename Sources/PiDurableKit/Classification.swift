import Foundation

/// What a classifier judges (pi-ai `ClassifierContext`): a state, and questions about it.
public struct ClassifierContext: Encodable, Sendable {
    /// What is judged.
    public var state: JSONObject
    /// The questions, by ID; their answers come back under the same IDs.
    public var questions: [String: ClassifierQuestion]

    public init(state: JSONObject, questions: [String: ClassifierQuestion]) {
        self.state = state
        self.questions = questions
    }
}

/// A question for a classifier (pi-ai `ClassifierQuestion`): its instructions, and what its answers mean.
public enum ClassifierQuestion: Encodable, Sendable, Hashable {
    /// A yes or no, with what each means. Answered with the probability of yes.
    case bool(instructions: String, whenTrue: String, whenFalse: String)
    /// One of several labels, each with what it means. Answered with a label, the probability of each, and a confidence.
    case choice(instructions: String, labels: [String: String])
    /// A score on a scale whose levels are described lowest first. Answered with a score and a confidence.
    case score(instructions: String, levels: [String])

    public func encode(to encoder: Encoder) throws {
        let (type, instructions, criteria): (String, String, JSONValue) =
            switch self {
            case .bool(let instructions, let whenTrue, let whenFalse):
                ("bool", instructions, ["true": .string(whenTrue), "false": .string(whenFalse)])
            case .choice(let instructions, let labels): ("choice", instructions, .object(labels.mapValues(JSONValue.string)))
            case .score(let instructions, let levels): ("score", instructions, .array(levels.map(JSONValue.string)))
            }
        try JSONValue.object(["type": .string(type), "instructions": .string(instructions), "criteria": criteria]).encode(to: encoder)
    }
}

/// A classifier's answer to one question (pi-ai `ClassifierAnswer`).
public enum ClassifierAnswer: Decodable, Sendable, Hashable {
    /// The probability that the answer is yes, from 0 to 1.
    case bool(probability: Double)
    /// The label chosen, the probability of each label, and the classifier's confidence.
    case choice(String, probabilities: [String: Double], confidence: Double)
    /// The score, and the classifier's confidence.
    case score(Double, confidence: Double)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        func number(_ key: String) throws -> Double { try container.decode(Double.self, forKey: AnyKey(key)) }
        switch try container.decode(String.self, forKey: AnyKey("type")) {
        case "bool": self = .bool(probability: try number("probability"))
        case "choice":
            self = .choice(
                try container.decode(String.self, forKey: AnyKey("choice")),
                probabilities: try container.decode([String: Double].self, forKey: AnyKey("probabilities")),
                confidence: try number("confidence"))
        case "score": self = .score(try number("score"), confidence: try number("confidence"))
        case let type:
            throw DecodingError.dataCorruptedError(forKey: AnyKey("type"), in: container, debugDescription: "Unknown answer type \(type)")
        }
    }
}

/// A classification (pi-ai `ClassifierResult`): an answer to every question.
public struct ClassifierResult: Decodable, Sendable, Hashable {
    public let provider: ProviderID
    public let model: String
    /// The classifier API, such as `typesafe-system-one`.
    public let api: String
    /// The answers, by question ID.
    public let answers: [String: ClassifierAnswer]
    /// The tokens used and their cost at the model's price, when the service reports them.
    public let usage: Usage?
}

/// Why a classification has no answers (a pi-ai `ClassifierResult` that stopped for an `error` or was `aborted`).
public enum ClassifierError: Error, Sendable, Hashable, LocalizedError, CustomStringConvertible {
    /// The service returned an error, or answers that don't parse. `usage` is what it reported using, if anything.
    case failed(String, usage: Usage?)
    /// The request was cancelled.
    case aborted(String)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .failed(let message, _), .aborted(let message): message
        }
    }
}

extension Models {
    /// Answers questions about a state with a classifier model (pi-ai `models.classify`), such as a ``CustomProvider``
    /// model of type ``ModelType/classifier``. Credentials and headers resolve as for other requests. A classification
    /// answers every question, or throws ``ClassifierError``; cancelling the task aborts the request.
    ///
    /// Tools that classify can report the spend in ``ToolResult/usage``.
    public func classify(_ model: ModelRef, context: ClassifierContext) async throws -> ClassifierResult {
        switch try await call("models.classify", ["model": model, "context": context]) as ClassifierReply {
        case .answered(let result): return result
        case .failed(let error): throw error
        }
    }
}

/// A pi-ai `ClassifierResult` as the bridge returns it: answers, or why there are none.
private enum ClassifierReply: Decodable, Sendable {
    case answered(ClassifierResult)
    case failed(ClassifierError)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        let stopReason = try container.decode(String.self, forKey: AnyKey("stopReason"))
        let message = try container.decodeIfPresent(String.self, forKey: AnyKey("errorMessage")) ?? stopReason
        switch stopReason {
        case "stop": self = .answered(try ClassifierResult(from: decoder))
        case "aborted": self = .failed(.aborted(message))
        default: self = .failed(.failed(message, usage: try container.decodeIfPresent(Usage.self, forKey: AnyKey("usage"))))
        }
    }
}
