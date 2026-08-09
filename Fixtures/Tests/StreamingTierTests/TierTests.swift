import AsyncStreaming
import BasicContainers
import HTTPTypes
import StreamingBodyProducers
import Testing
import WireMVC

// Pins every claim in `Documentation/Notes/StreamingResponseTier.md`. Two of them are *negative* and cannot
// be expressed as tests, because the code would not compile — they are recorded at the bottom of this file
// and re-checked by hand, since a build failure is the assertion.

struct BoomError: Error, Equatable { let message: String }
struct HandlerFailed: Error {}

@Suite("Streaming response tier")
struct TierTests {

    // ── The core claim: the body is written incrementally, not buffered ──

    @Test("chunks reach the peer as separate writes, after the head")
    func incrementalWrites() async throws {
        let recorder = Recorder()
        try await drive(
            responseSender: RecordingSender(recorder: recorder),
            headerFields: [.contentType: "text/html; charset=utf-8"],
            handler: { ChunkProducer(["<html>", "<body>", "hi", "</body></html>"]) },
            errorMapping: { _ in .status(.internalServerError) }
        )

        let events = recorder.recorded
        #expect(events.first == .head(.ok, [.contentType: "text/html; charset=utf-8"]))
        #expect(recorder.chunks == ["<html>", "<body>", "hi", "</body></html>"])
        #expect(events.last == .finished(nil))
        // Four writes, not one — the whole distinction between streaming and buffering.
        #expect(events.filter { if case .chunk = $0 { return true } else { return false } }.count == 4)
    }

    @Test("the head and early bytes are observable while the producer is still running")
    func headPrecedesCompletion() async throws {
        let recorder = Recorder()
        let gate = StreamGate()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await drive(
                    responseSender: RecordingSender(recorder: recorder),
                    handler: { GatedProducer(first: "shell", rest: "tail", gate: gate) },
                    errorMapping: { _ in .status(.internalServerError) }
                )
            }

            // Spin until the first chunk lands. A buffered implementation would never get here — this test
            // would hang rather than fail, which is the point: it cannot pass by accident.
            while recorder.chunks.isEmpty { await Task.yield() }

