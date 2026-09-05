// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import HTTPTypes
package import Wire
package import WireMVC
package import WireMVCElementary

// The `@HTMLResponse` route kind, served for real. This is the only place the generated streaming terminal
// actually *runs*: `WireMVCBuildPlugin` executes only in this package, so until a route here carries
// `@HTMLResponse` the codegen is compile-tested and never executed.
//
// Every route below streams. The head goes out before the body is rendered, and the body is written in
// chunks as it renders — see `WireMVCBootstrapExampleTests` for the assertions that pin that over real HTTP.

/// A page big enough that Elementary's default 1 KiB chunking splits it into several writes, which is what
/// makes "streamed" observable from the client rather than merely claimed.
package struct TodoListPage: HTMLDocument {
    package let heading: String
    package let rows: [String]

    package var title: String { heading }

    package var head: some HTML {
        meta(.name(.viewport), .content("width=device-width, initial-scale=1.0"))
    }

    package var body: some HTML {
        h1 { heading }
        ul {
            for row in rows {
                li(.class("todo")) { row }
            }
        }
    }
}

@Singleton
@Controller("/pages")
package struct PagesController {

    /// The plain shape: return HTML, get a streamed `200` with `text/html; charset=utf-8` seeded.
    @Get("/home")
    @HTMLResponse
    package func home() -> some HTML {
        TodoListPage(heading: "Home", rows: ["first", "second"])
    }

    /// Large enough to chunk. `{count}` is a path binding, so this also pins that bindings decode *inside*
    /// the terminal's `building` closure — before the head is sent, where a failure can still be mapped.
    ///
    /// It also throws conditionally, which is what makes `@ErrorResponse` meaningful on a streaming route:
    /// the throw happens before the head, so it maps to a status exactly as it would on `@JSONResponse`.
    @Get("/list/{count}")
    @HTMLResponse
    @ErrorResponse(PageTooLarge.self, .badRequest)
    package func list(@Path count: Int) throws -> some HTML {
        guard count <= 500 else { throw PageTooLarge() }
        return TodoListPage(
            heading: "Todos",
            rows: (0..<count).map { "task number \($0) — with enough text to fill a chunk" }
        )
    }

    /// A binding WireMVC has never heard of — `@TextBody` is declared in this module with
    /// `@RequestBinding(.body)`, and the plugin reads that off the declaration.
    @Post("/echo")
    @HTMLResponse
    package func echo(@TextBody text: String) -> some HTML {
        TodoListPage(heading: "Echo", rows: [text])
    }

    /// A **declared** `@Header`, so the generated client's precedence rule is testable: a route that binds a
    /// header gets a typed parameter for it, and that parameter beats anything passed in the loose `headers:`
    /// bag. The bag exists for headers a route does not declare (an auth token, a trace id read by a
    /// middleware); passing both is a contradiction, and the typed one is the more specific statement.
    @Get("/tenant")
    @HTMLResponse
    package func tenant(@Header("x-tenant") tenant: String) -> some HTML {
        TodoListPage(heading: tenant, rows: [])
    }

    /// A route constant beating the seeded content type, and a non-200 annotated status. Both go through
    /// the ordinary header machinery, so this is the same tier rule every other route obeys.
    @Get("/gone")
    @HTMLResponse(status: .notFound)
    @ResponseHeader(.cacheControl, "no-store")
    package func gone() -> some HTML {
        TodoListPage(heading: "Gone", rows: [])
    }

    /// A **response mode** WireMVC has never heard of. `@CSVResponse` is declared in this module with
    /// `@ResponseMode(.buffered, codec: "CSVCodec")`, and the plugin reads that off the declaration exactly
    /// as it reads `@TextBody`'s obligation above — so this one route exercises both ends of the extension
    /// point, with the framework naming neither.
    ///
    /// Buffered, unlike every other route here, which is the point: `@HTMLResponse` proved the streaming
    /// terminal, and a mode has to be able to pick the other one.
    @Get("/ledger")
    @CSVResponse
    package func ledger() -> Ledger {
        Ledger(entries: [Ledger.Entry(day: "mon", amount: 12), Ledger.Entry(day: "tue", amount: 34)])
    }

    /// A **streamed** request body, through a binding declared in this module. The handler never sees the
    /// bytes — only what the binding reduced them to while walking the reader.
    ///
    /// `@JSONResponse` here, with `/digest/page` below as the same binding on a **streaming** response —
    /// the pair is what shows the terminal is chosen by the response, not by the binding.
    @Post("/digest")
    @JSONResponse
    @ErrorResponse(DigestError.self, .contentTooLarge)
    package func digest(@DigestBody digest: BodyDigest) -> BodyDigest {
        digest
    }

    /// A **reduced** request body on a **streaming** response — the combination that used to be refused.
    ///
    /// It works through the lending terminal overload: the reader arrives as a consuming *parameter* of
    /// `building` rather than being collected before it, so `@DigestBody` walks it inside the mapped `do`.
    /// That placement is the whole point — an oversized body still throws `DigestError` from inside the
    /// walk and still maps to `413`, because nothing has been written yet. Pinned over real HTTP by
    /// `WireMVCBootstrapExampleTests`.
    ///
    /// Only *lending the stream to the handler* remains refused on a streaming response: a typed handler
    /// returns before its body is written, so it cannot still hold the request stream. See
    /// `WireMVCDiagnostic.bodyStreamOnStreamingResponse`.
    @Post("/digest/page")
    @HTMLResponse
    @ErrorResponse(DigestError.self, .contentTooLarge)
    package func digestPage(@DigestBody digest: BodyDigest) -> some HTML {
        TodoListPage(
            heading: "Digest",
            rows: ["bytes: \(digest.byteCount)", "checksum: \(digest.checksum)"]
        )
    }

    /// A reduced body **beside other binds**, on a streaming response.
    ///
    /// The lent reader is a parameter of `building` while `@Path` decodes from the register closure's
    /// `pathParameters` — two binds of different kinds in one `building`, which is the interaction the
    /// single-bind route above cannot show. The path value reaching the page proves the ordinary bind still
    /// runs inside the mapped region alongside the lent one.
    @Post("/digest/{label}/page")
    @HTMLResponse
    @ErrorResponse(DigestError.self, .contentTooLarge)
    package func labelledDigestPage(@Path label: String, @DigestBody digest: BodyDigest) -> some HTML {
        TodoListPage(heading: label, rows: ["bytes: \(digest.byteCount)"])
    }

    /// The same mode with an annotated status, read through the generic `status:` path rather than a
    /// per-annotation one — a user mode is not second-class about it.
    @Post("/ledger")
    @CSVResponse(status: .created)
    package func recordLedger(@TextBody note: String) -> Ledger {
        Ledger(entries: [Ledger.Entry(day: note, amount: 1)])
    }
}

/// The CSV route's payload. `Codable`-free on purpose: it can travel *only* through `CSVCodec`, so a client
/// that fell back to JSON would not compile rather than failing at runtime — which is the difference between
/// this fixture proving the seam and merely exercising it.
package struct Ledger: CSVRepresentable, CSVReadable {
    package struct Entry {
        package let day: String
        package let amount: Int
        package init(day: String, amount: Int) {
            self.day = day
            self.amount = amount
        }
    }

    package let entries: [Entry]
    package init(entries: [Entry]) { self.entries = entries }

    package static var csvHeader: String { "day,amount" }
    package var csvRows: [String] { entries.map { "\($0.day),\($0.amount)" } }

    package init(csvRows: [String]) throws {
        entries = try csvRows.map { row in
            let fields = row.split(separator: ",", maxSplits: 1)
            guard fields.count == 2, let amount = Int(fields[1]) else { throw CSVError.badField(row) }
            return Entry(day: String(fields[0]), amount: amount)
        }
    }
}

package struct PageTooLarge: Error {
    package init() {}
}
