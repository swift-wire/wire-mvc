// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import AsyncStreaming
import BasicContainers
import HTTPAPIs
import HTTPTypes
import Testing

@testable import WireMVC

// A request body held to a limit: the 413 a body over it gets, the `Content-Length` check that refuses one
// before a byte is read, and the reader that holds a streamed binding to a route's limit. Every reader here
// counts its reads, because "refused without reading" is a claim about reads, and a status alone cannot show
// it.

/// How often a ``ChunkedReader`` was read. A class, so the test can see it after the `consuming` reader has
/// gone.
private final class ReadCount: @unchecked Sendable {
    var reads = 0
}

private struct ReaderBroke: Error {}

/// A reader that hands out one chunk per read, the last with the end of the body — or fails on the read
/// after the last chunk when `failing`.
private struct ChunkedReader: AsyncReader, ~Copyable {
    typealias ReadElement = UInt8
    typealias ReadFailure = ReaderBroke
    typealias FinalElement = HTTPFields?
    typealias Buffer = UniqueArray<UInt8>

    var chunks: [[UInt8]]
    let count: ReadCount
    var failing = false

    init(_ chunks: [[UInt8]], count: ReadCount = ReadCount(), failing: Bool = false) {
        self.chunks = chunks
        self.count = count
        self.failing = failing
    }

    mutating func read<Return: ~Copyable, Failure: Error>(
        body: (inout Buffer, consuming FinalElement?) async throws(Failure) -> Return
    ) async throws(EitherError<ReaderBroke, Failure>) -> Return {
        count.reads += 1
        if chunks.isEmpty, failing { throw .first(ReaderBroke()) }
        let chunk = chunks.isEmpty ? [] : chunks.removeFirst()
        var buffer = UniqueArray<UInt8>(copying: chunk)
        let final: HTTPFields?? = chunks.isEmpty && !failing ? .some(nil) : nil
        do throws(Failure) {
            return try await body(&buffer, final)
        } catch {
            throw .second(error)
        }
    }
}

private func request(contentLength: String? = nil) -> HTTPRequest {
    var fields = HTTPFields()
    if let contentLength { fields[.contentLength] = contentLength }
    return HTTPRequest(method: .put, scheme: "http", authority: "test", path: "/upload", headerFields: fields)
}

private func isTooLarge(_ error: any Error, limit: Int) -> Bool {
    if case .bodyTooLarge(let maximumSize) = error as? WireMVCBindingError { return maximumSize == limit }
    return false
}

@Suite("Request body limits")
struct RequestBodyLimitTests {

    // MARK: - The status

    /// 413, not 422: a body can be well-formed and still too long, and the two ask the client for different
    /// things.
    @Test func aBodyTooLargeIs413() {
        #expect(WireMVCBindingError.bodyTooLarge(maximumSize: 10).status == .contentTooLarge)
        #expect(WireMVCBindingError.malformedBody.status == .unprocessableContent)
    }

    // MARK: - Collecting

    @Test func aBodyWithinTheLimitIsCollectedWhole() async throws {
        let bytes = try await WireMVCRequest.collectBody(ChunkedReader([[1, 2, 3], [4, 5]]), maximumSize: 5)
        #expect(bytes == [1, 2, 3, 4, 5], "exactly the limit is within it")
    }

