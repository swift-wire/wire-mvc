# Elementary HTML integration

## Purpose

The `WireMVCElementary` module, which supplies the `WireMVCHTMLProducer` that `@HTMLResponse` routes
resolve against, and renders an Elementary `HTML` value straight into the response body writer
through the streaming response tier. It is compiled only when the `Elementary` package trait is on,
and it depends on a pinned Elementary fork. WireMVC's core and its code generator name no HTML
library.

Rationale: [StreamingResponseTier](../../../Documentation/Notes/StreamingResponseTier.md).
Documentation: [PackageTraits](../../../Sources/WireMVC/WireMVC.docc/PackageTraits.md), [ResponsesAndHeaders](../../../Sources/WireMVC/WireMVC.docc/ResponsesAndHeaders.md).

## Requirements

### Requirement: The `Elementary` trait gates the Elementary dependency
The root `Package.swift` SHALL declare a trait named `Elementary`, not enabled by default, and the
`WireMVCElementary` target SHALL depend on the `Elementary` product only under
`.when(traits: ["Elementary"])`. The `WireMVCElementary` library product SHALL be declared
unconditionally.

#### Scenario: a consumer enables the trait
- **WHEN** the Fixtures package depends on wire-mvc with `traits: ["NIOHTTPServer", "Elementary"]` and its targets depend on the `WireMVCElementary` product
- **THEN** those targets build and serve `@HTMLResponse` routes

#### Scenario: the trait is off
- **WHEN** the root package is resolved with its default traits
- **THEN** the committed root `Package.resolved` contains no `elementary` pin

Pinned by: `Fixtures/Package.swift` (built by the `Build fixtures` step of the `BuildAndRun` job in `.github/workflows/build.yml`), `Package.resolved`. No CI step asserts that `elementary` stays out of the root graph; that is pinned by nothing yet.

### Requirement: With the trait off the module is empty
Every declaration in `Sources/WireMVCElementary/WireMVCHTMLProducer.swift` SHALL sit inside `#if
Elementary`, so that `WireMVCElementary` compiles to an empty module when the trait is off.

#### Scenario: a default build
- **WHEN** `swift build` runs at the repository root with no traits enabled
- **THEN** the `WireMVCElementary` target builds with no Elementary product and declares nothing

Pinned by: the `Build` step of the `BuildAndRun` job in `.github/workflows/build.yml`.

### Requirement: The Elementary dependency is a pinned fork
The root `Package.swift` SHALL depend on `https://github.com/tachyonics/elementary.git` at revision
`07eb69492ddf7052616af47518e7f883bd8f2691`, which lets `HTMLStreamWriter` be conformed to by a
`~Copyable, ~Escapable` type.

#### Scenario: the fixtures resolve the fork
- **WHEN** the Fixtures package resolves with the `Elementary` trait on
- **THEN** its `Package.resolved` pins `elementary` at `https://github.com/tachyonics/elementary.git` revision `07eb69492ddf7052616af47518e7f883bd8f2691`

Pinned by: `Fixtures/Package.resolved`, `Fixtures/Tests/StreamingTierTests/ElementaryProducerTests.swift` (compiles only against the fork).

### Requirement: `WireMVCElementary` re-exports Elementary
`WireMVCElementary` SHALL `@_exported public import Elementary`, so a controller module that imports
only `WireMVCElementary` can declare `some HTML` handlers and use Elementary's element functions.

#### Scenario: a controller with one import
- **WHEN** the fixture's `PagesController.swift` imports `WireMVC` and `WireMVCElementary` but not `Elementary`
- **THEN** its `@HTMLResponse` handlers returning `some HTML` compile

