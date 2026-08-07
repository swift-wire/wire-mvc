public import AsyncStreaming
public import HTTPAPIs
public import HTTPTypes
public import Middleware

/// The box a middleware chain carries as its `Middleware.Input`/`NextInput`. It is a two-state value:
/// `pending` holds the handler inputs (a fixed request, the per-request `RequestContext`, the request
/// `Reader`) plus the one-shot `ResponseSender`; `responded` means a middleware already wrote the
/// response — the sender is consumed and gone, and only the request is kept so always-run observe
/// middleware can still read it.
///
/// This shape is a *consequence* of the proposal's `Middleware.intercept<Return>(input:next:) -> Return`:
/// the only value of type `Return` is what `next` produces, so every middleware must call `next` (no
/// control-flow short-circuit). A middleware that wants to respond therefore does so by *writing* via
/// the sender and moving the box to `responded`, and the whole chain still runs — the terminal simply
/// skips the handler when the box is already `responded`. Changing that (letting inner middleware be
/// skipped) would require changing the middleware *shape*, not this box. See Notes/WireMVCMiddleware.md.
///
/// It is WireMVC-owned (the proposal ships its own box only in a test module, referenced by nothing and
/// pulling the whole NIO server stack); the middleware themselves stay the proposal's `Middleware`.
public struct RequestResponseMiddlewareBox<
    RequestContext: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    ResponseSender: HTTPResponseSender & ~Copyable