    /// The defect: this was `malformedBody`, so a client sending too much was told its body was malformed.
    @Test func aBodyOverTheLimitIsTooLargeNotMalformed() async {
        await #expect {
            _ = try await WireMVCRequest.collectBody(ChunkedReader([[1, 2, 3], [4, 5, 6]]), maximumSize: 5)
        } throws: { isTooLarge($0, limit: 5) }
    }

    /// A reader that fails for any other reason is still `malformedBody` — the limit is the one cause split
    /// out, because it is the one that asks something different of the client.
    @Test func aReaderFailureIsStillMalformed() async {
        await #expect {
            _ = try await WireMVCRequest.collectBody(ChunkedReader([[1]], failing: true), maximumSize: 5)
        } throws: { ($0 as? WireMVCBindingError).map { if case .malformedBody = $0 { true } else { false } } ?? false }
    }

    /// The claim the collecting terminals rely on: a `Content-Length` over the limit is refused **before a
    /// read**, so a server does not take 25 MB to refuse it.
    @Test func aDeclaredLengthOverTheLimitIsRefusedWithoutReadingTheBody() async {
        let count = ReadCount()
        await #expect {
            _ = try await WireMVCRequest.collectBody(
                of: request(contentLength: "26214400"),
                from: ChunkedReader([[1]], count: count),
                maximumSize: 1024
            )
        } throws: { isTooLarge($0, limit: 1024) }
        #expect(count.reads == 0)
    }

    /// The field is a claim, not a promise: a body within its stated length is still held to the limit as it
    /// is read, and a length that is not a number is left to the read rather than refused here.
    @Test func theDeclaredLengthOnlyRefusesWhatItClaims() throws {
        try WireMVCRequest.refuseDeclaredLength(of: request(), over: 10)
        try WireMVCRequest.refuseDeclaredLength(of: request(contentLength: "10"), over: 10)
        try WireMVCRequest.refuseDeclaredLength(of: request(contentLength: "lots"), over: 10)
        #expect(throws: WireMVCBindingError.self) {
            try WireMVCRequest.refuseDeclaredLength(of: request(contentLength: "11"), over: 10)
        }
    }

    // MARK: - The collecting terminal

    /// Through the generated terminal: the refusal maps to 413 through the builtin binding mapping, the
    /// handler never runs, and the reader is never read.
    @Test func theCollectingTerminalAnswers413WithoutReading() async throws {
        let count = ReadCount()
        let record = RecordedResponse()
        var handlerRan = false
        try await wireMVCBufferedTerminal(
            responseSender: RecordingSender(record: record),
            responseHeaders: ResponseHeaderRegistry(),
            collectingBodyFrom: ChunkedReader([[1, 2, 3]], count: count),
            request: request(contentLength: "5000"),
            maximumBodySize: 100,
            building: { _ in
                handlerRan = true
                return .status(.ok)
            },
            errorMapping: { error in .status((error as? WireMVCBindingError)?.status ?? .internalServerError) }
        )
        #expect(record.head?.status == .contentTooLarge)
        #expect(!handlerRan)
        #expect(count.reads == 0)
    }

    // MARK: - Streaming

    /// `streamBody` had the same defect as `collectBody`.
    @Test func streamBodyOverItsLimitIsTooLarge() async {
        var total = 0
        await #expect {
            let reader = ChunkedReader([[1, 2], [3, 4]])
            try await WireMVCRequest.streamBody(reader, into: &total, maximumSize: 3) { total, span in
                total += span.count
            }
        } throws: { isTooLarge($0, limit: 3) }
        #expect(total == 2, "the chunk that crossed the limit was not handed on")
    }

    @Test func theBoundedReaderPassesABodyWithinItsLimit() async throws {
        var total = 0
        let reader = WireMVCBoundedReader(ChunkedReader([[1, 2], [3]]), maximumSize: 3)
        try await WireMVCRequest.streamBody(reader, into: &total) { total, span in total += span.count }
        #expect(total == 3)
    }

    /// The route's limit beats a looser one the binding sets for itself — and reaches the terminal as a
    /// `WireMVCBindingError`, unwrapped, which is what lets it map to 413 rather than an unmappable 500.
    @Test func theBoundedReaderEndsABodyAtTheRoutesLimit() async {
        var total = 0
        await #expect {
            let reader = WireMVCBoundedReader(ChunkedReader([[1, 2], [3, 4]]), maximumSize: 3)
            try await WireMVCRequest.streamBody(reader, into: &total, maximumSize: 1_000) { total, span in
                total += span.count
            }
        } throws: { isTooLarge($0, limit: 3) }
    }

    /// An error the binding's own closure throws passes through the bounded reader unchanged, on the side it
    /// was thrown from — the reader only adds the limit, it does not take the binding's vocabulary away.
    @Test func theBoundedReaderPassesTheBindingsOwnErrorsThrough() async {
        struct Refused: Error {}
        await #expect {
            var reader = WireMVCBoundedReader(ChunkedReader([[1, 2]]), maximumSize: 10)
            try await reader.read { (_, _) async throws(Refused) in throw Refused() }
        } throws: { error in
            if case .second = error as? EitherError<any Error, Refused> { return true }
            return false
        }
    }
}
