import AsyncStreaming
public import HTTPAPIs
public import HTTPTypes

/// A request context that carries the response-header registry — the capability the front layer reads to
/// build its box, so it never has to name the concrete courier.
///
/// `SendableMetatype` for the same reason ``HTTPServerRouteBuilder`` is: every generated route closure
/// reads `requestContext.responseHeaders` inside an `@escaping @Sendable` handler, which carries this
/// conformance across. The two together are what make the generated file quiet — the builder covers the
/// closure's own generic environment, this covers the context it reaches through.
public protocol ResponseHeaderCarrying: HTTPServerCapability.RequestContext, SendableMetatype, ~Copyable {
    /// The app's real context, underneath the courier — what a route's box is built over, so nothing below
    /// routing meets the courier.
    associatedtype Base: HTTPServerCapability.RequestContext & ~Copyable

    var responseHeaders: ResponseHeaderRegistry { get }

    consuming func takeBase() -> Base
}

/// Carries WireMVC's per-request state from the top of the handler stack down to each route.
///
/// It exists because of one fixed boundary: `HTTPServerRequestHandler.handle` takes exactly four values
/// (request, context, reader, sender) and is the proposal's, not ours. A layer above the router that needs
/// to hand something to the routes below — the response-header registry that global middleware contribute
/// to — has no parameter to put it in. The request context is the only one of the four that is an
/// *extension point*: `HTTPServerCapability.RequestContext` is an empty marker whose whole purpose is
/// per-request capabilities. So the registry travels inside the context.
///
/// It is a **courier, not a carrier**. Route and controller middleware reach the registry off the
/// *box* (``RequestResponseMiddlewareBox/responseHeaders``), which is where it has always been; this type
/// only gets it across `handle`. The generated register closure therefore reads the registry, calls
/// ``takeBase()``, and builds the route's box over the **unwrapped** context — so nothing below routing
/// ever meets this type, a context-transforming middleware wraps the app's real context rather than this,
/// and the capability-forwarding conformances the plugin emits stay one layer shallower.
///
/// > Note: `public` is forced, not chosen. Whichever way the courier reaches the router — the app's
/// > `createRouteBuilder(for:)` naming its builder's context type, or an adapter `HTTPServer` supplying it
/// > — the naming type is public, and a public conformance to a public protocol must have public
/// > associated-type witnesses. Nothing in an app should mention this type otherwise.
public struct WireMVCContext<Base: HTTPServerCapability.RequestContext & ~Copyable>:
    ResponseHeaderCarrying, ~Copyable
{
    /// Where middleware above the router contribute response header fields. Copyable, so it can be read
    /// borrowing before the courier is consumed.
    public let responseHeaders: ResponseHeaderRegistry

    private var base: Base

    public init(base: consuming Base, responseHeaders: ResponseHeaderRegistry) {
        self.base = base
        self.responseHeaders = responseHeaders
    }

    /// Consume the courier and hand back the app's real context — the "drop the envelope" half of the
    /// generated register closure. Modelled on ``WireDisconnected/take()``: a linear value handed out of a
    /// consuming method, which is the only way to move a `~Copyable` stored property out.
    public consuming func takeBase() -> Base {
        let value = consume base
        return value
    }
}

/// The handler that puts the courier on, once per request, at the top of the stack.
///
/// It conforms with `RequestContext == Base` while its `Inner` conforms with `WireMVCContext<Base>` —
/// different types on different conformances, which is what lets it wrap where
/// ``GlobalMiddlewareHandler`` cannot (that one pins its associated types *equal* to its inner's, so it
/// can only observe).
///
/// Always present, even with no global middleware: one runtime concept beats two emission shapes, and the
/// cost is a single allocation per request.
public struct WireMVCContextHandler<
    Inner: HTTPServerRequestHandler,
    Base: HTTPServerCapability.RequestContext & ~Copyable
>: HTTPServerRequestHandler
where
    Inner.RequestContext == WireMVCContext<Base>,
    Inner.Reader: ~Copyable,
    Inner.ResponseSender: ~Copyable,
    Inner.ResponseSender.Writer: ~Copyable
{
    public typealias RequestContext = Base
    public typealias Reader = Inner.Reader
    public typealias ResponseSender = Inner.ResponseSender

    let inner: Inner

    public init(inner: Inner) {
        self.inner = inner
    }

    public func handle(
        request: HTTPRequest,
        requestContext: consuming Base,
        reader: consuming sending Inner.Reader,
        responseSender: consuming sending Inner.ResponseSender
    ) async throws {
        let courier = WireMVCContext(base: requestContext, responseHeaders: ResponseHeaderRegistry())
        try await inner.handle(
            request: request,
            requestContext: courier,
            reader: reader,
            responseSender: responseSender
        )
    }
}

