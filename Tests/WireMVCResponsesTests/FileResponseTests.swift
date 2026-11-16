// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import AsyncStreaming
import BasicContainers
import Foundation
import HTTPAPIs
import HTTPTypes
import Testing

@testable import WireMVC

// The file response, below the route: what a `Range` field resolves to, what `If-Range` decides, the head a
// file states, and what reaches the wire when the producer runs. The generated route is pinned over real
// HTTP by the fixtures' `FileResponseOverTheWireTests`.

@Suite("Byte range resolution")
struct ByteRangeTests {
    private func resolve(_ field: String?, _ size: Int64 = 1000) -> WireMVCByteRange {
        WireMVCByteRange.resolve(rangeField: field, size: size)
    }

    @Test func noFieldIsTheWholeRepresentation() {
        #expect(resolve(nil) == .whole)
    }

    @Test func aClosedRange() {
        #expect(resolve("bytes=0-499") == .part(first: 0, last: 499))
        #expect(resolve("bytes=500-999") == .part(first: 500, last: 999))
        #expect(resolve("bytes=7-7") == .part(first: 7, last: 7))
    }

    @Test func anOpenRangeRunsToTheEnd() {
        #expect(resolve("bytes=900-") == .part(first: 900, last: 999))
    }

    @Test func aLastPositionPastTheEndIsClamped() {
        #expect(resolve("bytes=900-5000") == .part(first: 900, last: 999))
    }

    @Test func aSuffixRange() {
        #expect(resolve("bytes=-100") == .part(first: 900, last: 999))
        // Longer than the representation: all of it, still as a part.
        #expect(resolve("bytes=-5000") == .part(first: 0, last: 999))
    }

    @Test func unsatisfiableRanges() {
        #expect(resolve("bytes=1000-") == .unsatisfiable)
        #expect(resolve("bytes=1000-2000") == .unsatisfiable)
        #expect(resolve("bytes=-0") == .unsatisfiable)
        // An empty representation satisfies no range at all.
        #expect(resolve("bytes=0-", 0) == .unsatisfiable)
        #expect(resolve("bytes=-1", 0) == .unsatisfiable)
    }

    /// A malformed field is ignored, not refused: §14.2 lets a server ignore `Range`, and §14.1.1 calls a
    /// `last-pos` below `first-pos` invalid rather than unsatisfiable.
    @Test func malformedFieldsAreIgnored() {
        for field in ["bytes=9-3", "bytes=a-b", "bytes=-", "bytes=1-2-3", "bytes", "bytes=+1-2", "bytes=1 -2", ""] {
            #expect(resolve(field) == .whole, "\(field)")
        }
    }

    @Test func otherUnitsAreIgnored() {
        #expect(resolve("items=0-1") == .whole)
    }

    @Test func theUnitIsCaseInsensitiveAndWhitespaceIsOptional() {
        #expect(resolve("Bytes=0-1") == .part(first: 0, last: 1))
        #expect(resolve("bytes= 0-1 ") == .part(first: 0, last: 1))
        // An empty list element carries nothing.
        #expect(resolve("bytes=0-1, ") == .part(first: 0, last: 1))
    }

    /// Several ranges are a `multipart/byteranges` body, which is not offered: the whole file instead.
    @Test func severalRangesAreTheWholeRepresentation() {
        #expect(resolve("bytes=0-1,5-6") == .whole)
    }

    /// A position too large to represent is past the end of any file, which is what it should mean.
    @Test func hugePositionsSaturate() {
        #expect(resolve("bytes=99999999999999999999999-") == .unsatisfiable)
        #expect(resolve("bytes=0-99999999999999999999999") == .part(first: 0, last: 999))
        #expect(resolve("bytes=-99999999999999999999999") == .part(first: 0, last: 999))
    }
}

@Suite("HTTP-date and validators")
struct FileValidatorTests {
    @Test func formatsIMFFixdate() {
        #expect(WireMVCHTTPDate.format(secondsSinceEpoch: 0) == "Thu, 01 Jan 1970 00:00:00 GMT")
        // RFC 9110 §5.6.7's own example.
        #expect(WireMVCHTTPDate.format(secondsSinceEpoch: 784_111_777) == "Sun, 06 Nov 1994 08:49:37 GMT")
        // A leap day, and a date past 2038.
        #expect(WireMVCHTTPDate.format(secondsSinceEpoch: 951_782_400) == "Tue, 29 Feb 2000 00:00:00 GMT")
        #expect(WireMVCHTTPDate.format(secondsSinceEpoch: 4_102_444_800) == "Fri, 01 Jan 2100 00:00:00 GMT")
        // Before the epoch.
        #expect(WireMVCHTTPDate.format(secondsSinceEpoch: -1) == "Wed, 31 Dec 1969 23:59:59 GMT")
    }

