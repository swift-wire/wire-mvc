// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import AsyncStreaming
import BasicContainers
import HTTPAPIs
import HTTPTypes
import Synchronization
import Testing
import WireMVC

// `WireMVCResponseSender` over a sender that records exactly what reached it: the head, every body byte,
// whether the response was finished, and its trailer. The server-level behaviour — that a real server then
// frames the response correctly — is pinned over the wire by the fixtures; these pin the wrapper's contract.

private final class HeadRecording: Sendable {
    struct State {
        var head: HTTPResponse?
        var body: [UInt8] = []
        var finished = false
        var trailer: HTTPFields?
    }
    let state = Mutex(State())
}

private struct HeadRecordingWriter: CallerAsyncWriter {
    typealias WriteElement = UInt8
    typealias WriteFailure = Never
    typealias FinalElement = HTTPFields?

    let recording: HeadRecording

    mutating func write<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer
    ) async throws(Never) where Buffer.Element: ~Copyable {
        let bytes = Self.drain(&buffer)
        recording.state.withLock { $0.body += bytes }
    }

    consuming func finish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer,
        finalElement: consuming HTTPFields?
    ) async throws(Never) where Buffer.Element: ~Copyable {
        let bytes = Self.drain(&buffer)
        let trailer = finalElement
        recording.state.withLock {
            $0.body += bytes
            $0.finished = true
            $0.trailer = trailer
        }
    }

    static func drain<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        _ buffer: inout Buffer
    ) -> [UInt8] where Buffer.Element: ~Copyable {
        var bytes: [UInt8] = []
        var consumer = buffer.consumeAll()
        while let byte = consumer.next() { bytes.append(byte) }
        return bytes
    }
}

private struct HeadRecordingSender: HTTPResponseSender {
    typealias Writer = HeadRecordingWriter

    let recording: HeadRecording

    mutating func sendInformational(_ response: HTTPResponse) async throws {}

    consuming func send(_ response: HTTPResponse) async throws -> HeadRecordingWriter {
        recording.state.withLock { $0.head = response }
        return HeadRecordingWriter(recording: recording)
    }

    consuming func sendAndFinish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        _ response: HTTPResponse,
        buffer: inout Buffer,
        trailer: HTTPFields?
    ) async throws where Buffer.Element: ~Copyable {
        let bytes = HeadRecordingWriter.drain(&buffer)
        recording.state.withLock {
            $0.head = response
            $0.body = bytes
            $0.finished = true
            $0.trailer = trailer
        }
    }
}

private func request(_ method: HTTPRequest.Method) -> HTTPRequest {
    HTTPRequest(method: method, scheme: "http", authority: "test", path: "/")
}

private func bytes(_ text: String) -> UniqueArray<UInt8> {
    UniqueArray<UInt8>(copying: Array(text.utf8))
}

@Suite("WireMVCResponseSender — HEAD")
struct HeadResponseTests {
    @Test func aBufferedResponseToHeadKeepsTheHeadAndTheLengthButNotTheBody() async throws {
        let recording = HeadRecording()
        let sender = WireMVCResponseSender(
            wrapping: HeadRecordingSender(recording: recording),
            answering: request(.head)
        )
        var body = bytes(#"{"message":"hi"}"#)
        try await sender.sendAndFinish(
            HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
            buffer: &body,
            trailer: nil
        )
        let state = recording.state.withLock { $0 }
        #expect(state.head?.status == .ok)
        #expect(state.head?.headerFields[.contentType] == "application/json")
        #expect(state.head?.headerFields[.contentLength] == "16")
        #expect(state.body.isEmpty)
        #expect(state.finished)
    }

    @Test func aStatedLengthIsKeptRatherThanReplaced() async throws {
        // A route answering `HEAD` itself states the `GET`'s length over an empty buffer.
        let recording = HeadRecording()
        let sender = WireMVCResponseSender(
            wrapping: HeadRecordingSender(recording: recording),
            answering: request(.head)
        )
        var nothing = UniqueArray<UInt8>()
        try await sender.sendAndFinish(
            HTTPResponse(status: .ok, headerFields: [.contentLength: "4096"]),
            buffer: &nothing,
            trailer: nil
        )
        #expect(recording.state.withLock { $0.head?.headerFields[.contentLength] } == "4096")
    }

    @Test func aBufferedResponseWithATrailerStatesNoLength() async throws {
        // A `GET` with a trailer is chunked and states no length, so its `HEAD` must not claim one.
        let recording = HeadRecording()
        let sender = WireMVCResponseSender(
            wrapping: HeadRecordingSender(recording: recording),
            answering: request(.head)
        )
        var body = bytes("abc")
        try await sender.sendAndFinish(HTTPResponse(status: .ok), buffer: &body, trailer: [.eTag: "\"t\""])
        let state = recording.state.withLock { $0 }
        #expect(state.head?.headerFields[.contentLength] == nil)
        #expect(state.body.isEmpty)
        #expect(state.trailer == nil)
    }

    @Test func aStreamedResponseToHeadSendsTheHeadAndFinishesWithNothing() async throws {
        let recording = HeadRecording()
        let sender = WireMVCResponseSender(
            wrapping: HeadRecordingSender(recording: recording),
            answering: request(.head)
        )
        var writer = try await sender.send(HTTPResponse(status: .ok, headerFields: [.contentType: "text/html"]))
        var chunk = bytes("<p>one</p>")
        try await writer.write(buffer: &chunk)
        let drained = chunk.isEmpty
        #expect(drained)
        var last = bytes("<p>two</p>")
        try await writer.finish(buffer: &last, finalElement: [.eTag: "\"t\""])
        let state = recording.state.withLock { $0 }
        #expect(state.head?.headerFields[.contentType] == "text/html")
        #expect(state.body.isEmpty)
        #expect(state.finished)
        #expect(state.trailer == nil)
    }

    @Test(arguments: [HTTPRequest.Method.get, .post, .delete])
    func anyOtherMethodPassesEverythingThrough(_ method: HTTPRequest.Method) async throws {
        let recording = HeadRecording()
        let sender = WireMVCResponseSender(
            wrapping: HeadRecordingSender(recording: recording),
            answering: request(method)
        )
        var writer = try await sender.send(HTTPResponse(status: .ok))
        var chunk = bytes("one")
        try await writer.write(buffer: &chunk)
        var last = bytes("two")
        try await writer.finish(buffer: &last, finalElement: [.eTag: "\"t\""])
        let state = recording.state.withLock { $0 }
        #expect(state.body == Array("onetwo".utf8))
        #expect(state.trailer?[.eTag] == "\"t\"")
    }

    @Test func aBufferedResponseToAnotherMethodIsUnchanged() async throws {
        let recording = HeadRecording()
        let sender = WireMVCResponseSender(
            wrapping: HeadRecordingSender(recording: recording),
            answering: request(.get)
        )
        var body = bytes("abc")
        try await sender.sendAndFinish(HTTPResponse(status: .ok), buffer: &body, trailer: nil)
        let state = recording.state.withLock { $0 }
        #expect(state.body == Array("abc".utf8))
        // Not this wrapper's to state: the length rule belongs to whoever builds the response.
        #expect(state.head?.headerFields[.contentLength] == nil)
    }
}
