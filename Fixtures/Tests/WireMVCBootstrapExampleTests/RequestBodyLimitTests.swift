// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Foundation
import HTTPTypes
import Testing
import WireMVCTesting

@testable import WireMVCBootstrapExample

// Request bodies held to a limit, end to end: `@BytesBody`, `@RequestBodyLimit` at both scopes, and the 413 a
// body over the limit gets — by its `Content-Length`, or by reading it.
//
// Two suites, because the two refusals need two transports. Over a real socket a client cannot send a body
// that disagrees with its own `Content-Length`, so the live suite shows what a client sees: 413, and a
// connection that still serves. In-process the request head and body are separate values, which is what
// lets the second suite tell the two refusals apart — a head that claims too much against a body that is
// small, and a body that is too long under a head that says nothing.

/// `count` bytes of `byte`.
private func bytes(_ count: Int, _ byte: UInt8 = UInt8(ascii: "x")) -> Data {
    Data(repeating: byte, count: count)
}

/// A `Memo` whose JSON encoding is about `count` bytes long.
private func memo(ofLength count: Int) throws -> Data {
    try JSONEncoder().encode(Memo(text: String(repeating: "m", count: count)))
}

@Suite(.wiremvc(.swiftHttpServer))
struct RequestBodyLimitTests {
    /// The controller raises its routes' limit to 2 MiB, so a body past the 1 MB default — 1.5 MiB here —
    /// arrives whole. Without the annotation this request was a 422.
    @Test func aBodyUnderARaisedLimitArrivesWhole() async throws {
        try await withClient { client in
            let response = try await client.send("PUT", "/uploads/poster", body: bytes(1_572_864))
            #expect(response.status == 200)
            #expect(try response.json(Upload.self) == Upload(name: "poster", byteCount: 1_572_864))
        }
    }

    /// `@BytesBody` through the generated typed client: `[UInt8]` is sent as the body, as it is.
    @Test func theTypedClientSendsBytes() async throws {
        try await withClient(for: UploadsControllerClient.self) { uploads in
            let upload = try await uploads.put(name: "small", bytes: [1, 2, 3, 4])
            #expect(upload == Upload(name: "small", byteCount: 4))
        }
    }

    /// Over the limit is 413, not 422: the client is told to send less rather than something else. And the
    /// next request is still answered — a body refused for its size must not cost the client the server.
    ///
    /// A 100 KB memo against the route's 64 bytes: refused by its `Content-Length` before a byte is read, and
    /// small enough that the mebibyte the server drains after a route takes the rest, so the connection is
    /// kept. A body more than that over a limit is answered and the connection then closed, and whether the
    /// client sees the 413 first is a race against the close on a client still sending — measured at about
    /// one lost response in fifty on loopback — so that path is shown in-process, below, not here.
    @Test func aBodyOverTheLimitIs413AndTheServerStillAnswers() async throws {
        try await withClient { client in
            let refused = try await client.send(
                "POST",
                "/uploads/memo",
                body: try memo(ofLength: 100_000),
                headers: ["Content-Type": "application/json"]
            )
            #expect(refused.status == 413)
            let next = try await client.get("/uploads/limit")
            #expect(next.status == 200)
            #expect(try next.json(Int.self) == UploadLimits.maximumUpload)
        }
    }

    /// A route's own limit beats the controller's. `/uploads/memo` lowers it to 64 bytes, so a memo that
    /// would fit under the controller's 2 MiB is refused.
    @Test func aRouteLimitBeatsTheControllers() async throws {
        try await withClient { client in
            let small = try await client.send(
                "POST",
                "/uploads/memo",
                body: try memo(ofLength: 8),
                headers: ["Content-Type": "application/json"]
            )
            #expect(small.status == 200)
            let large = try await client.send(
                "POST",
                "/uploads/memo",
                body: try memo(ofLength: 200),
                headers: ["Content-Type": "application/json"]
            )
            #expect(large.status == 413)
        }
    }

    /// The limit and a malformed body are different failures with different statuses: a body within the
    /// limit that is not JSON is still 422.
    @Test func aMalformedBodyWithinTheLimitIsStill422() async throws {
        try await withClient { client in
            let response = try await client.send(
                "POST",
                "/uploads/memo",
                body: Data("{not json".utf8),
                headers: ["Content-Type": "application/json"]
            )
            #expect(response.status == 422)
        }
    }

    /// A route that states no limit gets the default, and over it is 413 — the defect: the same request
    /// used to be answered 422, as though the JSON were malformed. Just over the million-byte default and
    /// under the mebibyte drain, so the connection is kept, as above.
    @Test func theDefaultLimitIs413Too() async throws {
        try await withClient { client in
            let response = try await client.send(
                "POST",
                "/registry/tag",
                body: try JSONEncoder().encode(Note(value: String(repeating: "n", count: 1_020_000))),
                headers: ["Content-Type": "application/json"]
            )
            #expect(response.status == 413)
        }
    }

    /// A streamed binding is held to the route's limit by the reader the terminal hands it. `@DigestBody`
    /// allows 4 KiB by itself and the route only 1 KiB, so 2 KiB is refused — by the route, which the
    /// binding alone would not have done — and 512 bytes is not.
    @Test func aStreamedBindingIsHeldToTheRouteLimit() async throws {
        try await withClient { client in
            let small = try await client.send("POST", "/uploads/digest", body: bytes(512))
            #expect(small.status == 200)
            #expect(try small.json(BodyDigest.self).byteCount == 512)
            let large = try await client.send("POST", "/uploads/digest", body: bytes(2048))
            #expect(large.status == 413)
        }
    }
}

@Suite(.wiremvc(.inProcess))
struct DeclaredLengthTests {
    /// A head claiming more than the limit is refused **on the claim**: the body here is ten bytes, which the
    /// route would have taken, so the only thing that can have refused it is the `Content-Length`. That is
    /// the refusal that reads nothing — the point of checking the field before the body.
    @Test func aDeclaredLengthOverTheLimitIsRefusedWithoutReading() async throws {
        try await withClient { client in
            let response = try await client.send(
                "PUT",
                "/uploads/poster",
                body: bytes(10),
                headers: ["Content-Length": String(25 * 1024 * 1024)]
            )
            #expect(response.status == 413)
        }
    }

    /// The same claim on a streamed binding's route: refused before the binding walks a byte.
    @Test func aDeclaredLengthOverAStreamedRoutesLimitIsRefused() async throws {
        try await withClient { client in
            let response = try await client.send(
                "POST",
                "/uploads/digest",
                body: bytes(10),
                headers: ["Content-Length": "4096"]
            )
            #expect(response.status == 413)
        }
    }

    /// A body with no `Content-Length` — a chunked one, live — is held to the limit while it is read.
    @Test func aBodyWithNoDeclaredLengthIsHeldToTheLimitByTheRead() async throws {
        try await withClient { client in
            let response = try await client.send("PUT", "/uploads/poster", body: bytes(3 * 1024 * 1024))
            #expect(response.status == 413)
        }
    }

    /// The field is a claim and the read is what enforces it: a body longer than the length it states is
    /// still refused at the limit.
    @Test func aBodyLongerThanItsDeclaredLengthIsStillHeldToTheLimit() async throws {
        try await withClient { client in
            let response = try await client.send(
                "PUT",
                "/uploads/poster",
                body: bytes(3 * 1024 * 1024),
                headers: ["Content-Length": "10"]
            )
            #expect(response.status == 413)
        }
    }
}
