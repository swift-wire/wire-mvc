public import AsyncStreaming
public import HTTPAPIs
public import HTTPTypes
public import WireMVC

/// The batteries-included router for the WireMVC-native (proposal-server) path — a path-segment trie.
/// Build → freeze → serve: `TrieRouteBuilder` is the mutable `FinalizableHTTPServerRouteBuilder`
/// (`WireMVC.apply` registers routes onto it); `finalize()` compacts it into the immutable
/// `FrozenTrieRouter`, which *is* the proposal's `HTTPServerRequestHandler` the server serves. A
/// `@WireMVCBootstrap` composition root returns this from `createRouteBuilder(for:)`.
///
/// WireMVC's core stays router-agnostic — it registers onto *any* builder; this is the router the
/// native path uses when the app doesn't bring its own. Generic over the server's associated types (the
/// one place the `~Copyable` streaming machinery is threaded); the routing algorithm lives in the
/// non-generic ``RouteTrie``/``FrozenRouteTrie``.
public struct TrieRouteBuilder<
    RequestContext: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable & SendableMetatype,
    ResponseSender: HTTPResponseSender & ~Copyable & SendableMetatype
>: FinalizableHTTPServerRouteBuilder
where
    Reader.ReadElement == UInt8,
    Reader.FinalElement == HTTPFields?,
    ResponseSender.Writer: ~Copyable
{
    public typealias Handler =
        @Sendable (
            HTTPRequest,
            consuming RequestContext,
            [String: Substring],
            consuming sending Reader,
            consuming sending ResponseSender
        ) async throws -> Void

    /// A 405 handler. Same shape as `Handler` but for the allowed-method list in place of path
    /// parameters: a 405 matched no template, so there is nothing to bind, and it owes an `Allow`.
    public typealias MethodNotAllowedHandler =
        @Sendable (
            HTTPRequest,
            consuming RequestContext,
            [HTTPRequest.Method],
            consuming sending Reader,
            consuming sending ResponseSender
        ) async throws -> Void

    private var trie = RouteTrie()
    /// How a request's trailing slash is treated. An app chooses it where it builds the router — its
    /// `createRouteBuilder(for:)` — because it is a property of the app's URL contract, not of a route.
    private let trailingSlash: TrailingSlashPolicy
    private var handlers: [Handler] = []
    /// The fallback dispatched to on an unmatched request. `nil` until `registerNotFound`;
    /// the frozen router answers a built-in 404 when it stays `nil`.
    private var notFoundHandler: Handler?
    /// The handler for a matched path with an unmatched method. `nil` until `registerMethodNotAllowed`;
    /// the frozen router answers a built-in — and contribution-less — 405 when it stays `nil`.
    private var methodNotAllowedHandler: MethodNotAllowedHandler?

    public init(trailingSlash: TrailingSlashPolicy = .lenient) {
        self.trailingSlash = trailingSlash
    }

    /// Infer the router's associated types from the server it will serve on, so callers needn't spell
    /// `TrieRouteBuilder<Server.RequestContext, …>` by hand. The inverse (`~Copyable`) requirements are
    /// restated because they don't propagate across the generic boundary on their own.
    public init<Server: HTTPServer>(
        for server: borrowing Server,
        trailingSlash: TrailingSlashPolicy = .lenient
    )
    where
        Server.RequestContext == RequestContext,
        Server.Reader == Reader,
        Server.ResponseSender == ResponseSender,
        Server.RequestContext: ~Copyable,
        Server.Reader: ~Copyable,
        Server.ResponseSender: ~Copyable,
        Server.ResponseSender.Writer: ~Copyable
    {
        self.init(trailingSlash: trailingSlash)
    }

    public mutating func register(
        method: HTTPRequest.Method,
        path: String,
        handler: @escaping Handler
    ) {
        switch trie.insert(method: method, path: path) {
        case let .inserted(index):
            precondition(index == handlers.count, "RouteTrie index and handler array drifted")
            handlers.append(handler)

        case let .duplicate(existing):
            // Fatal at registration, which is startup: a duplicate has no recovery that is not worse than
            // stopping. Accepting it silently — what this replaces — left the second route unreachable,
            // so a controller's route went dead with nothing said, and the failure surfaced later as a
            // 404 on a route that visibly exists in the source.
            //
            // `existing` may read differently from `path`: a node has one parameter edge and the first
            // name wins, so `/users/{id}` and `/users/{name}` are the same node. Naming both is what makes
            // that case legible rather than baffling.
            let collision =
                existing == path
                ? "'\(path)' is registered twice"
                : "'\(path)' collides with '\(existing)' — they differ only in parameter *names*, "
                    + "which a router cannot tell apart, so only the first would ever be reached"
            preconditionFailure("duplicate route: \(method.rawValue) \(collision).")

        case let .catchAllNotLast(segment):
            preconditionFailure(
                "route '\(path)': '\(segment)' claims the rest of the path, so the segments after it can "
                    + "never match. A catch-all must be the last segment."
            )

        case let .unsupportedSegment(segment):
            // The recursive catch-all `{name*}` is supported; these are the *other* wildcard shapes —
            // Hummingbird's bare `*`, `*.jpg`, `file.*`. They have no meaning here, and left unchecked
            // they read as ordinary parameters, which is a mis-route rather than an error.
            preconditionFailure(
                "route '\(path)' uses '\(segment)': the only wildcard WireMVC route templates express is "
                    + "the trailing catch-all, '{name*}'. Register the concrete paths, or serve this shape "
                    + "with the host framework's own router."
            )
        }
    }

    public mutating func registerNotFound(handler: @escaping Handler) {
        notFoundHandler = handler
    }

    public mutating func registerMethodNotAllowed(handler: @escaping MethodNotAllowedHandler) {
        methodNotAllowedHandler = handler
    }

    /// Freeze the trie and pair it with the handler array — the immutable handler the server serves.
    public consuming func finalize() -> FrozenTrieRouter<RequestContext, Reader, ResponseSender> {
        FrozenTrieRouter(
            trie: trie.freeze(trailingSlash: trailingSlash),
            handlers: handlers,
            notFoundHandler: notFoundHandler,
            methodNotAllowedHandler: methodNotAllowedHandler
        )
    }
}

