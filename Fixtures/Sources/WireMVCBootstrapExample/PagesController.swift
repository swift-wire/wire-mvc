package import HTTPTypes
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
}

package struct PageTooLarge: Error {
    package init() {}
}
