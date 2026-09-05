// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import AsyncStreaming
import BasicContainers
import HTTPAPIs
import HTTPTypes
import Testing
import WireMVC
import WireMVCRouter

// The synthesised `404` and `405` are the two responses the router writes itself, without going through a
// `WireMVCOutcome`. They are bodiless, which is not the same as lengthless: a miss with nothing to say
// still has a known length, and leaving it unstated frames it as chunked exactly as a body would be.

private final class RecordedHead: @unchecked Sendable {
    var head: HTTPResponse?
}

private struct MissRequestContext: HTTPServerCapability.RequestContext {
    init() {}
}

private struct MissReader: AsyncReader {
    typealias ReadElement = UInt8
    typealias ReadFailure = Never
    typealias FinalElement = HTTPFields?
    typealias Buffer = UniqueArray<UInt8>

    mutating func read<Return: ~Copyable, Failure: Error>(
        body: (inout Buffer, consuming FinalElement?) async throws(Failure) -> Return
    ) async throws(EitherError<ReadFailure, Failure>) -> Return {
        var buffer = UniqueArray<UInt8>()
        do {
            return try await body(&buffer, .some(nil))
        } catch {
            throw EitherError.second(error)
        }
    }
}

private struct MissWriter: CallerAsyncWriter {
    typealias WriteElement = UInt8
    typealias WriteFailure = Never
    typealias FinalElement = HTTPFields?

    mutating func write<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer
    ) async throws(Never) where Buffer.Element: ~Copyable {}

    consuming func finish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer,
        finalElement: consuming FinalElement
    ) async throws(Never) where Buffer.Element: ~Copyable {}
}

private struct MissSender: HTTPResponseSender {
    typealias Writer = MissWriter

    let record: RecordedHead

    mutating func sendInformational(_ response: HTTPResponse) async throws {}

    consuming func send(_ response: HTTPResponse) async throws -> MissWriter {
        record.head = response
        return MissWriter()
    }

    consuming func sendAndFinish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        _ response: HTTPResponse,
        buffer: inout Buffer,
        trailer: HTTPFields?
    ) async throws where Buffer.Element: ~Copyable {
        record.head = response
    }
}

/// A router with one `GET /users` route, so a `POST` misses on method and `/nope` misses on path.
private func router() -> FrozenTrieRouter<MissRequestContext, MissReader, MissSender> {
    var builder = TrieRouteBuilder<MissRequestContext, MissReader, MissSender>()
    builder.register(method: .get, path: "/users") { _, _, _, _, _ in }
    return builder.finalize()
}

private func head(for method: HTTPRequest.Method, path: String) async throws -> HTTPResponse? {
    let record = RecordedHead()
    try await router().handle(
        request: HTTPRequest(method: method, scheme: "http", authority: "test", path: path),
        requestContext: MissRequestContext(),
        reader: MissReader(),
        responseSender: MissSender(record: record)
    )
    return record.head
}

@Suite("Synthesised miss framing")
struct SynthesisedMissFramingTests {
    @Test
    func synthesisedNotFoundStatesZeroLength() async throws {
        let response = try await head(for: .get, path: "/nope")
        #expect(response?.status == .notFound)
        #expect(response?.headerFields[.contentLength] == "0")
    }

    @Test
    func synthesisedMethodNotAllowedStatesZeroLengthBesideAllow() async throws {
        let response = try await head(for: .post, path: "/users")
        #expect(response?.status == .methodNotAllowed)
        #expect(response?.headerFields[.allow] == "GET")
        #expect(response?.headerFields[.contentLength] == "0")
    }
}