/// Presents a real `HTTPServer` as one whose `RequestContext` is the courier, putting the courier on
/// inside `serve(handler:)`.
///
/// This is the reason a `@WireMVCBootstrap` needs no edit: `createServer()` and
/// `createRouteBuilder(for:)` are written generically over `Server`/`Server.RequestContext`, so handing
/// them this instead of the raw server makes the whole stack — builder, router, front layer, routes —
/// generic over the courier without the app spelling it anywhere.
///
/// It does *not* keep ``WireMVCContext`` internal, which was the original hope: a public conformance to a
/// public protocol must have public associated-type witnesses, so the courier is public either way.
public struct WireMVCContextServer<Base: HTTPServer>: HTTPServer
where
    Base.RequestContext: ~Copyable,
    Base.Reader: ~Copyable,
    Base.ResponseSender: ~Copyable,
    Base.ResponseSender.Writer: ~Copyable
{
    public typealias RequestContext = WireMVCContext<Base.RequestContext>
    public typealias Reader = Base.Reader
    public typealias ResponseSender = Base.ResponseSender

    /// The server underneath. Exposed so a caller that needs to describe the *real* server — the test
    /// harness building a client for the bound port — can reach past the wrapper.
    public let base: Base

    public init(_ base: consuming Base) {
        self.base = base
    }

    public func serve<Handler: HTTPServerRequestHandler>(handler: Handler) async throws
    where
        Handler.RequestContext: ~Copyable,
        Handler.RequestContext == RequestContext,
        Handler.Reader == Reader,
        Handler.Reader: ~Copyable,
        Handler.ResponseSender == ResponseSender,
        Handler.ResponseSender: ~Copyable
    {
        try await base.serve(handler: WireMVCContextHandler(inner: handler))
    }
}

/// A response sender that applies contributed header fields to whatever head is written through it.
///
/// The typed terminal injects contributions into its ``WireMVCOutcome``; a `@RawRoute` handler has no
/// outcome — it writes its own head — so without this a middleware's contribution would silently vanish on
/// every raw route. That includes the `@NotFound` fallback, which *must* be raw, so a global middleware's
/// headers would never reach a 404.
///
/// Wrapping the sender is the only place the two shapes meet: whatever writes the head goes through
/// `send`/`sendAndFinish`, and headers are still mutable at that point. The raw handler is generic over its
/// sender, so it accepts the wrapper without knowing — the same shape `MultiPartSender` already uses.
public struct ResponseHeaderApplyingSender<Base: HTTPResponseSender & ~Copyable>: HTTPResponseSender,
    ~Copyable
where Base.Writer: ~Copyable {
    public typealias Writer = Base.Writer

    var base: Base
    let registry: ResponseHeaderRegistry

    public init(wrapping base: consuming Base, registry: ResponseHeaderRegistry) {
        self.base = base
        self.registry = registry
    }

    /// Contributions apply to the *final* head only — an informational (1xx) response is not the response.
    public mutating func sendInformational(_ response: HTTPResponse) async throws {
        try await base.sendInformational(response)
    }

    /// Writes the resolved head immediately and hands back the base sender's own writer.
    ///
    /// A streaming raw route has no length to state, so there is nothing to wait for. A *buffered* raw
    /// route reaches ``sendAndFinish(_:buffer:trailer:)`` below, which sees head and body together — but
    /// only if it is spelled with three arguments. The two-argument spelling binds to the proposal's
    /// protocol extension, which expands to `send` + `finish` and arrives here instead, where the body is
    /// not yet known.
    ///
    /// This briefly held the head back inside a writer so that path could state a length too. That has
    /// been removed: the shadowing is fixed upstream rather than worked around here, and until that lands
    /// a raw route spelled with two arguments frames as chunked. Every call site in this package uses one
    /// or three arguments and is unaffected.
    public consuming func send(_ response: HTTPResponse) async throws -> Writer {
        let resolved = try await applying(to: response)
        let inner = consume self.base
        return try await inner.send(resolved)
    }

    public consuming func sendAndFinish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        _ response: HTTPResponse,
        buffer: inout Buffer,
        trailer: HTTPFields?
    ) async throws where Buffer.Element: ~Copyable {
        var resolved = try await applying(to: response)
        // Reached only by a caller that spells `trailer:` explicitly — see ``send(_:)`` for why. Kept
        // correct anyway: a conformer that fuses head and body should not lose the length by taking the
        // faster path. Not when a trailer is present, because trailers require chunked encoding and a
        // stated length would contradict the framing the trailer forces.
        if trailer == nil { resolved.stateLengthIfAbsent(buffer.count) }
        let inner = consume self.base
        try await inner.sendAndFinish(resolved, buffer: &buffer, trailer: trailer)
    }

    /// The handler's own fields come first, so a raw route that sets `Content-Type: text/event-stream`
    /// keeps it; middleware apply over the top, as they do for a typed route's outcome.
    private borrowing func applying(to response: HTTPResponse) async throws -> HTTPResponse {
        // Contributions are applied **onto the head the handler wrote**, rather than into a fresh
        // `HTTPFields` that the handler's own fields are then replayed into.
        //
        // `resolved(returned:middleware:)` starts from empty, replays `returned` into it, then applies the
        // contributions. On this path `statics` is always empty, so replaying `returned` into an empty set
        // reproduces exactly what `response.headerFields` already is — the construction and the replay are
        // both work whose result is the input. Applying straight onto the head keeps the same order and
        // the same precedence (handler's fields first, middleware over the top) without either.
        //
        // Measured on a raw route writing two fields of its own: 2.75 → 1.92 µs and 17 → 5 allocations.
        // The empty-contribution guard matters as much — a raw route on a graph with no contributing
        // middleware then copies nothing at all.
        var resolved = response
        try await registry.drain(into: &resolved.headerFields)
        return resolved
    }
}
