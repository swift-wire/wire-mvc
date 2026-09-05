// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

import AsyncStreaming
import BasicContainers
import HTTPAPIs
import HTTPTypes
import Synchronization

/// What the peer observed, in order. The point of recording *events* rather than a concatenated body is
/// that "streamed incrementally" and "buffered then sent" produce identical bytes and different event
/// sequences — the distinction the tier exists for.
enum WireEvent: Equatable, Sendable {
    case head(HTTPResponse.Status, HTTPFields)
    case chunk(String)
    case finished(HTTPFields?)
    /// The writer was dropped without `finish` — the proposal's abort signal.
    case aborted
}

final class Recorder: Sendable {
    private let events = Mutex<[WireEvent]>([])

    func record(_ event: WireEvent) { events.withLock { $0.append(event) } }
    var recorded: [WireEvent] { events.withLock { $0 } }

    var chunks: [String] {
        recorded.compactMap { if case let .chunk(text) = $0 { return text } else { return nil } }
    }
    var body: String { chunks.joined() }
}

/// Fires on drop. If `finish` never ran, the response was aborted — which is what the proposal says a
/// dropped writer means, and what a mid-body producer failure must look like on the wire.
private final class CompletionToken {
    let recorder: Recorder
    var finished = false
    init(recorder: Recorder) { self.recorder = recorder }
    deinit { if !finished { recorder.record(.aborted) } }
}

struct RecordingSender: HTTPResponseSender {
    typealias Writer = RecordingWriter

    let recorder: Recorder

    mutating func sendInformational(_ response: HTTPResponse) async throws {}

    consuming func send(_ response: HTTPResponse) async throws -> RecordingWriter {
        recorder.record(.head(response.status, response.headerFields))
        return RecordingWriter(recorder: recorder)
    }

    consuming func sendAndFinish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        _ response: HTTPResponse,
        buffer: inout Buffer,
        trailer: HTTPFields?
    ) async throws where Buffer.Element: ~Copyable {
        recorder.record(.head(response.status, response.headerFields))
        let bytes = drainBytes(&buffer)
        if !bytes.isEmpty { recorder.record(.chunk(String(decoding: bytes, as: UTF8.self))) }
        recorder.record(.finished(trailer))
    }
}

struct RecordingWriter: CallerAsyncWriter {
    typealias WriteElement = UInt8
    typealias WriteFailure = Never
    typealias FinalElement = HTTPFields?

    let recorder: Recorder
    private let token: CompletionToken

    init(recorder: Recorder) {
        self.recorder = recorder
        self.token = CompletionToken(recorder: recorder)
    }

    mutating func write<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer
    ) async throws(Never) where Buffer.Element: ~Copyable {
        let bytes = drainBytes(&buffer)
        if !bytes.isEmpty { recorder.record(.chunk(String(decoding: bytes, as: UTF8.self))) }
    }

    consuming func finish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer,
        finalElement: consuming FinalElement
    ) async throws(Never) where Buffer.Element: ~Copyable {
        let bytes = drainBytes(&buffer)
        if !bytes.isEmpty { recorder.record(.chunk(String(decoding: bytes, as: UTF8.self))) }
        token.finished = true
        recorder.record(.finished(finalElement))
    }
}

func drainBytes<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
    _ buffer: inout Buffer
) -> [UInt8] where Buffer.Element: ~Copyable {
    var bytes: [UInt8] = []
    var consumer = buffer.consumeAll()
    while let byte = consumer.next() { bytes.append(byte) }
    return bytes
}
