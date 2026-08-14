import Foundation
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
}
