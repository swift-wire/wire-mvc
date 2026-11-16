// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Foundation
import HTTPTypes
import Testing
import WireMVCTesting

@testable import WireMVCBootstrapExample

// `@FileResponse` over real HTTP, on the harness-owned `NIOHTTPServer`. What is proved here is that the
// generated terminal, the file's own head, the route's header tiers and the proposal's body writer compose
// into a correctly framed response: the right status, the right bytes, and a `Content-Length` that matches
// what arrived.

private func expected(_ range: ClosedRange<Int>) -> Data {
    Data(FileFixture.bytes[range])
}

@Suite(.wiremvc(.swiftHttpServer))
struct FileResponseOverTheWireTests {

    @Test func servesTheWholeFile() async throws {
        try await withClient { client in
            let response = try await client.get("/files/sample.txt")
            #expect(response.status == 200)
            let fields = try #require(response.head?.headerFields)
            #expect(fields[.contentType] == "text/plain; charset=utf-8")
            #expect(fields[.contentLength] == "1000")
            #expect(fields[.acceptRanges] == "bytes")
            #expect(fields[.eTag]?.hasPrefix("\"") == true)
            #expect(fields[.lastModified]?.hasSuffix(" GMT") == true)
            #expect(fields[.contentRange] == nil)
            #expect(response.body == Data(FileFixture.bytes))
        }
    }

    @Test func servesOneRangeAsPartialContent() async throws {
        try await withClient { client in
            let response = try await client.get("/files/sample.txt", headers: ["Range": "bytes=100-299"])
            #expect(response.status == 206)
            let fields = try #require(response.head?.headerFields)
            #expect(fields[.contentRange] == "bytes 100-299/1000")
            #expect(fields[.contentLength] == "200")
            #expect(response.body == expected(100...299))
        }
    }

    /// A suffix range, and an open-ended one past what a chunk holds: both read across several chunks.
    @Test func servesSuffixAndOpenRanges() async throws {
        try await withClient { client in
            let suffix = try await client.get("/files/sample.txt", headers: ["Range": "bytes=-300"])
            #expect(suffix.status == 206)
            #expect(suffix.head?.headerFields[.contentRange] == "bytes 700-999/1000")
            #expect(suffix.body == expected(700...999))

            let open = try await client.get("/files/sample.txt", headers: ["Range": "bytes=990-"])
            #expect(open.status == 206)
            #expect(open.head?.headerFields[.contentLength] == "10")
            #expect(open.body == expected(990...999))
        }
    }

    @Test func anUnsatisfiableRangeIs416() async throws {
        try await withClient { client in
            let response = try await client.get("/files/sample.txt", headers: ["Range": "bytes=1000-"])
            #expect(response.status == 416)
            let fields = try #require(response.head?.headerFields)
            #expect(fields[.contentRange] == "bytes */1000")
            #expect(response.body.isEmpty)
        }
    }

    /// Several ranges, or a malformed one, are ignored rather than refused: the whole file, `200`.
    @Test func multipleOrMalformedRangesServeTheWholeFile() async throws {
        try await withClient { client in
            for field in ["bytes=0-1,5-6", "bytes=9-3", "items=0-1"] {
                let response = try await client.get("/files/sample.txt", headers: ["Range": field])
                #expect(response.status == 200, "\(field)")
                #expect(response.body.count == 1000, "\(field)")
            }
        }
    }

    /// `If-Range` with this file's own validator applies the range; with any other, the whole file.
    @Test func ifRangeDecidesWhetherTheRangeApplies() async throws {
        try await withClient { client in
            let whole = try await client.get("/files/sample.txt")
            let etag = try #require(whole.head?.headerFields[.eTag])
            let lastModified = try #require(whole.head?.headerFields[.lastModified])

            for validator in [etag, lastModified] {
                let matched = try await client.get(
                    "/files/sample.txt",
                    headers: ["Range": "bytes=0-9", "If-Range": validator]
                )
                #expect(matched.status == 206, "\(validator)")
                #expect(matched.body == expected(0...9))
            }

            for stale in ["\"0-0.0\"", "W/\(etag)", "Thu, 01 Jan 1970 00:00:00 GMT"] {
                let mismatched = try await client.get(
                    "/files/sample.txt",
                    headers: ["Range": "bytes=0-9", "If-Range": stale]
                )
                #expect(mismatched.status == 200, "\(stale)")
                #expect(mismatched.body.count == 1000)
            }
        }
    }

    /// A missing file throws from the `WireMVCFile` initialiser, before the head, so `@ErrorResponse` maps it.
    @Test func aMissingFileMapsTo404() async throws {
        try await withClient { client in
            let response = try await client.get("/files/missing.txt")
            #expect(response.status == 404)
            #expect(response.body.isEmpty)
        }
    }

    /// Route constants fold under the file's head: `Cache-Control` survives, and a route-named `Content-Type`
    /// beats the file's seeded one. Middleware does too — `AccessLog`'s global `x-served-by`.
    @Test func routeAndMiddlewareFieldsFoldUnderTheFileHead() async throws {
        try await withClient { client in
            let response = try await client.get("/files/cached/sample.txt")
            #expect(response.status == 200)
            let fields = try #require(response.head?.headerFields)
            #expect(fields[.cacheControl] == "max-age=60")
            #expect(fields[.contentType] == "application/octet-stream")
            #expect(fields[.contentLength] == "1000")
            #expect(fields[.init("x-served-by")!] == "wire-mvc")
        }
    }

    /// The response tuple: a returned status answers a whole file, a range's `206` replaces it, and a
    /// returned `Content-Length` is replaced by the file's — while the handler's own field survives.
    @Test func aResponseTupleFoldsUnderTheFileHead() async throws {
        try await withClient { client in
            let whole = try await client.get("/files/tagged/sample.txt")
            #expect(whole.status == 203)
            #expect(whole.head?.headerFields[.contentLength] == "1000")
            #expect(whole.head?.headerFields[.init("x-file")!] == "sample.txt")
            #expect(whole.body.count == 1000)

            let part = try await client.get("/files/tagged/sample.txt", headers: ["Range": "bytes=0-4"])
            #expect(part.status == 206)
            #expect(part.head?.headerFields[.contentLength] == "5")
            #expect(part.body == expected(0...4))
        }
    }
}

/// The generated typed client hands a `@FileResponse` route's whole response back, because a file's head
/// says as much as its bytes.
@Suite(.wiremvc(.swiftHttpServer))
struct FileResponseTypedClientTests {

    @Test func theClientHandsBackTheWholeResponse() async throws {
        try await withClient(for: FilesControllerClient.self) { files in
            let response = try await files.file(name: "sample.txt", range: "bytes=10-19", ifRange: nil)
            #expect(response.status == 206)
            #expect(response.head?.headerFields[.contentRange] == "bytes 10-19/1000")
            #expect(response.body == expected(10...19))
        }
    }

    @Test func anUnsatisfiableRangeThrowsLikeAnyRefusal() async throws {
        try await withClient(for: FilesControllerClient.self) { files in
            let error = try await #require(throws: WireMVCRouteError.self) {
                try await files.file(name: "sample.txt", range: "bytes=5000-", ifRange: nil)
            }
            #expect(error.status == .rangeNotSatisfiable)
        }
    }
}
