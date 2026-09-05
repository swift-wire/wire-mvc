// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

import Foundation
import HTTPTypes
import Testing
import WireMVCTesting

@testable import WireMVCBootstrapExample

// The streaming **request** tier over real HTTP: `@DigestBody` is declared in the app module with
// `@RequestBinding(.readerBody)`, so the generated terminal hands it the reader instead of collecting the
// body first.
//
// Correct output is the weak half of this — a collecting binding would produce the same digest. The claims
// worth testing are the ones only a streaming binding can satisfy: that it rejects an oversized body
// *during* the read, and that no `collectBody` call is generated for the route at all.

@Suite(.wiremvc(.swiftHttpServer))
struct StreamingRequestTests {

    private func digest(of body: String) -> BodyDigest {
        var hash = UInt64(14_695_981_039_346_656_037)
        for byte in Array(body.utf8) { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return BodyDigest(byteCount: body.utf8.count, checksum: hash)
    }

    @Test("a streamed body reduces to what the binding accumulated")
    func reducesTheBody() async throws {
        try await withClient { client in
            let body = "the quick brown fox jumps over the lazy dog"
            let response = try await client.send("POST", "/pages/digest", body: Data(body.utf8))
            #expect(response.status == 200)
            #expect(try response.json(BodyDigest.self) == digest(of: body))
        }
    }

    /// An empty body is a stream that ends immediately, not an absent one. The distinction matters because a
    /// collecting binding sees `body: []` and a streaming one sees a reader that yields nothing — and the
    /// second is easy to get wrong by treating the first `read` as proof there is data.
    @Test("an empty body is a stream that ends immediately")
    func emptyBody() async throws {
        try await withClient { client in
            let response = try await client.send("POST", "/pages/digest", body: Data())
            #expect(response.status == 200)
            #expect(try response.json(BodyDigest.self).byteCount == 0)
        }
    }

    /// A body spanning many chunks. The digest is a fold, so a wrong chunk boundary — a dropped tail, a
    /// double-counted final chunk — changes it. That is the cheap way to detect the end-of-stream rule being
    /// applied wrongly: the proposal's `read` marks the *last* chunk with a non-nil final element, and its
    /// buffer may still carry bytes, so exiting the loop before consuming it silently truncates.
    @Test("a multi-chunk body is folded exactly once, tail included")
    func multiChunkBody() async throws {
        try await withClient { client in
            let body = String(repeating: "abcdefghij", count: 400)  // 4000 bytes, under the route's cap
            let response = try await client.send("POST", "/pages/digest", body: Data(body.utf8))
            #expect(response.status == 200)
            let returned = try response.json(BodyDigest.self)
            #expect(returned.byteCount == 4000, "no chunk dropped or counted twice")
            #expect(returned == digest(of: body))
        }
    }

    /// **The claim a collecting binding cannot make.** The route caps the body at 4 KiB and throws from
    /// inside the walk, so an oversized request is refused part-way through reading it rather than after it
    /// has all arrived. `@ErrorResponse(DigestError.self, .contentTooLarge)` maps that to 413, which also
    /// pins that an error thrown mid-stream still reaches the mapping — the response head has not been sent,
    /// because this is a buffered response mode.
    @Test("an oversized body is refused during the read")
    func oversizedBodyIsRefusedMidStream() async throws {
        try await withClient { client in
            let response = try await client.send(
                "POST",
                "/pages/digest",
                body: Data(String(repeating: "x", count: 64 * 1024).utf8)
            )
            #expect(response.status == 413)
        }
    }

    // MARK: - The same binding on a streaming response

    /// `/pages/digest/page` is `@DigestBody` again, this time under `@HTMLResponse` — the combination the
    /// generator used to refuse outright.
    ///
    /// It goes through the **lending** terminal overload: the reader is handed to `building` as a consuming
    /// parameter instead of being collected before it, so the binding walks it inside the mapped region. The
    /// digest reaching the page is the proof the walk happened there and not somewhere the head had already
    /// gone out.
    @Test("a reduced body reaches a streamed response")
    func reducedBodyOnStreamingResponse() async throws {
        try await withClient { client in
            let body = "the quick brown fox jumps over the lazy dog"
            let response = try await client.send("POST", "/pages/digest/page", body: Data(body.utf8))
            #expect(response.status == 200)
            let page = response.bodyText
            let expected = digest(of: body)
            #expect(page.contains("bytes: \(expected.byteCount)"))
            #expect(page.contains("checksum: \(expected.checksum)"))
            // The streaming tier seeds the content type; a buffered mode would have set its own.
            #expect(response.head?.headerFields[.contentType]?.contains("text/html") == true)
        }
    }

    /// **The property the placement buys.** The binding throws from inside the walk, and the mapping still
    /// fires — 413, not a truncated 200 — because `lendingBodyFrom:` puts the walk inside the same `do`
    /// whose `catch` maps. Hoisting the read above the terminal would compile and lose exactly this, which
    /// is why the existing collecting overload's doc comment argues against it.
    @Test("an oversized body still maps to 413 on a streaming response")
    func oversizedBodyMapsOnStreamingResponse() async throws {
        try await withClient { client in
            let response = try await client.send(
                "POST",
                "/pages/digest/page",
                body: Data(String(repeating: "x", count: 64 * 1024).utf8)
            )
            #expect(response.status == 413, "the walk threw before the head went out, so the tier mapped it")
        }
    }

    /// A lent reader **beside another bind**. `@Path` decodes from the register closure's `pathParameters`
    /// while the reader arrives as `building`'s parameter — two binds of different kinds in one closure.
    /// The label reaching the page is what proves the ordinary bind still runs there too.
    @Test("a reduced body composes with other binds on a streamed response")
    func reducedBodyBesideOtherBinds() async throws {
        try await withClient { client in
            let body = "hello"
            let response = try await client.send("POST", "/pages/digest/report/page", body: Data(body.utf8))
            #expect(response.status == 200)
            let page = response.bodyText
            #expect(page.contains("report"), "the @Path bind reached the handler")
            #expect(page.contains("bytes: \(body.utf8.count)"), "so did the lent reader")
        }
    }

    /// A streamed response on a **request-scoped** controller, with a lent reader.
    ///
    /// Every other `@HTMLResponse` route in the fixtures is app-`@Singleton`, so before this the streaming
    /// terminal had only ever been emitted with an empty scope-entry preamble and prologue. Here the
    /// generated `building` carries the scope entry, the lent bind and the handler call together — each half
    /// is fine alone, which is exactly why the combination is worth pinning.
    @Test("a streamed response works on a request-scoped controller")
    func streamedResponseOnScopedController() async throws {
        try await withClient { client in
            let body = "abcdef"
            let response = try await client.send("POST", "/scoped-pages/digest", body: Data(body.utf8))
            #expect(response.status == 200)
            let page = response.bodyText
            #expect(page.contains("stamped:scoped"), "the scope-entered controller's injected singleton")
            #expect(page.contains("bytes: \(body.utf8.count)"))
        }
    }

    /// And the mapping still fires from inside a scope-entered lending terminal.
    @Test("an oversized body maps to 413 on a scoped streamed route")
    func oversizedBodyMapsOnScopedStreamingResponse() async throws {
        try await withClient { client in
            let response = try await client.send(
                "POST",
                "/scoped-pages/digest",
                body: Data(String(repeating: "x", count: 64 * 1024).utf8)
            )
            #expect(response.status == 413)
        }
    }
}
