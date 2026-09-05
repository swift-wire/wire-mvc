// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

import AsyncStreaming
import BasicContainers
import Elementary
import HTTPTypes
import StreamingBodyProducers
import Testing
import WireMVC
import WireMVCElementary

// The end-to-end claim: Elementary HTML renders *directly* into swift-http-api-proposal's lifetime-bound
// response body writer, through WireMVC's streaming tier, with no intermediate buffer and no bridging task.
//
// Requires the pinned Elementary fork, via wire-mvc's `Elementary` trait. Against
// upstream Elementary this file does not compile at all: `HTMLStreamWriter` requires an escapable conformer,
// and `ProposalHTMLStreamWriter` cannot be one.

struct Todo: Sendable {
    let id: String
    let title: String
}

struct TodosPage: HTMLDocument {
    let todos: [Todo]
    var title: String { "Todos" }

    var head: some HTML {
        meta(.name(.viewport), .content("width=device-width, initial-scale=1.0"))
    }

    var body: some HTML {
        h1 { "Todos" }
        ul {
            for todo in todos {
                li(.id(todo.id)) { todo.title }
            }
        }
    }
}

@Suite("Elementary through the streaming tier")
struct ElementaryProducerTests {

    @Test("a fragment renders into the proposal's writer")
    func fragment() async throws {
        let recorder = Recorder()
        try await drive(
            responseSender: RecordingSender(recorder: recorder),
            headerFields: [.contentType: "text/html; charset=utf-8"],
            handler: { WireMVCHTMLProducer(div(.class("greeting")) { p { "Hi mom!" } }) },
            errorMapping: { _ in .status(.internalServerError) }
        )

        #expect(recorder.recorded.first == .head(.ok, [.contentType: "text/html; charset=utf-8"]))
        #expect(recorder.body == #"<div class="greeting"><p>Hi mom!</p></div>"#)
        #expect(recorder.recorded.last == .finished(nil))
    }

    @Test("a full document renders, doctype and all")
    func document() async throws {
        let recorder = Recorder()
        let todos = [Todo(id: "a", title: "buy milk"), Todo(id: "b", title: "write codegen")]

        try await drive(
            responseSender: RecordingSender(recorder: recorder),
            headerFields: [.contentType: "text/html; charset=utf-8"],
            handler: { WireMVCHTMLProducer(TodosPage(todos: todos)) },
            errorMapping: { _ in .status(.internalServerError) }
        )

        let html = recorder.body
        #expect(html.hasPrefix("<!DOCTYPE html><html><head>"))
        #expect(html.contains("<title>Todos</title>"))
        #expect(html.contains(#"<li id="a">buy milk</li>"#))
        #expect(html.contains(#"<li id="b">write codegen</li>"#))
        #expect(html.hasSuffix("</body></html>"))
    }

    // ── The point of the whole exercise ──

    @Test("a large page is delivered in chunks, not buffered")
    func chunksIncrementally() async throws {
        let recorder = Recorder()
        let todos = (0..<200).map { Todo(id: "t\($0)", title: "task number \($0)") }

        try await drive(
            responseSender: RecordingSender(recorder: recorder),
            handler: { WireMVCHTMLProducer(TodosPage(todos: todos), chunkSize: 256) },
            errorMapping: { _ in .status(.internalServerError) }
        )

        // Many separate writes reached the peer — the response was streamed, not assembled and sent.
        #expect(recorder.chunks.count > 10)
        // …and reassembling them gives exactly what a buffered render would have produced.
        #expect(recorder.body == TodosPage(todos: todos).render())
    }

    @Test("the head is on the wire while the page is still rendering")
    func headPrecedesBody() async throws {
        let recorder = Recorder()
        let gate = StreamGate()
        let todos = (0..<200).map { Todo(id: "t\($0)", title: "task number \($0)") }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await drive(
                    responseSender: RecordingSender(recorder: recorder),
                    handler: {
                        WireMVCHTMLProducer(
                            div {
                                ul {
                                    for todo in todos {
                                        li(.id(todo.id)) { todo.title }
                                    }
                                }
                                AsyncContent {
                                    let _ = await gate.wait()
                                    p { "late" }
                                }
                            },
                            chunkSize: 256
                        )
                    },
                    errorMapping: { _ in .status(.internalServerError) }
                )
            }

            // Bytes arrive before the gated tail is even computed. A buffering implementation would
            // deadlock here rather than fail.
            while recorder.chunks.isEmpty { await Task.yield() }
            #expect(recorder.recorded.first.map { if case .head = $0 { true } else { false } } == true)
            #expect(!recorder.recorded.contains(.finished(nil)))

            gate.open()
            try await group.waitForAll()
        }

        #expect(recorder.body.hasSuffix("<p>late</p></div>"))
        #expect(recorder.recorded.last == .finished(nil))
    }

    @Test("async content inside the page streams as it resolves")
    func asyncContent() async throws {
        let recorder = Recorder()

        try await drive(
            responseSender: RecordingSender(recorder: recorder),
            handler: {
                WireMVCHTMLProducer(
                    ul {
                        AsyncForEach(AsyncStream(rows: ["alpha", "beta", "gamma"])) { row in
                            li { row }
                        }
                    },
                    chunkSize: 8
                )
            },
            errorMapping: { _ in .status(.internalServerError) }
        )

        #expect(recorder.body == "<ul><li>alpha</li><li>beta</li><li>gamma</li></ul>")
        #expect(recorder.chunks.count > 1)
    }

    // ── Trailers still work through the Elementary path ──

    @Test("trailing fields are delivered after the rendered body")
    func trailers() async throws {
        let recorder = Recorder()
        let trailer: HTTPFields = [.init("x-render")!: "elementary"]

        try await drive(
            responseSender: RecordingSender(recorder: recorder),
            trailer: trailer,
            handler: { WireMVCHTMLProducer(p { "done" }) },
            errorMapping: { _ in .status(.internalServerError) }
        )

        #expect(recorder.body == "<p>done</p>")
        #expect(recorder.recorded.last == .finished(trailer))
    }
}

extension AsyncStream where Element: Sendable {
    fileprivate init(rows: [Element]) {
        self.init { continuation in
            for row in rows { continuation.yield(row) }
            continuation.finish()
        }
    }
}
