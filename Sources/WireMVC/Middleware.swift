// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

public import AsyncStreaming
public import HTTPAPIs
public import HTTPTypes
public import Middleware

/// The box a middleware chain carries as its `Middleware.Input`/`NextInput`. It is a two-state value:
/// `pending` holds the handler inputs (a fixed request, the per-request `RequestContext`, the matched
/// ``RouteContext``, the request `Reader`) plus the one-shot `ResponseSender`; `responded` means a
/// middleware already wrote the response — the sender is consumed and gone, and only the request and the
/// route are kept so always-run observe middleware can still read them.
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
            route: RouteContext?,
            reader: WireDisconnected<Reader>,
            responseSender: WireDisconnected<ResponseSender>,
            responseHeaders: WireDisconnected<ResponseHeaderRegistry>
        )
        /// **No registry.** Once a middleware has written the response the head is on the wire, and
        /// nothing drains the registry again — ``respondingWith(_:)`` drains on its way out, raw
        /// ``responding(_:)`` never drains, and a route terminal reaches its drain through
        /// ``withPendingContents(_:)``, which does nothing in this state. Carrying one here would let a
        /// middleware contribute a field that could not reach any response; leaving it out makes that
        /// unwriteable rather than documented.
        case responded(request: HTTPRequest, route: RouteContext?)
    }

    var storage: Storage

    init(_ storage: consuming Storage) {
        self.storage = storage
    }

    /// Still to be handled: the handler inputs, the one-shot sender and the registry. Takes the
    /// reader/sender and the registry as raw `consuming sending` values and wraps them.
    ///
    /// `route` is `nil` above the router — the global tier folds around `handle`, before any match has
    /// happened — and the matched ``RouteContext`` below it. It is a required argument rather than a
    /// defaulted one for the reason the registry is: a transforming middleware rebuilds the box through
    /// ``withContents(pending:responded:)``, and dropping the route there would silently unname the
    /// route for everything further in.
    public static func pending(
        request: HTTPRequest,
        requestContext: consuming RequestContext,
        route: RouteContext?,
        reader: consuming sending Reader,
        responseSender: consuming sending ResponseSender,
        responseHeaders: consuming sending ResponseHeaderRegistry
    ) -> Self {
        Self(
            .pending(
                request: request,
                requestContext: requestContext,
                route: route,
                reader: WireDisconnected(reader),
                responseSender: WireDisconnected(responseSender),
                responseHeaders: WireDisconnected(responseHeaders)
            )
        )
    }

    /// A middleware has written the response; the sender is consumed and the registry is spent. The
    /// request and the route are kept for observation — an always-run observer wants to log *which
    /// route* was gated as much as it wants the request that asked for it.
    public static func responded(request: HTTPRequest, route: RouteContext?) -> Self {
        Self(.responded(request: request, route: route))
    }

    /// A borrowing peek at the request — readable in either state — so a middleware can inspect it
    /// without consuming the box (it still has to pass the box to `next`).
    public var peekedRequest: HTTPRequest {
        switch storage {
        case .pending(let request, _, _, _, _, _): return request
        case .responded(let request, _): return request
        }
    }

    /// A borrowing peek at the matched route — readable in either state, alongside ``peekedRequest``.
    ///
    /// `nil` and empty are deliberately different answers. `nil` means *there is no route*: the box is
    /// above the router, where the global tier folds and no match has happened yet. A non-`nil`
    /// ``RouteContext`` with empty `pathParameters` means *this route matched and declares none*.
    /// Collapsing the two into an empty dictionary would make "outside the router" indistinguishable
    /// from "a route with no parameters", which is exactly the question a per-route rule asks.
    public var peekedRoute: RouteContext? {
        switch storage {
        case .pending(_, _, let route, _, _, _): return route
        case .responded(_, let route): return route
        }
    }

    /// Whether the request is still to be handled (no middleware has responded yet).
    public var isPending: Bool {
        switch storage {
        case .pending: return true
        case .responded: return false
        }
    }

    /// Contribute response header fields and carry on — the shape almost every contributing middleware
    /// wants, over the same primitive ``withContents(pending:responded:)`` a transforming one uses.
    ///
    /// `contribute` is handed the registry `inout`, so several fields (and conditional ones — a CORS
    /// policy contributes up to four, each behind its own test) are added in one pass rather than nested
    /// one call deep each. `body` then receives the rebuilt box, so a middleware that wants to
    /// short-circuit after contributing can call ``respondingWith(_:)`` on what it is given.
    ///
    /// > Note: when the box is already `responded` there is no registry to contribute to — the response
    /// > is written — so `contribute` is **not called** and `body` receives the `responded` box unchanged.
    /// > This is the one place that case is absorbed rather than spelled out, which is why it is stated
    /// > here: an always-run observer contributes unconditionally and cannot know a gate outside it
    /// > already answered. Reach for ``withContents(pending:responded:)`` to handle the two apart.
    public consuming func contributing<Return: ~Copyable>(
        _ contribute: (inout ResponseHeaderRegistry) throws -> Void,
        then body: nonisolated(nonsending) (consuming Self) async throws -> Return
    ) async throws -> Return {
        switch consume storage {
        case .pending(let request, let requestContext, let route, let reader, let responseSender, let responseHeaders):
            var registry = responseHeaders.take()
            try contribute(&registry)
            return try await body(
                .pending(
                    request: request,
                    requestContext: requestContext,
                    route: route,
                    reader: reader.take(),
                    responseSender: responseSender.take(),
                    responseHeaders: registry
                )
            )
        case .responded(let request, let route):
            return try await body(.responded(request: request, route: route))
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
        case .pending(let request, _, let route, _, let responseSender, _):
            try await write(responseSender.take())
            return .responded(request: request, route: route)
        case .responded(let request, let route):
            return .responded(request: request, route: route)
        }
    }

    /// The gate's blessed spelling: respond with a ``WireMVCOutcome``, draining the contributed header
    /// fields into it first.
    ///
    /// A gate short-circuits the terminal, so the terminal's drain never runs — without this, every
    /// middleware-contributed field would vanish on exactly the paths that most want them (a `401` wanting
    /// its `WWW-Authenticate`, a redirect wanting a session cookie set on the way out). Contributions
    /// registered by middleware *outside* this one are included; ones further in never ran, and after this
    /// there is no registry left to contribute to.
    public consuming func respondingWith(_ outcome: consuming WireMVCOutcome) async throws -> Self {
        switch consume storage {
        case .pending(let request, _, let route, _, let responseSender, let responseHeaders):
            let registry = responseHeaders.take()
            var resolved = outcome
            resolved.headerFields = WireMVCResponseHeaders.resolved(
                returned: resolved.headerFields,
                middleware: try await registry.drain()
            )
            try await resolved.send(on: responseSender.take())
            return .responded(request: request, route: route)
        case .responded(let request, let route):
            return .responded(request: request, route: route)
        }
    }

    /// The generated terminal's destructure: run `handler` with the pending contents, or do nothing if a
    /// middleware already responded. The reader/sender and the registry are handed out `sending` (see
    /// ``WireDisconnected``), so the terminal can forward them to another `HTTPServerRequestHandler` — and
    /// so the registry the terminal wraps its sender with is the one the box hands back rather than a
    /// captured local, which is what keeps the composite disconnected.
    public consuming func withPendingContents(
        _ handler:
            nonisolated(nonsending) (
                HTTPRequest,
                consuming RequestContext,
                RouteContext?,
                consuming sending Reader,
                consuming sending ResponseSender,
                consuming sending ResponseHeaderRegistry
            ) async throws -> Void
    ) async throws {
        switch consume storage {
        case .pending(let request, let requestContext, let route, let reader, let responseSender, let responseHeaders):
            try await handler(
                request,
                requestContext,
                route,
                reader.take(),
                responseSender.take(),
                responseHeaders.take()
            )
        case .responded:
            break
        }
    }

    /// The primitive both a transforming middleware and ``contributing(_:then:)`` are built on — the
    /// structured replacement for pattern-matching the box directly (the cases are internal). Consumes the
    /// box into its raw contents, handing the reader/sender and the registry out `sending`, and returns
    /// whatever each branch's `next`-based body produces: `pending` rebuilds and forwards a (possibly
    /// retyped) box, `responded` forwards the already-written state, which carries no registry to thread.
    public consuming func withContents<Return: ~Copyable>(
        pending:
            nonisolated(nonsending) (
                HTTPRequest,
                consuming RequestContext,
                RouteContext?,
                consuming sending Reader,
                consuming sending ResponseSender,
                consuming sending ResponseHeaderRegistry
            ) async throws -> Return,
        responded:
            nonisolated(nonsending) (HTTPRequest, RouteContext?) async throws -> Return
    ) async throws -> Return {
        switch consume storage {
        case .pending(let request, let requestContext, let route, let reader, let responseSender, let responseHeaders):
            return try await pending(
                request,
                requestContext,
                route,
                reader.take(),
                responseSender.take(),
                responseHeaders.take()
            )
        case .responded(let request, let route):
            return try await responded(request, route)
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
