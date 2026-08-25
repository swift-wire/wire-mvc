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
    Chain.Input == RequestResponseMiddlewareBox<Inner.RequestContext, Inner.Reader, Inner.ResponseSender>,
    Chain.NextInput == Chain.Input,
    // The front layer's box must carry the *same* registry the routes below will drain, so it reads it off
    // the context rather than making one. Stated as a capability so this stays generic over the context.
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
        let registry = requestContext.responseHeaders
        let box = RequestResponseMiddlewareBox<Inner.RequestContext, Inner.Reader, Inner.ResponseSender>
            .pending(
                request: request,
                requestContext: requestContext,
                reader: reader,
                responseSender: responseSender,
                // The courier's registry, not a fresh one — this is what makes a global middleware's
                // contribution reach a route's terminal, which builds its own box further down.
                responseHeaders: registry
            )
        try await chain.intercept(input: box) { finalBox in
            try await finalBox.withPendingContents { request, requestContext, reader, responseSender in
                try await inner.handle(
                    request: request,
                    requestContext: requestContext,
                    reader: reader,
                    responseSender: responseSender
                )
            }
        }
    }
}