            #expect(recorder.chunks == ["shell"])
            #expect(!recorder.recorded.contains(.finished(nil)))  // the response is still open
            gate.open()
            try await group.waitForAll()
        }

        #expect(recorder.body == "shelltail")
        #expect(recorder.recorded.last == .finished(nil))
    }

    // ── The error path ──

    @Test("a handler failure before the first byte maps to a buffered outcome")
    func handlerFailureMapsNormally() async throws {
        let recorder = Recorder()
        try await drive(
            responseSender: RecordingSender(recorder: recorder),
            handler: { () async throws -> ChunkProducer in throw HandlerFailed() },
            errorMapping: { _ in .status(.notFound) }
        )

        // Nothing streamed: one buffered send with the mapped status, exactly as a JSON route would do.
        #expect(recorder.recorded == [.head(.notFound, [:]), .finished(nil)])
    }

    @Test("a mid-body failure propagates and aborts the response")
    func midBodyFailureAborts() async throws {
        let recorder = Recorder()
        let boom = BoomError(message: "row 3 exploded")

        await #expect(throws: BoomError.self) {
            try await drive(
                responseSender: RecordingSender(recorder: recorder),
                handler: { FailingProducer(before: ["<html>", "<p>ok</p>"], failure: boom) },
                errorMapping: { _ in .status(.internalServerError) }
            )
        }

        // The head is already out with a 200, so the error cannot become a status — and does not try to.
        #expect(recorder.recorded.first == .head(.ok, [:]))
        #expect(recorder.chunks == ["<html>", "<p>ok</p>"])
        // The writer was dropped without `finish`: the proposal's abort, not a well-formed short response.
        #expect(recorder.recorded.contains(.aborted))
        #expect(!recorder.recorded.contains(.finished(nil)))
    }

    // ── Trailers: where post-head metadata goes ──

    @Test("trailing fields are delivered with the end of the body")
    func trailers() async throws {
        let recorder = Recorder()
        let trailer: HTTPFields = [.init("x-render-ms")!: "12"]

        try await drive(
            responseSender: RecordingSender(recorder: recorder),
            trailer: trailer,
            handler: { ChunkProducer(["a", "b"]) },
            errorMapping: { _ in .status(.internalServerError) }
        )

        #expect(recorder.recorded.last == .finished(trailer))
    }

    // ── The buffered tier is untouched: this is the REAL WireMVCOutcome ──

    @Test("the real WireMVCOutcome still sends head and body in one call")
    func bufferedUnchanged() async throws {
        let recorder = Recorder()
        let outcome = WireMVCOutcome(
            status: .ok,
            headerFields: [.contentType: "application/json"],
            body: Array(#"{"ok":true}"#.utf8)
        )
        try await outcome.send(on: RecordingSender(recorder: recorder))

        #expect(
            recorder.recorded == [
                .head(.ok, [.contentType: "application/json"]),
                .chunk(#"{"ok":true}"#),
                .finished(nil),
            ]
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Non-Sendable bodies need no erasure box: this compiling is the assertion
// ─────────────────────────────────────────────────────────────────────────────

final class NonSendableModel {
    var rows: [String] = ["a", "b"]
}

struct NonSendableProducer: WireMVCBodyProducer {
    let model: NonSendableModel  // rejected outright if `WireMVCBodyProducer` requires `Sendable`

    consuming func writeBody<W: CallerAsyncWriter & ~Copyable & ~Escapable>(
        into writer: consuming W,
        terminatedBy trailer: HTTPFields?
    ) async throws where W.WriteElement == UInt8, W.FinalElement == HTTPFields? {
        var writer = writer
        for row in model.rows {
            var buffer = UniqueArray<UInt8>(copying: Array(row.utf8))
            try await writer.write(buffer: &buffer)
        }
        var end = UniqueArray<UInt8>()
        try await writer.finish(buffer: &end, finalElement: trailer)
    }
}

@Suite("Non-Sendable bodies")
struct NonSendableTests {
    @Test("a producer holding a non-Sendable value streams without an erasure box")
    func nonSendableProducer() async throws {
        let recorder = Recorder()
        try await drive(
            responseSender: RecordingSender(recorder: recorder),
            handler: { NonSendableProducer(model: NonSendableModel()) },
            errorMapping: { _ in .status(.internalServerError) }
        )
        #expect(recorder.chunks == ["a", "b"])
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Negative checks — assertions that a build FAILS, so they cannot live as tests
// ─────────────────────────────────────────────────────────────────────────────
//
// 1. Sending inside the `do` (the shape the design note first proposed):
//
//        do {
//            try await WireMVCStreamingOutcome(status: .ok, producer: try await handler())
//                .send(on: responseSender)
//        } catch {
//            try await errorMapping(error).send(on: responseSender)
//        }
//
//    → error: 'responseSender' consumed more than once
//
//    This is why `wireMVCStreamingTerminal` hoists the send out of the `do`/`catch`. The soundness rule is
//    the ownership checker's, not the design's.
//
// 2. Adding `: Sendable` to `WireMVCBodyProducer`:
//
//    → error: stored property 'model' of 'Sendable'-conforming struct 'NonSendableProducer'
//             has non-Sendable type 'NonSendableModel'
//
//    This is why the protocol has no `Sendable` requirement: the requirement would be the sole reason a
//    non-`Sendable` body needed an erasure box, which is the apparatus it looked like it was protecting
//    against.
//
// Both were checked by temporarily reintroducing them and confirming the failure, then reverting. Re-check
// by hand if the tier's shape changes. NOTE: `swift build`, not `swiftc -typecheck` — the move-only checker
// is a SIL pass, so `-typecheck` accepts (1) silently.
