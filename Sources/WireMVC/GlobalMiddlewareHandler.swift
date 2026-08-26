import AsyncStreaming
public import HTTPAPIs
public import HTTPTypes
public import Middleware

/// The global-middleware **front layer** (M5.5 Phase 5). The `@WireMVCBootstrap` composition root's
/// `@Middleware` wraps *every* request — matched routes and the `@NotFound` fallback alike — by wrapping
/// the finalized router in this handler once, in the generated `@main`. It folds a composed non-transforming
/// global chain around the inner handler's `handle`, so global concerns (access logging, auth gates, CORS)
/// run outside the router without being replicated into each route's codegen.
///
/// The terminal calls `inner.handle`, which is fixed on the router's box type and demands `consuming
/// sending` reader/sender. That is why global middleware must be **non-transforming** (`Chain.Input ==
/// Chain.NextInput` — the box type is preserved end-to-end): they observe and short-circuit-by-writing, but
/// cannot transform the context/reader/sender the router expects. Transforming middleware stay
/// controller/route-scope, where the generated terminal is shaped for the transformed box. The reader/sender
/// survive the box fold as `sending` because ``RequestResponseMiddlewareBox`` holds them in
/// ``WireDisconnected`` — the property that lets this terminal reach `inner.handle` at all.
///
/// `Chain` is the concrete composed middleware (`wireCompose`'s inferred type), taken as a generic parameter
/// so it needn't be named (`Middleware` has two primary associated types, so `some Middleware<Input>` with a
/// pinned input is not expressible).
public struct GlobalMiddlewareHandler<
    Inner: HTTPServerRequestHandler,
    Chain: Middleware
>: HTTPServerRequestHandler
where
    Inner.RequestContext: ~Copyable,
    Inner.Reader: ~Copyable,
    Inner.ResponseSender: ~Copyable,
    Inner.ResponseSender.Writer: ~Copyable,
    // The front layer's box is over the courier's **`Base`**, not over the courier itself. With a linear
    // registry there is exactly one of it, so the box cannot both own it and hold a courier that also
    // carries it. The courier is therefore taken apart on the way in and rebuilt in the terminal — one
    // re-wrap per request — which is also what the route boxes below already do via `takeContents()`.
    Chain.Input == RequestResponseMiddlewareBox<
        Inner.RequestContext.Base, Inner.Reader, Inner.ResponseSender
    >,
    Chain.NextInput == Chain.Input,
    // The front layer's box must carry the *same* registry the routes below will drain, so it takes it out
    // of the context rather than making one. Stated as a capability so this stays generic over the context.
    Inner.RequestContext: ResponseHeaderCarrying
{
    let inner: Inner
    let chain: Chain

    public init(inner: Inner, chain: Chain) {
        self.inner = inner
        self.chain = chain
    }

    public func handle(
        request: HTTPRequest,
        requestContext: consuming Inner.RequestContext,
        reader: consuming sending Inner.Reader,
        responseSender: consuming sending Inner.ResponseSender
    ) async throws {
        // Destructured here, in this frame, rather than inside a closure: `reader` and `responseSender` are
        // this function's `sending` parameters, and a closure would make them captures — task-isolated, and
        // so refused where the box wants them `sending`.
        let contents = requestContext.takeContents()
        let registry = contents.responseHeaders.take()
        let base = contents.base

        let box = RequestResponseMiddlewareBox<
            Inner.RequestContext.Base, Inner.Reader, Inner.ResponseSender
        >
        .pending(
            request: request,
            requestContext: base,
            // No route: this layer folds *around* `inner.handle`, and the router matches inside it. `nil`
            // is the honest answer and a distinguishable one — an empty `RouteContext` would claim a
            // parameterless match that has not happened.
            route: nil,
            reader: reader,
            responseSender: responseSender,
            // The courier's registry, not a fresh one — this is what makes a global middleware's
            // contribution reach a route's terminal, which builds its own box further down.
            responseHeaders: registry
        )
        try await chain.intercept(input: box) { finalBox in
            try await finalBox.withPendingContents { request, base, _, reader, responseSender, registry in
                // Rebuild the courier from the base and the registry the box hands back, so the routes
                // below receive the one the global middleware contributed to.
                try await inner.handle(
                    request: request,
                    requestContext: Inner.RequestContext(base: base, responseHeaders: registry),
                    reader: reader,
                    responseSender: responseSender
                )
            }
        }
    }
}
