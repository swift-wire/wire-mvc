public import AsyncStreaming
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
    public typealias Writer = ResponseHeaderApplyingWriter<Base>

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

    /// Resolves the head but **does not write it**, handing both to the writer instead.
    ///
    /// The deferral is what lets a raw route state a `Content-Length`, and it is needed because of an
    /// overload-resolution trap rather than a design choice. The proposal declares
    /// `sendAndFinish(_:buffer:trailer:)` as a requirement *and* supplies a same-signature extension with
    /// `trailer` defaulted; a two-argument call — the spelling nearly every raw route uses — can only match
    /// the extension, which expands to `send(_:)` + `finish(_:)` and never reaches a conformer's override.
    /// So the three-argument witness below is unreachable from ordinary raw-route code, and the only place
    /// left that sees the head *and* the whole body is the writer's `finish`.
    ///
    /// The cost: a raw route that streams sees its head flushed on the first `write` rather than on `send`.
    /// Typed routes are unaffected (``WireMVCOutcome`` states its own length before sending) and so are
    /// transformed-sender routes like SSE and multipart, which are not wrapped at all.
    public consuming func send(_ response: HTTPResponse) async throws -> Writer {
        let resolved = try await applying(to: response)
        let inner = consume self.base
        return ResponseHeaderApplyingWriter(deferring: resolved, to: inner)
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

/// The writer ``ResponseHeaderApplyingSender/send(_:)`` returns, holding the resolved head until it knows
/// whether the body is streamed or complete.
///
/// Two outcomes, and the state machine exists only to tell them apart:
///
/// - `finish` before any `write` — the whole body is in hand, so the head can state a `Content-Length` and
///   head and body go out in a single call on the base sender.
/// - `write` first — the body is streamed, no length can be known, so the head is flushed as it stands and
///   everything after it forwards to the base writer.
public struct ResponseHeaderApplyingWriter<Base: HTTPResponseSender & ~Copyable>: CallerAsyncWriter,
    ~Copyable
where Base.Writer: ~Copyable {
    public typealias WriteElement = UInt8
    /// `any Error`, not the base writer's failure type: flushing a deferred head calls `Base.send`, whose
    /// errors are untyped, so this writer can fail in ways the base writer alone cannot.
    public typealias WriteFailure = any Error
    public typealias FinalElement = HTTPFields?

    private enum State: ~Copyable {
        /// The head is resolved but unwritten, and the base sender is still whole.
        case deferred(Base, HTTPResponse)
        /// The head is written; the base writer owns the rest.
        case flushed(Base.Writer)
        /// Transient. The value is in flight inside a `write`, so the property is reinitialised before any
        /// `await` rather than after it — a throw part-way through a transition must not leave `self`
        /// consumed. Reaching it means a previous `write` failed, and the request is already failing.
        case inFlight
    }

    private var state: State

    init(deferring head: HTTPResponse, to base: consuming Base) {
        self.state = .deferred(base, head)
    }

    private init(state: consuming State) {
        self.state = state
    }

    public mutating func write<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer
    ) async throws(WriteFailure) where Buffer.Element: ~Copyable {
        // `self`, not `self.state`: consuming a stored property leaves `self` partially initialised, and
        // only a whole-value reinitialisation puts it back. The placeholder goes in before the first
        // `await` so a throw part-way through a transition cannot leave `self` consumed.
        let taken = consume self.state
        self = Self(state: .inFlight)
        switch taken {
        case .deferred(let base, let head):
            // A streamed body: the length is genuinely unknown here, so the head goes as it stands.
            var writer = try await base.send(head)
            try await writer.write(buffer: &buffer)
            self = Self(state: .flushed(writer))
        case .flushed(var writer):
            try await writer.write(buffer: &buffer)
            self = Self(state: .flushed(writer))
        case .inFlight:
            fatalError("ResponseHeaderApplyingWriter written to after a write failed part-way through")
        }
    }

    public consuming func finish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer,
        finalElement: consuming FinalElement
    ) async throws(WriteFailure) where Buffer.Element: ~Copyable {
        switch consume state {
        case .deferred(let base, var head):
            let trailer = finalElement
            // No `write` came first, so this buffer is the whole body. A trailer forces chunked framing,
            // so a length is stated only without one.
            if trailer == nil { head.stateLengthIfAbsent(buffer.count) }
            try await base.sendAndFinish(head, buffer: &buffer, trailer: trailer)
        case .flushed(let writer):
            try await writer.finish(buffer: &buffer, finalElement: finalElement)
        case .inFlight:
            fatalError("ResponseHeaderApplyingWriter finished after a write failed part-way through")
        }
    }
}