    @Test func theEntityTagIsStrongAndChangesWithTheFile() {
        let tag = WireMVCFile.entityTag(size: 1000, seconds: 1_700_000_000, nanoseconds: 5)
        #expect(tag == "\"3e8-6553f100.5\"")
        #expect(tag != WireMVCFile.entityTag(size: 1000, seconds: 1_700_000_000, nanoseconds: 6))
        #expect(tag != WireMVCFile.entityTag(size: 1001, seconds: 1_700_000_000, nanoseconds: 5))
    }

    @Test func ifRangeMatchesTheSameEntityTagOrDateOnly() {
        let tag = "\"3e8-1.0\""
        let date = "Thu, 01 Jan 1970 00:00:01 GMT"
        #expect(WireMVCFile.matches(ifRange: tag, entityTag: tag, lastModified: date))
        #expect(WireMVCFile.matches(ifRange: " \(date) ", entityTag: tag, lastModified: date))
        #expect(!WireMVCFile.matches(ifRange: "\"other\"", entityTag: tag, lastModified: date))
        // Strong comparison: a weak tag never matches, even one naming the same opaque value.
        #expect(!WireMVCFile.matches(ifRange: "W/\(tag)", entityTag: tag, lastModified: date))
        #expect(!WireMVCFile.matches(ifRange: "Thu, 01 Jan 1970 00:00:02 GMT", entityTag: tag, lastModified: date))
    }
}

/// A scratch file holding a known pattern, removed when the test ends.
private struct ScratchFile: ~Copyable {
    let path: String
    let bytes: [UInt8]

    init(size: Int) throws {
        bytes = (0..<size).map { UInt8(ascii: "A") + UInt8($0 % 26) }
        path =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("wire-mvc-file-\(UUID().uuidString)").path
        try Data(bytes).write(to: URL(fileURLWithPath: path))
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }
}

@Suite("File head and body")
struct FileProducerTests {