>: ~Copyable
where
    Reader.ReadElement == UInt8,
    Reader.FinalElement == HTTPFields?,
    ResponseSender.Writer: ~Copyable
{
    /// The box's two-state storage. The linear `reader`/`responseSender` ride in ``WireDisconnected`` so they
    /// survive extraction as `sending` — which is what lets a folded terminal hand them to an
    /// `HTTPServerRequestHandler` (`router.handle`, the front-layer wrapper). ``WireDisconnected`` is an
    /// internal detail: it never appears in the box's public surface. The public `pending(…)` factory wraps
    /// the raw `sending` reader/sender; the public destructures (`withPendingContents` / `withContents`)
    /// unwrap them — and route terminals take them `consuming`, which accepts a `sending` argument, so the
    /// wrapping is invisible everywhere outside this file.
    enum Storage: ~Copyable {
        case pending(
            request: HTTPRequest,
            requestContext: RequestContext,
            reader: WireDisconnected<Reader>,
            responseSender: WireDisconnected<ResponseSender>,
            responseHeaders: ResponseHeaderRegistry
        )
        case responded(request: HTTPRequest, responseHeaders: ResponseHeaderRegistry)
    }

    var storage: Storage

    init(_ storage: consuming Storage) {
        self.storage = storage
    }

    /// Still to be handled: the handler inputs and the one-shot sender. Takes the reader/sender as raw
    /// `consuming sending` values and wraps them; the generated `.pending(reader: reader, …)` call site is
    /// unchanged from when this was an enum case.
    public static func pending(
        request: HTTPRequest,
        requestContext: consuming RequestContext,
        reader: consuming sending Reader,
        responseSender: consuming sending ResponseSender,
        responseHeaders: ResponseHeaderRegistry
    ) -> Self {
        Self(
            .pending(
                request: request,
                requestContext: requestContext,
                reader: WireDisconnected(reader),
                responseSender: WireDisconnected(responseSender),
                responseHeaders: responseHeaders
            )
        )
    }

    /// A middleware has written the response; the sender is consumed. The request is kept for observation.
    public static func responded(request: HTTPRequest, responseHeaders: ResponseHeaderRegistry) -> Self {
        Self(.responded(request: request, responseHeaders: responseHeaders))
    }

    /// A borrowing peek at the request — readable in either state — so a middleware can inspect it
    /// without consuming the box (it still has to pass the box to `next`).
    public var peekedRequest: HTTPRequest {
        switch storage {
        case .pending(let request, _, _, _, _): return request
        case .responded(let request, _): return request
        }
    }

    /// Where a middleware contributes response header fields — see ``ResponseHeaderRegistry``.
    ///
    /// Borrowing and available in **both** states, like ``peekedRequest``: a middleware registers on the way
    /// in, without consuming the box, and the registry survives a gate responding so an always-run observe
    /// middleware downstream can still contribute. A class, so reaching it borrowing is enough to write to
    /// it — and so a transforming middleware rebuilding the box threads the same one rather than a copy.
    public var responseHeaders: ResponseHeaderRegistry {
        switch storage {
        case .pending(_, _, _, _, let responseHeaders): return responseHeaders
        case .responded(_, let responseHeaders): return responseHeaders
        }
    }

    /// Whether the request is still to be handled (no middleware has responded yet).
    public var isPending: Bool {
        switch storage {
        case .pending: return true
        case .responded: return false
        }
    }

    /// A middleware "handles" the request: `write` is handed the sender (consuming it) to write the
    /// response, and the box becomes `responded`. If the box is already `responded`, it is returned
    /// unchanged — first-decision-wins, enforced by there being no sender to hand over.
    /// > Important: this hands over the raw sender, so WireMVC never sees an outcome and **cannot drain the
    /// > registry** — a middleware responding this way discards every contributed header field. Use it for
    /// > streaming a response that has no outcome shape; for an ordinary gate (a 401 challenge, a redirect)
    /// > use ``respondingWith(_:)``, which drains.
    public consuming func responding(
        _ write: nonisolated(nonsending) (consuming ResponseSender) async throws -> Void
    ) async throws -> Self {
        switch consume storage {
        case .pending(let request, _, _, let responseSender, let responseHeaders):
            try await write(responseSender.take())
            return .responded(request: request, responseHeaders: responseHeaders)
        case .responded(let request, let responseHeaders):
            return .responded(request: request, responseHeaders: responseHeaders)
        }
    }

    /// The gate's blessed spelling: respond with a ``WireMVCOutcome``, draining the contributed header
    /// fields into it first.
    ///
    /// A gate short-circuits the terminal, so the terminal's drain never runs — without this, every
    /// middleware-contributed field would vanish on exactly the paths that most want them (a `401` wanting
    /// its `WWW-Authenticate`, a redirect wanting a session cookie set on the way out). Contributions
    /// registered by middleware *outside* this one are included; ones further in never ran.
    public consuming func respondingWith(_ outcome: consuming WireMVCOutcome) async throws -> Self {
        switch consume storage {
        case .pending(let request, _, _, let responseSender, let responseHeaders):
            var resolved = outcome
            resolved.headerFields = WireMVCResponseHeaders.resolved(
                returned: resolved.headerFields,
                middleware: try await responseHeaders.drain()
            )
            try await resolved.send(on: responseSender.take())
            return .responded(request: request, responseHeaders: responseHeaders)
        case .responded(let request, let responseHeaders):
            return .responded(request: request, responseHeaders: responseHeaders)
        }
    }

    /// The generated terminal's destructure: run `handler` with the pending contents, or do nothing if a
    /// middleware already responded. The reader/sender are handed out `sending` (see ``WireDisconnected``),
    /// so the terminal can forward them to another `HTTPServerRequestHandler`.
    public consuming func withPendingContents(
        _ handler:
            nonisolated(nonsending) (
                HTTPRequest,
                consuming RequestContext,
                consuming sending Reader,
                consuming sending ResponseSender
            ) async throws -> Void
    ) async throws {
        switch consume storage {
        case .pending(let request, let requestContext, let reader, let responseSender, _):
            try await handler(request, requestContext, reader.take(), responseSender.take())
        case .responded:
            break
        }
    }

    /// A transforming middleware's destructure — the structured replacement for pattern-matching the box
    /// directly (the cases are internal). Consumes the box into its raw contents, handing the reader/sender
    /// out `sending`, and returns whatever each branch's `next`-based body produces: `pending` rebuilds and
    /// forwards a (possibly retyped) box, `responded` forwards the already-written state.
    public consuming func withContents<Return: ~Copyable>(
        pending:
            nonisolated(nonsending) (
                HTTPRequest,
                consuming RequestContext,
                consuming sending Reader,
                consuming sending ResponseSender
            ) async throws -> Return,
        responded:
            nonisolated(nonsending) (HTTPRequest) async throws -> Return
    ) async throws -> Return {
        switch consume storage {
        case .pending(let request, let requestContext, let reader, let responseSender, _):
            return try await pending(request, requestContext, reader.take(), responseSender.take())
        case .responded(let request, _):
            return try await responded(request)
        }
    }
}

@available(*, unavailable)
extension RequestResponseMiddlewareBox: Sendable {}

/// Builds a route's middleware chain into a *concrete* composed `Middleware` (the `MiddlewareBuilder`
/// fold's inferred `ChainedMiddleware…` type), rather than erasing to `some Middleware`. Returning the
/// concrete type keeps the fold's final box type inferred, which is what lets the terminal call
/// `withPendingContents` on it — a `some Middleware<Input>`-with-pinned-input boundary is not expressible
/// (`Middleware` has two primary associated types), so the fold must stay witness-local and concrete.
/// The generated `registerWireRoutes` witness calls this inline with the route's middleware.
public func wireCompose<Composed: Middleware>(
    @MiddlewareBuilder _ build: () -> Composed
) -> Composed where Composed.Input: ~Copyable, Composed.NextInput: ~Copyable {
    build()
}