Pinned by: `Fixtures/Sources/WireMVCBootstrapExample/PagesController.swift` (built by the `Build fixtures` step of the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: `WireMVCHTMLProducer` is the `@HTMLResponse` producer
`WireMVCHTMLProducer<Content: HTML>` SHALL conform to `WireMVCBodyProducer` with `init(_ content:
Content, chunkSize: Int = 1024)` and `contentType` equal to `wireMVCHTMLContentType`, whose value is
`text/html; charset=utf-8`. It SHALL NOT require `Content` to be `Sendable`. The generated
`WireMVCHTMLProducer(<handler call>)` SHALL resolve against the `WireMVCHTMLProducer` visible in the
controller's module.

#### Scenario: a streamed page over the wire
- **WHEN** `GET /pages/home` is served from an `@HTMLResponse` route in the fixture app
- **THEN** the response is `200` with `Content-Type: text/html; charset=utf-8` and a body beginning `<!DOCTYPE html><html><head>` and ending `</body></html>`

#### Scenario: an annotated status beside a route constant
- **WHEN** `GET /pages/gone` is served from a route annotated `@HTMLResponse(status: .notFound)` with `@ResponseHeader(.cacheControl, "no-store")`
- **THEN** the response is `404` with `Content-Type: text/html; charset=utf-8` and `Cache-Control: no-store`

Pinned by: `Fixtures/Tests/WireMVCBootstrapExampleTests/HTMLResponseOverTheWireTests.swift` (`servesAStreamedPage`, `annotatedStatusAndRouteConstants`), `Tests/WireMVCCodegenTests/HTMLResponseGenerationTests.swift` (`plainRoute`).

### Requirement: The producer renders directly into the response body writer
`WireMVCHTMLProducer.writeBody(into:terminatedBy:)` SHALL render `content` with
`render(intoOwned:chunkSize:)` into a `ProposalHTMLStreamWriter` wrapping the response body writer,
take the writer back, and call `finish` with an empty buffer and the given trailer.

#### Scenario: a fragment
- **WHEN** `WireMVCHTMLProducer(div(.class("greeting")) { p { "Hi mom!" } })` is driven through the streaming terminal
- **THEN** the body is `<div class="greeting"><p>Hi mom!</p></div>` and the response finishes with no trailer

#### Scenario: a large page in chunks
- **WHEN** a 200-item page is driven with `chunkSize: 256`
- **THEN** more than ten separate writes reach the sender and their concatenation equals the page's buffered `render()`

#### Scenario: the head before the tail renders
- **WHEN** a page ends in `AsyncContent` that waits on a gate
- **THEN** the head and at least one chunk are recorded before the gate opens, and the body ends `<p>late</p></div>` after it does

#### Scenario: a trailer
- **WHEN** `WireMVCHTMLProducer(p { "done" })` is driven with trailer `x-render: elementary`
- **THEN** the body is `<p>done</p>` and the response finishes with that trailer

Pinned by: `Fixtures/Tests/StreamingTierTests/ElementaryProducerTests.swift` (`fragment`, `document`, `chunksIncrementally`, `headPrecedesBody`, `asyncContent`, `trailers`).

### Requirement: `ProposalHTMLStreamWriter` adapts the proposal's writer to Elementary
`ProposalHTMLStreamWriter<Writer: CallerAsyncWriter & ~Copyable & ~Escapable>` with `Writer.WriteElement
== UInt8` SHALL be a `~Copyable`, `~Escapable` `HTMLStreamWriter` whose `write(_:)` copies the slice into
a `UniqueArray<UInt8>` and passes it to `writer.write(buffer:)`, and whose consuming `taken()` returns
the wrapped writer.

#### Scenario: async content streams as it resolves
- **WHEN** `ul { AsyncForEach(…) { row in li { row } } }` over `alpha`, `beta`, `gamma` is driven with `chunkSize: 8`
- **THEN** the body is `<ul><li>alpha</li><li>beta</li><li>gamma</li></ul>` delivered in more than one write

Pinned by: `Fixtures/Tests/StreamingTierTests/ElementaryProducerTests.swift` (`asyncContent`, `chunksIncrementally`).

## Related specifications

- [responses-and-modes](../responses-and-modes/spec.md)
- [package-traits](../package-traits/spec.md)
- [response-headers](../response-headers/spec.md)
- [testing-harness](../testing-harness/spec.md)
