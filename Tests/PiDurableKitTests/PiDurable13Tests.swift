import Foundation
import SQLite3
import Testing
@testable import PiDurableKit

/// pi-durable 1.3.0: table prefixes, malformed tool arguments, and `@earendil-works/chord/output` for extensions.
@Suite struct PiDurable13Tests {
    /// The tables of a SQLite file.
    func tables(in url: URL) throws -> Set<String> {
        var database: OpaquePointer?
        guard sqlite3_open(url.path(percentEncoded: false), &database) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(database, "SELECT name FROM sqlite_master WHERE type = 'table'", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW { names.insert(String(cString: sqlite3_column_text(statement, 0))) }
        return names
    }

    @Test func storagesShareADatabaseUnderTablePrefixes() async throws {
        let url = temporaryDirectory().appending(path: "shared.sqlite")
        let models = Models(builtinProviders: false)
        let first = try await Harness.open(.sqlite(at: url, tablePrefix: "first_"), models: models)
        let firstConversation = try await first.createConversation()
        try await first.close()
        let second = try await Harness.open(.sqlite(at: url, tablePrefix: "second_"), models: models)
        _ = try await second.createConversation()
        _ = try await second.createConversation()
        #expect(try await second.conversations().items.count == 2)
        try await second.close()

        let names = try tables(in: url)
        #expect(names.contains("first_conversations"))
        #expect(names.contains("second_conversations"))
        #expect(!names.contains("conversations"))

        // Each storage sees only its own conversations.
        let reopened = try await Harness.open(.sqlite(at: url, tablePrefix: "first_"), models: models)
        #expect(try await reopened.conversations().items.map(\.id) == [firstConversation.id])
        try await reopened.close()
    }

    @Test func eachTablePrefixHasItsOwnLock() async throws {
        let url = temporaryDirectory().appending(path: "shared.sqlite")
        let models = Models(builtinProviders: false)
        let first = try await Harness.open(.sqlite(at: url, tablePrefix: "first_"), models: models)
        let second = try await Harness.open(.sqlite(at: url, tablePrefix: "second_"), models: models)
        await #expect(throws: PiDurableError.self) { try await Harness.open(.sqlite(at: url, tablePrefix: "first_"), models: models) }
        try await first.close()
        try await second.close()
    }

    @Test func malformedToolArgumentsCarryTheirError() throws {
        let json = #"{"type":"toolCall","id":"call","name":"roll","arguments":{},"argumentsError":"Not a JSON object: {sides"}"#
        let call = try JSONDecoder().decode(ToolCall.self, from: Data(json.utf8))
        #expect(call.arguments.isEmpty)
        #expect(call.argumentsError == "Not a JSON object: {sides")
        let encoded = try JSONValue(encoding: call)
        #expect(encoded["argumentsError"]?.stringValue == "Not a JSON object: {sides")
        #expect(try JSONValue(encoding: ToolCall(id: "call", name: "roll", arguments: [:]))["argumentsError"] == nil)
    }

    @Test func extensionsCanBoundOutputWithChord() async throws {
        let source = #"""
        const { defineExtension, defineTool } = require("@earendil-works/pi-durable");
        const { Type } = require("@earendil-works/pi-ai");
        const { OutputBuffer, utf8ByteLength } = require("@earendil-works/chord/output");
        module.exports = defineExtension({
            name: "bounded",
            tools: [defineTool({
                name: "bounded",
                description: "Bounded output",
                parameters: Type.Object({}),
                execute: async () => ({
                    output: [{ type: "text", text: `${typeof OutputBuffer} ${utf8ByteLength("héllo")}` }],
                }),
            })],
        });
        """#
        let setup = try await FauxSetup.make(extensions: [Extension("bounded", javaScript: source)])
        try await setup.faux.append(.toolCall("bounded", [:]))
        try await setup.faux.append(.text("Done"))
        let root = try await setup.root()
        _ = try await ask(root, "Go")
        let result = try #require(try await root.view().entries.compactMap(\.toolResult).first)
        #expect(result.text == "function 6", "\(result.text)")
    }
}
