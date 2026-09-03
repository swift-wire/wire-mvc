public import AsyncStreaming
public import HTTPAPIs
public import HTTPTypes

/// The registration surface `@Controller`'s generated witness targets, and what `WireMVC.apply`
/// registers onto. It keeps the server's associated `RequestContext`/`Reader`/`ResponseSender` (they
/// must match the server's, per `HTTPServer.serve`'s `Handler.Reader == Reader`), so it is never
/// boxed as `any`. WireMVC stays router-agnostic — it depends only on this protocol; a concrete
/// builder (also an `HTTPServerRequestHandler`, so it can serve) is supplied by the caller.
///
/// `SendableMetatype` because `register`'s handler is `@escaping @Sendable`: a generated witness is
/// generic over the builder, so every route closure it registers carries `Builder`'s metadata and
/// conformances into a concurrent context. Without the refinement each one is a warning the consumer
/// cannot act on — the closure is generated, and the conformance it is being warned about is WireMVC's.
/// Stated on the protocol rather than on each generic parameter so an app's `createRouteBuilder(for:)`
/// keeps the signature it already has, and an opaque `some FinalizableHTTPServerRouteBuilder<…>` return
/// carries the guarantee. It costs a conformer nothing: a concrete type satisfies it implicitly, and so
/// does a generic one — only a *generic parameter* standing in for a builder would have to say so.
public protocol HTTPServerRouteBuilder<RequestContext, Reader, ResponseSender>: SendableMetatype {
    associatedtype RequestContext: HTTPServerCapability.RequestContext, ~Copyable
    associatedtype Reader: AsyncReader, ~Copyable, SendableMetatype
    where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?
    associatedtype ResponseSender: HTTPResponseSender, ~Copyable, SendableMetatype
    where ResponseSender.Writer: ~Copyable

    /// Register one route. `handler` receives the request, the server's per-request `RequestContext`,
    /// the matched path parameters, the request body reader, and the response sender. WireMVC owns this
    /// shape: the proposal's handler signature has no slot for matched path parameters, so the router
    /// extracts them from the path template and passes them in. The `RequestContext` is threaded so a
    /// raw handler can read the server's capabilities, and so middleware can seed its box from it.
    mutating func register(
        method: HTTPRequest.Method,
        path: String,
        handler:
            @escaping @Sendable (
                HTTPRequest,
                consuming RequestContext,
                [String: Substring],
                consuming sending Reader,
                consuming sending ResponseSender
            ) async throws -> Void
    )
}

/// A `HTTPServerRouteBuilder` for the native (proposal-server) path that **finalizes** — once all
/// routes are registered — into an immutable `HTTPServerRequestHandler` to serve. This is the
/// build → freeze → serve lifecycle: the mutable builder collects routes; `finalize()` compacts them
/// into an optimized immutable handler (e.g. a frozen trie with binary-searchable literal children). A
/// `@WireMVCBootstrap` composition root's `createRouteBuilder(for:)` returns one of these; the
/// generated `@main` registers the collated routes, then `finalize()`s and serves the result. It
/// refines the router-agnostic core so the `ServerTransport` adapter path (which doesn't serve via
/// `HTTPServerRequestHandler`) stays unaffected.
public protocol FinalizableHTTPServerRouteBuilder<RequestContext, Reader, ResponseSender>:
    HTTPServerRouteBuilder
{
    associatedtype ServingHandler: HTTPServerRequestHandler
    where
        ServingHandler.RequestContext: ~Copyable,
        ServingHandler.RequestContext == RequestContext,
        ServingHandler.Reader: ~Copyable,
        ServingHandler.Reader == Reader,
        ServingHandler.ResponseSender: ~Copyable,
        ServingHandler.ResponseSender == ResponseSender,
        ServingHandler.ResponseSender.Writer: ~Copyable

    /// Register the fallback handler for **unmatched** requests — what the router dispatches to when no
    /// route matches (any method, any path), instead of its built-in 404. Same handler shape as
    /// `register`, with empty path parameters (there is no template). The `@WireMVCBootstrap` generated
    /// `@main` calls this with the app's `@NotFound` handler (or a synthesized 404) *before* `finalize()`,
    /// so the fallback is a real route — it folds in the global middleware/error tiers like any other
    /// Unregistered (a hand-written app), the router answers a built-in 404.
    mutating func registerNotFound(
        handler:
            @escaping @Sendable (
                HTTPRequest,
                consuming RequestContext,
                [String: Substring],
                consuming sending Reader,
                consuming sending ResponseSender
            ) async throws -> Void
    )

    /// Register the handler for a request whose **path matched but whose method did not** — the `405`
    /// counterpart to `registerNotFound`.
    ///
    /// Separate from the 404 fallback because it is a different answer: the resource exists, and the
    /// response owes an `Allow` listing what it does accept, which is the third parameter (the router's
    /// resolved set, deduplicated and sorted). Routing a 405 through `registerNotFound` would present
    /// "no such resource" for a resource that is right there.
    ///
    /// It exists for the same reason `registerNotFound` does: whatever writes a head must drain the
    /// request context's `ResponseHeaderRegistry`, or a global `@Middleware`'s CORS and security headers
    /// go missing from exactly the responses nobody declares. A router cannot do that draining itself —
    /// it is not constrained to a `ResponseHeaderCarrying` context — so the generated `@main` supplies a
    /// handler that can.
    ///
    /// Required rather than defaulted: a no-op default would let a new builder silently answer bare 405s,
    /// which is the exact bug this exists to close.
    mutating func registerMethodNotAllowed(
        handler:
            @escaping @Sendable (
                HTTPRequest,
                consuming RequestContext,
                [HTTPRequest.Method],
                consuming sending Reader,
                consuming sending ResponseSender
            ) async throws -> Void
    )

    /// Compact the registered routes into the immutable handler that serves them.
    consuming func finalize() -> ServingHandler
}
