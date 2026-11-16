# Request bindings

How a handler parameter is filled from the request, and how to add a binding of your own.

## Overview

Every handler parameter carries a binding annotation naming where its value comes from. The
built-ins cover the ordinary cases:

```swift
@Get("/{id}")
@JSONResponse
func find(
    @Path id: UUID,
    @Query verbose: Bool,
    @Header("X-Tenant") tenant: String
) async throws -> Document { … }

@Post
@JSONResponse(status: .created)
func create(@JSONBody new: NewDocument) async throws -> Document { … }
```

``Path`` and ``Query`` convert through `LosslessStringConvertible`, so any type that can be
spelled as a string is usable without ceremony. ``Header`` reads a field, ``JSONBody`` decodes
the request body.

A decode that fails becomes a client-error status rather than a `500` — the generated witness
maps ``WireMVCBindingError`` onto the appropriate 4xx before any of your error mappings are
consulted. See <doc:ErrorHandling>.

## Bodies, and how much of one a route accepts

``JSONBody`` decodes the body; ``BytesBody`` hands it over as it arrived, for a route whose body *is*
the payload — an image, an archive, a file to store:

```swift
@Put("/blobs/{digest}")
@ResponseStatus(.noContent)
@RequestBodyLimit(25 * 1024 * 1024)
func put(@Path digest: String, @BytesBody image: [UInt8]) async throws { … }
```

A collected body is held in memory whole before any binding sees it, so a route collects at most
``WireMVCRequest/defaultMaximumBodySize`` — a million bytes — unless it raises that with
`@RequestBodyLimit`. On the controller the annotation covers every route that reads a body; on a
route it covers that one, and the route's beats the controller's.

A body over the limit is answered **413 Content Too Large**, before the handler runs. A request
whose `Content-Length` already says too much is refused without a byte being read; a chunked body,
or one that runs past the length it stated, is refused when the read reaches the limit. Neither is
a `422`: a body can be well-formed and still too long, and the two statuses ask the client for
different things.

The limit reaches a binding that reads the body itself, too. A `.readerBody` or `.bodyStream`
binding on a route with `@RequestBodyLimit` is handed a ``WireMVCBoundedReader`` that ends the body
at the limit, so the route's limit holds whatever the binding does — and a binding that keeps a
smaller limit of its own, through ``WireMVCRequest/streamBody(_:into:maximumSize:consume:)``, still
enforces that one.

## The contract

All of them are ordinary property wrappers conforming to ``RequestBound``, and the generated witness
calls `bind` once per parameter. Nothing about them is special-cased in the macro, which is the
point: the macro stays a thin, binding-agnostic dispatcher, and a binding you write is used the
same way the built-ins are.

To add one, write a property wrapper conforming to ``RequestBound`` and mark it
`@RequestBinding`:

```swift
@RequestBinding(.body)
public struct FormBody<Value: Decodable & Sendable>: RequestBound { … }
```

The argument states the *obligations* — what the code generator must do differently for this
binding, such as collecting the request body, or claiming a path placeholder. It deliberately
does not state a wire position: where a value comes from is the binding's own behaviour, and the
generator never reads your `bind` body, so obligations are exactly the things it cannot infer.

The declaration is read by the build plugin, which already re-parses every Wire-aware dependency
module — so a binding declared in a library works in any consumer without WireMVC knowing its
name.

## Bindings that resolve rather than decode

A static `bind` is right while everything needed is already in the request. It is not enough for
a binding that has to *consult* something — a store to read from, a policy engine, the caller the
request scope authenticated.

That case takes two declarations, and cannot take one. A parameter attribute has to be a property
wrapper, whose instance holds the value the call site supplies; a graph binding's instance holds
what the graph supplied. No single type can have both initialisers be total.

So the wrapper names a **worker**, and the worker is an ordinary request-scoped binding
conforming to ``ScopedRequestBound``:

```swift
@RequestBinding(DocumentAuthorizer.self, .path)
@propertyWrapper
public struct AuthorizedDocument {
    public var wrappedValue: Document
    public init(wrappedValue: Document) { self.wrappedValue = wrappedValue }
    public init(wrappedValue: Document, _ name: String) { self.wrappedValue = wrappedValue }
}

@Scoped(seed: HTTPRequest.self)
public struct DocumentAuthorizer: ScopedRequestBound {
    public typealias Value = Document
    @Inject var documents: DocumentStore
    @Inject var policies: PolicyEngine

    public func bind(…) async throws -> Document { … }
}
```

Neither declaration mentions the scope, and the controller mentions neither. `@RequestBinding`
declares swift-wire's `.injectsFromGraph` capability, so a route parameter naming the wrapper is
what makes the scope entry hand back the worker — one hop out, through that argument. There is
no second place to keep in step.

A route taking a `Document` cannot skip the authorisation
check, because the check is how a `Document` comes into existence. The alternative — load, then
authorise — restates that ordering in every handler, and the route that omits the second line
compiles, serves, and is unauthorised with nothing but review to catch it.

The worker must be bound in the **controller's own** scope. A `@Singleton @Controller` enters no
scope, so there is nothing to resolve a worker from, and the generator says so at the parameter
rather than emitting a reference to a value that was never constructed.