/// The immutable, servable router — *is* the proposal's `HTTPServerRequestHandler`. Resolves the
/// request path through the frozen trie (binary-searched literal children) and dispatches the matched
/// method's handler, answers `405` with `Allow` when the path exists but the method does not, or falls
/// back to `404`.
public struct FrozenTrieRouter<
    RequestContext: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable & SendableMetatype,
    ResponseSender: HTTPResponseSender & ~Copyable & SendableMetatype
>: HTTPServerRequestHandler
where
    Reader.ReadElement == UInt8,
    Reader.FinalElement == HTTPFields?,
    ResponseSender.Writer: ~Copyable
{
    let trie: FrozenRouteTrie
    let handlers: [TrieRouteBuilder<RequestContext, Reader, ResponseSender>.Handler]
    /// The fallback for unmatched requests; the built-in 404 below is used only when it's `nil` (an app
    /// that never called `registerNotFound`).
    let notFoundHandler: TrieRouteBuilder<RequestContext, Reader, ResponseSender>.Handler?
    /// The 405 handler, registered by the generated `@main`. It has a `ResponseHeaderCarrying` context and
    /// so can drain the registry — which is why the head is written there rather than here.
    let methodNotAllowedHandler: TrieRouteBuilder<RequestContext, Reader, ResponseSender>.MethodNotAllowedHandler?

    public func handle(
        request: HTTPRequest,
        requestContext: consuming RequestContext,
        reader: consuming sending Reader,
        responseSender: consuming sending ResponseSender
    ) async throws {
        // Resolve without consuming, so the reader and sender are consumed exactly once — by the
        // matched handler, the fallback, the built-in 404, or the 405.
        switch trie.resolve(method: request.method, path: request.path ?? "/") {
        case let .matched(index, parameters):
            try await handlers[index](request, requestContext, parameters, reader, responseSender)

        case let .methodNotAllowed(allowed):
            // Dispatched to its own handler rather than to `notFoundHandler`: that fallback is the app's
            // *404* — `@NotFound` — and routing a 405 into it would present "no such resource" for a
            // resource that exists. `Allow` is required on a 405 by RFC 9110 §15.5.6.
            //
            // The registered handler writes the head because it can drain the request context's
            // `ResponseHeaderRegistry`; this router cannot, not being constrained to a
            // `ResponseHeaderCarrying` context. Without one — a hand-written builder that registers none —
            // the fallback below is correct but bare, so a global `@Middleware`'s CORS or security headers
            // would be missing from it.
            if let methodNotAllowedHandler {
                try await methodNotAllowedHandler(request, requestContext, allowed, reader, responseSender)
            } else {
                var fields = HTTPFields()
                fields[.allow] = allowed.map(\.rawValue).joined(separator: ", ")
                var response = HTTPResponse(status: .methodNotAllowed, headerFields: fields)
                // Bodiless, but a known length all the same — see `stateLengthIfAbsent`. A synthesised
                // miss is written here rather than through a `WireMVCOutcome`, so it needs saying twice.
                response.stateLengthIfAbsent(0)
                try await responseSender.sendAndFinish(response)
            }

        case .notFound:
            if let notFoundHandler {
                try await notFoundHandler(request, requestContext, [:], reader, responseSender)
            } else {
                var response = HTTPResponse(status: .notFound)
                response.stateLengthIfAbsent(0)
                try await responseSender.sendAndFinish(response)
            }
        }
    }
}
