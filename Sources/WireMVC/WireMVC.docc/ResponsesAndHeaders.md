# Responses and headers

How a handler's return value becomes a response, and the three ways to set a header field.

## Overview

A route's response annotation says how the return value is encoded. Three ship, and all three are
declared through the same extension point a response mode declared outside WireMVC uses.

```swift
@Get("/{id}") @JSONResponse             func get(…) async throws -> Todo
@Get("/page") @HTMLResponse             func page(…) async throws -> some HTML
@Delete("/{id}") @ResponseStatus(.noContent) func delete(…) async throws
```

`@JSONResponse` encodes an `Encodable` return as a JSON body, with an optional status.
`@ResponseStatus` is the bodiless form. `@HTMLResponse` streams.

## Streaming is a contract, not an optimisation

`@HTMLResponse` sends the head first and writes the body incrementally as it renders, and that has
one consequence worth stating plainly: **error mapping covers such a route only up to the first
byte.** Binding failures, scope-entry throws and the handler itself still map to a status. A
failure *during rendering* happens after the head is on the wire, so it cannot become a status —
it truncates the response instead.

HTML support lives behind the `Elementary` trait, and WireMVC's core depends on no HTML library:
the annotation names a convention, resolved in your own module. See <doc:PackageTraits>.

## Constant headers

`@ResponseHeader` sets a constant field on the route's **successful** response, at two scopes —
on the controller it covers every route, on a route it covers that one, and a route entry beats a
controller entry naming the same field.

```swift
@ResponseHeader(.cacheControl, "no-store")
@ResponseHeader(.setCookie, "consent=1", .append)
```

The verb defaults to `.set`. `.append` emits a **separate field line** rather than folding into
one value, which is what makes it correct for `Set-Cookie` — RFC 6265 forbids folding that field
and HTTP/2 requires separate lines. `.setIfAbsent` defers to a contributor further in.

It applies to success only. An error response is built by the mapping that produced it and
carries its own fields: a `Cache-Control` chosen for a `200` is rarely right for the `500` that
replaced it, so inheriting it silently would be a worse default than saying nothing.

## Computed headers

A value the handler computes is returned, not annotated. Return a labelled tuple:

```swift
@Get("/{id}") @JSONResponse
func document(@Path id: UUID) async throws -> (headers: HTTPFields, body: Document) {
    let doc = try await store.document(id)
    return ([.eTag: doc.etag], doc)
}
```

The tuple may name `status`, `headers` and `body` — any suffix-subset ending in `body` — and a
field it sets beats `@ResponseHeader` on the route, which beats the controller's. Innermost wins,
as everywhere else.

Returning response metadata rather than mutating something handed to the handler is what the
typed prior art does: axum's tuple `IntoResponse`, Spring's `ResponseEntity`, Hummingbird's
`EditedResponse`. It is also what an OpenAPI operation already does, so both authoring styles
answer the question the same way.

## Owning the wire

`@RawRoute` is the escape hatch. The handler receives the request, the matched path parameters,
the body reader and the response sender verbatim — no parameter decoding, no response encoding —
and writes the response itself. It stands in for the response annotation, so a raw route needs no
`@JSONResponse`.

```swift
@Get("/events")
@RawRoute
func stream<Sender: HTTPResponseSender & ~Copyable>(
    request: HTTPRequest, responseSender: consuming sending Sender
) async throws { … }
```

Take only the primitives you need, in any order — they are matched by type. The explicit form,
`@RawRoute(.role, …)`, binds them positionally by named role instead, which is what you need when
a parameter's type cannot be inferred: a slot a middleware *transformed*, such as a
sender-transforming middleware's `MultiPartSender<S>`. There is no `as?` rescue for a `consuming`
non-copyable value, so a transformed sender has to be named by role.

Naming the transformed slot also couples the route to its producing middleware at compile time —
without the transform, the generated primitive does not match the handler's parameter and the
build fails.

## Declaring a response mode

The built-ins are instances of `@ResponseMode`, not privileged cases of it. That is the test the
extension point has to pass: if the built-ins could not be expressed through it, its shape would
be wrong. The request side settled the same question when the parameter bindings became ordinary
conformers rather than names the generator tested for.