    @Test func aMissingFileThrowsNotFound() {
        #expect(throws: WireMVCFileError.notFound(path: "/no/such/file")) {
            try WireMVCFile(path: "/no/such/file", contentType: "text/plain")
        }
    }

    @Test func aDirectoryIsNotAFile() {
        let directory = FileManager.default.temporaryDirectory.path
        #expect(throws: WireMVCFileError.notFound(path: directory)) {
            try WireMVCFile(path: directory, contentType: "text/plain")
        }
    }

    @Test func aNonFileURLIsNotFound() {
        let url = URL(string: "https://example.com/x")!
        #expect(throws: WireMVCFileError.notFound(path: url.absoluteString)) {
            try WireMVCFile(url: url, contentType: "text/plain")
        }
    }

    @Test func theWholeFileLeavesTheStatusToTheRoute() throws {
        let scratch = try ScratchFile(size: 300)
        let file = try WireMVCFile(path: scratch.path, contentType: "text/plain")
        let head = file.head
        #expect(head.status == nil)
        #expect(head.headerFields[.contentLength] == "300")
        #expect(head.headerFields[.acceptRanges] == "bytes")
        #expect(head.headerFields[.eTag] == file.entityTag)
        #expect(head.headerFields[.lastModified] == file.lastModified)
        #expect(head.headerFields[.contentRange] == nil)
    }

    @Test func aPartStates206AndItsRange() throws {
        let scratch = try ScratchFile(size: 300)
        let file = try WireMVCFile(path: scratch.path, contentType: "text/plain", range: "bytes=10-19")
        #expect(file.head.status == .partialContent)
        #expect(file.head.headerFields[.contentRange] == "bytes 10-19/300")
        #expect(file.head.headerFields[.contentLength] == "10")
    }

    @Test func anUnsatisfiableRangeStates416AndNoContentType() throws {
        let scratch = try ScratchFile(size: 300)
        let file = try WireMVCFile(path: scratch.path, contentType: "text/plain", range: "bytes=300-")
        #expect(file.head.status == .rangeNotSatisfiable)
        #expect(file.head.headerFields[.contentRange] == "bytes */300")
        #expect(file.head.headerFields[.contentLength] == "0")
        #expect(WireMVCFileProducer(file).contentType == nil)
    }

    @Test func aStaleIfRangeSendsTheWholeFile() throws {
        let scratch = try ScratchFile(size: 300)
        let file = try WireMVCFile(
            path: scratch.path,
            contentType: "text/plain",
            range: "bytes=0-9",
            ifRange: "\"stale\""
        )
        #expect(file.range == .whole)
        let current = try WireMVCFile(
            path: scratch.path,
            contentType: "text/plain",
            range: "bytes=0-9",
            ifRange: file.entityTag
        )
        #expect(current.range == .part(first: 0, last: 9))
    }

    /// Over the shipped outcome: the file's head wins over the route's status and its framing fields, its
    /// content type is seeded, a route field it does not name survives, and the bytes arrive in order.
    @Test func theOutcomeSendsTheFilesHeadAndItsBytes() async throws {
        let scratch = try ScratchFile(size: 1000)
        let file = try WireMVCFile(path: scratch.path, contentType: "text/plain", range: "bytes=100-899", chunkSize: 64)
        let record = RecordedResponse()
        let outcome = WireMVCStreamingOutcome(
            status: .ok,
            headerFields: [.contentLength: "1", .cacheControl: "no-store"],
            producer: WireMVCFileProducer(file)
        )
        try await outcome.send(on: RecordingSender(record: record))

        let head = try #require(record.head)
        #expect(head.status == .partialContent)
        #expect(head.headerFields[.contentLength] == "800")
        #expect(head.headerFields[values: .contentLength].count == 1, "the file's length replaces the route's")
        #expect(head.headerFields[.cacheControl] == "no-store")
        #expect(head.headerFields[.contentType] == "text/plain")
        #expect(record.body == Array(scratch.bytes[100...899]))
    }

    /// A route naming its own content type keeps it — the media type is the author's to restate.
    @Test func aRouteContentTypeBeatsTheFiles() async throws {
        let scratch = try ScratchFile(size: 10)
        let file = try WireMVCFile(path: scratch.path, contentType: "text/plain")
        let record = RecordedResponse()
        let outcome = WireMVCStreamingOutcome(
            status: .ok,
            headerFields: [.contentType: "application/octet-stream"],
            producer: WireMVCFileProducer(file)
        )
        try await outcome.send(on: RecordingSender(record: record))
        #expect(record.head?.headerFields[.contentType] == "application/octet-stream")
        #expect(record.body == scratch.bytes)
    }

    /// A file that shrinks after its head is built cannot keep the length the head promised, so the body
    /// throws rather than finishing short.
    @Test func aFileThatShrinksAbortsTheBody() async throws {
        let scratch = try ScratchFile(size: 1000)
        let file = try WireMVCFile(path: scratch.path, contentType: "text/plain", chunkSize: 100)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: scratch.path))
        try handle.truncate(atOffset: 250)
        try handle.close()

        let record = RecordedResponse()
        let outcome = WireMVCStreamingOutcome(status: .ok, producer: WireMVCFileProducer(file))
        await #expect(throws: WireMVCFileError.truncated(path: scratch.path)) {
            try await outcome.send(on: RecordingSender(record: record))
        }
        #expect(record.body.count == 250)
    }

    /// The descriptor opened at construction is the one read, so a file unlinked in between is still sent.
    @Test func anUnlinkedFileIsStillTheOneSent() async throws {
        let scratch = try ScratchFile(size: 50)
        let file = try WireMVCFile(path: scratch.path, contentType: "text/plain")
        try FileManager.default.removeItem(atPath: scratch.path)

        let record = RecordedResponse()
        try await WireMVCStreamingOutcome(status: .ok, producer: WireMVCFileProducer(file))
            .send(on: RecordingSender(record: record))
        #expect(record.body == scratch.bytes)
    }
}

@Suite("Body head precedence")
struct BodyHeadTests {
    @Test func theRouteHeadStandsWhenTheBodySaysNothing() {
        let applied = WireMVCBodyHead.route.applied(over: .created, [.cacheControl: "no-store"])
        #expect(applied.status == .created)
        #expect(applied.headerFields == [.cacheControl: "no-store"])
    }

    @Test func aStatedStatusAndFieldsWin() {
        var routeFields: HTTPFields = [.cacheControl: "no-store"]
        routeFields.append(HTTPField(name: .eTag, value: "\"a\""))
        routeFields.append(HTTPField(name: .eTag, value: "\"b\""))
        let head = WireMVCBodyHead(status: .partialContent, headerFields: [.eTag: "\"file\""])
        let applied = head.applied(over: .ok, routeFields)
        #expect(applied.status == .partialContent)
        #expect(applied.headerFields[values: .eTag] == ["\"file\""], "every line of a stated name goes")
        #expect(applied.headerFields[.cacheControl] == "no-store")
    }

    /// A producer that does not implement `head` — every one written before it existed — leaves the route's.
    @Test func theDefaultIsTheRoutes() {
        struct Silent: WireMVCBodyProducer {
            consuming func writeBody<W: CallerAsyncWriter & ~Copyable & ~Escapable>(
                into writer: consuming W,
                terminatedBy trailer: HTTPFields?
            ) async throws where W.WriteElement == UInt8, W.FinalElement == HTTPFields? {
                var end = UniqueArray<UInt8>()
                try await writer.finish(buffer: &end, finalElement: trailer)
            }
        }
        #expect(Silent().head == .route)
    }
}
