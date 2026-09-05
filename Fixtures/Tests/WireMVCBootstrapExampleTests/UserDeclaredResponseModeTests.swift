// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Foundation
import HTTPTypes
import Testing
import WireMVCTesting

@testable import WireMVCBootstrapExample

// A response mode declared **outside WireMVC**, served over real HTTP and driven through the *generated*
// typed client. The response-side counterpart of `@TextBody`, and the claim the whole seam exists for:
// `@CSVResponse` is a macro declared in this module carrying `@ResponseMode(.buffered, codec: "CSVCodec")`,
// and nothing in the framework names it, CSV, or `Ledger`.
//
// What makes this a proof rather than a demonstration is `Ledger`: it is not `Codable`. It can travel only
// through `CSVCodec`. A generated client that fell back to `TestResponse.json` — which is exactly what the
// client did for every mode before this, and what the design note originally left unaddressed — would not
// compile, rather than failing somewhere later.

@Suite(.wiremvc(.swiftHttpServer))
struct UserDeclaredResponseModeTests {

    /// The server half: the route's body and content type both come from the mode's own codec.
    @Test func servesTheCodecsBytesAndContentType() async throws {
        try await withClient { client in
            let response = try await client.get("/pages/ledger")
            #expect(response.status == 200)
            let fields = try #require(response.head?.headerFields)
            #expect(
                fields[.contentType] == "text/csv; charset=utf-8",
                "the content type comes from the codec, which is the thing that knows"
            )
            #expect(response.bodyText == "day,amount\nmon,12\ntue,34\n")
        }
    }

    /// The client half. `ledger()` returns a `Ledger` — decoded by `CSVCodec`, because the mode says so.
    @Test func theTypedClientDecodesThroughTheMode() async throws {
        try await withClient(for: PagesControllerClient.self) { pages in
            let ledger = try await pages.ledger()
            #expect(ledger.entries.map(\.day) == ["mon", "tue"])
            #expect(ledger.entries.map(\.amount) == [12, 34])
        }
    }

    /// A user mode is not second-class about the status argument: `@CSVResponse(status: .created)` is read
    /// through the same generic path `@JSONResponse(status:)` is, keyed on whichever annotation was written.
    ///
    /// It also composes with a user *binding* on the same route — `@TextBody` in, `@CSVResponse` out — so
    /// both halves of the extension point are exercised by one generated method.
    @Test func aUserModeCarriesAnAnnotatedStatus() async throws {
        try await withClient(for: PagesControllerClient.self) { pages in
            let ledger = try await pages.recordLedger(note: "wed")
            #expect(ledger.entries.map(\.day) == ["wed"])
        }
        try await withClient { client in
            // `send` rather than `post`: the latter is the JSON convenience, and this route's body is not
            // JSON — which is the whole reason `@TextBody` is on it.
            let response = try await client.send("POST", "/pages/ledger", body: Data("wed".utf8))
            #expect(response.status == 201, "the annotated status, not the default 200")
        }
    }

    /// The built-ins still work, on the same controller, through the same lookup. They are no longer special
    /// cases in the generator — `@HTMLResponse` is a `.streaming` mode with a producer, `@CSVResponse` a
    /// `.buffered` one with a codec — so this pins that generalising them did not quietly change either.
    @Test func theBuiltInModesStillBehaveAsBefore() async throws {
        try await withClient { client in
            let html = try await client.get("/pages/home")
            #expect(html.head?.headerFields[.contentType] == "text/html; charset=utf-8")
            #expect(html.bodyText.hasPrefix("<!DOCTYPE html>"))

            let csv = try await client.get("/pages/ledger")
            #expect(csv.head?.headerFields[.contentType] == "text/csv; charset=utf-8")
        }
    }
}
