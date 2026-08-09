public import HTTPTypes
public import Wire

// The WireMVC annotation surface. `@Controller` is the one macro that does work — it walks the
// controller's routes and generates the `RouteContributor` witness. The verb, param, and response
// annotations are markers `@Controller` reads (verbs/responses are no-op peer macros; the param
// bindings are `@propertyWrapper`s in RequestBinding.swift).

/// Tells Wire that `@Controller` contributes a generated **proxy** — `_WireRouteContributor_<Controller>`
/// — into `WireMVCKeys.routeContributors`, not the controller itself. swift-wire's contributor-proxy
/// synthesis constructs the proxy (depending on the controller plus any factories its `@Middleware(key)`
/// use-sites demand) and collates that. So a controller needs only `@Singleton @Controller` and stays a
/// plain, footgun-free binding — the proxy is the only type that holds the lifted factories.
public let wireMVCControllerAlias = WireAdapterAnnotationV1(
    annotation: "Controller",
    capability: .contributesProxy(
        to: WireMVCKeys.routeContributors,
        proxyTypePrefix: "_WireRouteContributor_",
        // Routes register once at bootstrap, so the proxy is app-scoped. A `@Scoped(seed:)` controller
        // is then a scope bridge (the app-scoped proxy enters the request scope per request); a
        // `@Singleton` controller the proxy holds directly.
        proxyScope: .singleton
    )
)

/// `@Middleware(X)` declares that the annotated controller folds a middleware resolved from the graph —
/// the `.injectsFromGraph` capability, lifted onto the controller's route-contributor proxy. The plugin
/// dispatches on `X`: a `FactoryKey` naming a `@Factory` template synthesises and lifts `_WireFactory_<key>`;
/// a `T.self` or a `BindingKey` injects the middleware binding itself (by type / by key) onto the proxy.
/// The route codegen reads the same argument and folds the matching proxy field.
public let wireMVCMiddlewareAlias = WireAdapterAnnotationV1(
    annotation: "Middleware",
    capability: .injectsFromGraph
)

/// `@Coding(key)` names a keyed `WireMVCCoding` binding whose settings this scope's routes encode and
/// decode with — dates, and JSON options.
///
///     extension WireMVCCoding {
///         static let app = BindingKey<WireMVCCoding>()
///         static let reports = BindingKey<WireMVCCoding>()
///     }
///
///     @Provides(WireMVCCoding.app) static let appCoding = WireMVCCoding()
///
/// Three scopes, innermost winning: the `@WireMVCBootstrap` type sets the app's, a controller overrides it
/// for its routes, a route for itself. The same tiering `@Middleware` and `@ErrorResponse` use, for the
/// same reason: a policy is usually app-wide and occasionally not.
///
/// A **key** rather than a wrapper type, because the tiers all select the same type and swift-wire keys
/// the graph by type: `@Coding(WireMVCCoding.self)` would name one binding at every scope, so the override
/// could never resolve to anything different. `BindingKey` is what swift-wire already offers for binding
/// one type several times — the earlier design invented a `CodingSource` protocol to give each tier a
/// distinct *type* to name, which solved the same problem a second way.
///
/// It reaches the generated witness through `.injectsFromGraph`, exactly as a keyed `@Middleware` does —
/// the proxy gains a `_wire<key>` field and the witness reads it. That is what lets the settings come from
/// the graph while the code that needs them (`RequestBound.bind`, `WireMVCOutcome.json`) is static.
@attached(peer)
public macro Coding(_ key: BindingKey<WireMVCCoding>) =
    #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

/// `@Coding(WireMVCCoding.self)` names the app's *unkeyed* `WireMVCCoding` binding.
///
///     @Provides let coding = WireMVCCoding(json: .init(sortsKeys: true))
///     @WireMVCBootstrap @Coding(WireMVCCoding.self) struct AppBootstrap { … }
///
/// The form for an app with one coding, which is most of them: there is nothing to tell apart, so there
/// is no name to invent. Both forms exist for the same reason `@Middleware` has both — a key earns its
/// keep only once a second binding of the type exists.
///
/// Naming this one at two nested scopes overrides nothing, since it selects the same binding either way.
/// That is diagnosed rather than silently ignored.
@attached(peer)
public macro Coding(_ type: WireMVCCoding.Type) =
    #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

/// `@Coding` is lifted by the same capability `@Middleware` uses.
public let wireMVCCodingAlias = WireAdapterAnnotationV1(
    annotation: "Coding",
    capability: .injectsFromGraph
)

/// Marks a controller: each `@Get`/`@Post`/… route is registered onto a `some HTTPServerRouteBuilder`
/// under the optional path prefix. `@Singleton @Controller("/users")` is all an app-scoped controller
/// needs. A **marker** (Phase A) — it expands to nothing; the route-contributor proxy is generated in
/// the consumer module under plugin orchestration (WireGen emits the struct, `WireMVCRouteGen` the
/// witness). WireGen reads `@Controller` as the proxy-contribution directive via `wireMVCControllerAlias`.
@attached(peer)
public macro Controller(_ path: String) =
    #externalMacro(module: "WireMVCMacros", type: "ControllerMacro")

/// The no-path-prefix form (routes carry the full path on their verb annotation).
@attached(peer)
public macro Controller() =
    #externalMacro(module: "WireMVCMacros", type: "ControllerMacro")

// ── Composition root (`@WireMVCBootstrap`) ──

/// Tells WireGen to synthesise a **keyless global-middleware proxy** for the `@WireMVCBootstrap` root:
/// `_WireGlobalMiddleware_<Bootstrap>` reattributes the root's global `@Middleware` factories onto itself
/// (factory synthesis lands `_wireFactory_<key>` on the proxy, not the root — which, being a plain user
/// struct, has no such field) but contributes to no multibinding — a standalone, directly-addressable
/// binding. `WireMVCRouteGen` emits a generic `wrapGlobalMiddleware` method on it (the front layer folds
/// those factories around the router), and the generated `@main` reads `graph._WireGlobalMiddleware_<Bootstrap>`.
/// This is the `@Controller` proxy machinery with no contribution; it lets `@Middleware` mean one thing at
/// route, controller, and global scope, the scope set by placement — as `@ErrorResponse` already is. WireGen
/// discovers this via `wireMVCBootstrapAlias`; the macro below stays a no-op marker.
public let wireMVCBootstrapAlias = WireAdapterAnnotationV1(
    annotation: "WireMVCBootstrap",
    capability: .liftsPeersToProxy(proxyTypePrefix: "_WireGlobalMiddleware_", proxyScope: .singleton)
)

/// Marks the app's WireMVC-native composition root. A `@Singleton @WireMVCBootstrap` struct whose
/// `@Inject` properties resolve from the graph and whose `createServer()` /
/// `createRouteBuilder(for:)` factories build the concrete server and route builder. The plugin
/// (`WireMVCRouteGen`) reads the marker and generates the program entry point — a `@main` that
/// bootstraps the graph, constructs this type, registers the collated routes with `WireMVC.apply`,
/// and serves the router alongside the collated `ServiceLifecycle` services. `@Singleton` is required
/// (it makes the type a graph binding, exactly as `@Singleton @Controller` does); the entry point is
/// generated, not written. A **marker** — it expands to nothing (reuses `RouteMarkerMacro`); the
/// generated `@main` is emitted into the consumer module. See [Notes/../M5_5_PLAN.md].
@attached(peer)
public macro WireMVCBootstrap() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

/// Marks a method on the `@WireMVCBootstrap` composition root as the **fallback** handler for unmatched
/// requests (any method, any path) — the router dispatches to it instead of its built-in 404. It uses
/// the same annotations a route handler does (in practice `@RawRoute`, to write the response directly);
/// `@Path` is unavailable (there's no matched template). The generated `@main` registers it via
/// `registerNotFound` *before* `finalize()`, so it's a real route — the global middleware/error tiers
/// fold into it (M5.5 Phase 4/5), and being DI-capable it can use the Bootstrap's `@Inject`ed deps. If
/// no method carries `@NotFound`, the plugin synthesises a plain 404 fallback (still fold-able). A
/// **marker** — it expands to nothing; the plugin reads it.
@attached(peer)
public macro NotFound() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

// ── HTTP verb markers (peer, no-op — read by `@Controller`) ──

@attached(peer)
public macro Get(_ path: String) = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
@attached(peer)
public macro Get() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
@attached(peer)
public macro Post(_ path: String) = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
@attached(peer)
public macro Post() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
@attached(peer)
public macro Put(_ path: String) = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
@attached(peer)
public macro Put() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
@attached(peer)
public macro Patch(_ path: String) = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
@attached(peer)
public macro Patch() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
@attached(peer)
public macro Delete(_ path: String) = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
@attached(peer)
public macro Delete() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

// ── Response markers (peer, no-op — read by `@Controller`) ──

/// The route returns an `Encodable` body, encoded as JSON with the given status (default 200).
@attached(peer)
public macro JSONResponse() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
@attached(peer)
public macro JSONResponse(status: HTTPResponse.Status) =
    #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

/// The route returns HTML, **streamed** — the head goes out first, then the body is written incrementally
/// as it renders. `Content-Type: text/html; charset=utf-8` unless the route says otherwise.
///
///     @Get("/todos")
///     @HTMLResponse
///     func page() async throws -> some HTML { TodosPage(todos: try await repository.all()) }
///
/// Streaming is the contract, not an optimisation, and it has one consequence worth stating plainly:
/// **`@ErrorResponse` covers this route only up to the first byte.** Binding failures, scope-entry throws
/// and the handler itself still map to a status as they would on a `@JSONResponse` route; a failure *during
/// rendering* happens after the head is on the wire, so it cannot become a status and instead truncates the
/// response (the writer is dropped without `finish`, which the proposal defines as an abort).
///
/// The return type is not named here. The generated terminal wraps whatever the handler returns in a
/// `WireMVCHTMLProducer`, resolved against the adapter the *controller's own module* imports — `WireMVCElementary`
/// in practice. WireMVC's core depends on no HTML library, so this annotation names a convention rather than
/// one. See `Documentation/Notes/StreamingResponseTier.md`.
@attached(peer)
public macro HTMLResponse() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
@attached(peer)
public macro HTMLResponse(status: HTTPResponse.Status) =
    #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

/// The route returns no body; the response carries the given status.
@attached(peer)
public macro ResponseStatus(_ status: HTTPResponse.Status) =
    #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

/// `@ResponseHeader(.cacheControl, "no-store")` — a **constant** header field on this route's successful
/// response. Repeatable, at two scopes: on the controller it covers every route, on a route it covers that
/// one, and a route entry beats a controller entry naming the same field. The same tiering `@Middleware`,
/// `@ErrorResponse` and `@Coding` use, for the same reason — a policy is usually scope-wide and
/// occasionally not.
///
/// It applies to the route's **success** outcome only. An error response is built by the `@ErrorResponse`
/// mapping that produced it, which carries its own fields (`.status(_:headerFields:)` /
/// `.json(_:status:headerFields:)`) — a `Cache-Control` chosen for a `200` is rarely right for the `500`
/// that replaced it, so inheriting it silently would be a worse default than saying nothing.
///
/// Constants only, by construction. A **computed** header is returned by the handler instead, in a
/// labelled response tuple:
///
///     @Get("/{id}") @JSONResponse
///     func document(@Path id: UUID) async throws -> (headers: HTTPFields, body: Document) {
///         let doc = try await store.document(id)
///         return ([.eTag: doc.etag], doc)
///     }
///
/// The tuple may name `status`, `headers`, and `body` — any suffix-subset ending in `body` — and a field
/// it sets beats this annotation, which beats the controller's. Innermost wins, as everywhere else.
/// Returning the response metadata rather than mutating something handed to the handler is what the typed
/// prior art does (axum's tuple `IntoResponse`, Spring's `ResponseEntity`, Hummingbird's `EditedResponse`)
/// and, more locally, what an `@Operation` route already does — the OpenAPI generator's `Output.Ok` carries
/// `headers` and `body` exactly this way, so both kinds of route answer the question the same way.
///
/// The field name is an `HTTPField.Name`, so every standard field is `.location` / `.eTag` /
/// `.cacheControl`; a non-standard name has no spelling here yet.
@attached(peer)
public macro ResponseHeader(_ name: HTTPField.Name, _ value: String) =
    #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

/// The verb form — `@ResponseHeader(.setCookie, "consent=1", .append)`.
///
/// Defaults to `.set`, which is what the tier order implies. `.append` is for a field that legitimately
/// repeats: it emits a **separate field line** rather than folding into one value, which is what makes it
/// correct for `Set-Cookie` (RFC 6265 §3 forbids folding that field, and RFC 9113 §8.2.3 requires separate
/// lines over HTTP/2). `.setIfAbsent` defers to a contributor further in.
///
/// The same three verbs a middleware contributes with — one vocabulary, because annotations and middleware
/// differ in *when* their value exists and in *what they reach*, not in how their contributions combine.
@attached(peer)
public macro ResponseHeader(_ name: HTTPField.Name, _ value: String, _ verb: ResponseHeaderVerb) =
    #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

/// The raw escape hatch: the handler receives the request, matched path parameters, the body reader,
/// and the response sender verbatim (no param decode, no response encode) and writes the response
/// itself. Use for streaming/SSE/proxying. The handler is generic over the reader/sender (the builder's
/// associated types); take only the primitives you need — `HTTPRequest`, `[String: Substring]`, the
/// `AsyncReader`-constrained reader, the `HTTPResponseSender`-constrained sender — in any order.
/// Stands in for the response annotation (a `@RawRoute` needs no `@JSONResponse`/`@ResponseStatus`).
@attached(peer)
public macro RawRoute() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

/// A raw handler's register-closure primitive, named for `@RawRoute(.role, …)`.
public enum RawRouteRole: Sendable {
    case request
    case requestContext
    case pathParameters
    case reader
    case responseSender
}

/// The explicit-role raw escape hatch — `@RawRoute(.role, …)` binds the handler's parameters to the
/// register-closure primitives **positionally by the listed roles**, one role per parameter, instead of
/// inferring them from the parameter types/constraints. Use it when a parameter's type can't be inferred:
/// a **transformed slot** whose type a middleware produces — e.g. `responseSender: consuming
/// MultiPartSender<S>` off a sender-transforming middleware. There is no `as?` rescue for a `consuming`
/// `~Copyable` value, so a transformed sender/reader/context must be named by role. Naming the transformed
/// slot also couples the route to its producing middleware at compile time: without the transform, the
/// register closure's primitive doesn't match the handler's parameter type and the build fails.
@attached(peer)
public macro RawRoute(_ roles: RawRouteRole...) =
    #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

/// Wrap a route (or, on the controller type, every route) in a `Middleware` resolved from the graph.
/// `@Middleware(T.self)` folds the `T` binding by type; a generic-with-deps middleware is instead named
/// by its `@Factory` key (the overload below). The middleware runs before the handler and can transform
/// the box (e.g. enrich the `RequestContext`). Controller-scope `@Middleware` wraps outer, route-scope
/// inner: `controller-outer → route-inner → handler`. A marker: the plugin lifts the binding onto the
/// controller's route-contributor proxy and the route codegen folds it — the annotation expands to nothing.
@attached(peer)
public macro Middleware<T>(_ type: T.Type) =
    #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

/// The keyed form — `@Middleware(key)`. A `FactoryKey` naming a generic-with-deps middleware's `@Factory`
/// template folds the synthesised factory (`_WireFactory_<key>`), specialised at the builder's box roles;
/// any other `key` folds the graph binding stored under it. Either way the plugin lifts what the key names
/// onto the controller's proxy and the route codegen folds the matching field. See `wireMVCMiddlewareAlias`.
@attached(peer)
public macro Middleware(_ key: FactoryKey) =
    #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

// ── Route error handling (`@ErrorResponse`) ──

/// Map an error thrown by a route (from the handler, or from a `@Scoped` binding built at scope entry)
/// to a response, at controller scope (every route) or route scope (one route). Route entries are
/// consulted before controller entries (route overrides controller); an unmapped throw becomes a
/// built-in `500` written by the terminal — WireMVC owns the 500, since the server aborts (drops the
/// connection on) an escaped throw rather than synthesising one. A **marker**: the route
/// codegen reads the annotation and folds the mapping into the terminal's `catch` — the annotation
/// expands to nothing. Two forms:
///
/// - `@ErrorResponse(E.self, .status)` — the ultralight case: for a thrown `E`, respond with `status`.
/// - `@ErrorResponse({ (e: E) in … })` — an inline typed-parameter closure (the `@Teardown(<action>)`
///   shape), for a richer response (a JSON body, logic). The parameter type must be annotated and is the
///   matched error type. Static by construction (no `self`), so it maps a handler throw *and* a throwing
///   request-scoped binding at scope entry.
///
/// A form whose error type is `Swift.Error` is the **catch-all** — consulted after the built-in
/// `WireMVCBindingError`→status mapping (so param-decode failures keep their 415/422), before the
/// built-in 500. At most one catch-all per scope, and it must be the last error entry at its scope.
///
/// > A named-function reference (`@ErrorResponse(SomeType.map)`) is **not** supported yet: a reference to
/// > the annotated controller's own method is a circular macro reference (the compiler can't resolve the
/// > type mid-expansion), and a reference to a separate type needs cross-module signature resolution the
/// > codegen doesn't do. Use an inline closure.
///
/// See [Notes/RouteErrorHandling.md](RouteErrorHandling.md).
@attached(peer)
public macro ErrorResponse<E: Error>(_ type: E.Type, _ status: HTTPResponse.Status) =
    #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

/// The body-returning form — `@ErrorResponse(E.self, .notFound, { e in Problem(…) })`. The closure's
/// value is encoded as the JSON body of a response with that status.
///
/// It is the pair form's counterpart: `(E.self, .status)` answers with a status alone, which is all a
/// response carrying no body can say. Which of the two is right is not always the author's choice — an
/// adapter that reads an OpenAPI document knows whether that status declares a body, and can require the
/// matching form.
@attached(peer)
public macro ErrorResponse<E: Error, Body: Encodable>(
    _ type: E.Type,
    _ status: HTTPResponse.Status,
    _ body: (E) throws -> Body
) = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

/// The inline-closure form — `@ErrorResponse({ (e: E) in … })`. `E` (including `Swift.Error` for the
/// catch-all) is the matched type, read from the closure's annotated parameter.
@attached(peer)
public macro ErrorResponse<E: Error>(_ respond: (E) throws -> WireMVCOutcome) =
    #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

/// The catch-all overload — a mapping over `any Error`, so overload resolution binds a `Swift.Error`
/// mapping here directly rather than through `E == any Error` inference on the generic form above.
@attached(peer)
public macro ErrorResponse(_ respond: (any Error) throws -> WireMVCOutcome) =
    #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

// ── Generic-with-deps middleware: the producer side (`@Factory` + `@MiddlewareFactory`) ──

/// The box roles a generic middleware's assisted parameters fill, in the proposal box's canonical order
/// (`RequestResponseMiddlewareBox<RequestContext, Reader, ResponseSender>`). Referenced in a
/// `@MiddlewareFactory(.role, …)` custom mapping.
public enum MiddlewareRole: Sendable {
    case requestContext
    case reader
    case responseSender
}

/// Supplies the **box-role mapping** for a generic middleware's `@Factory` template — which of its
/// assisted (non-`@Inject`) generic parameters fill which box role. Bare `@MiddlewareFactory` maps them
/// positionally to `RequestContext`, `Reader`, `ResponseSender` in order (the common
/// `<Ctx, Reader, Sender>` case); `@MiddlewareFactory(.requestContext, .responseSender)` maps them by the
/// listed roles (positional over the assisted parameters — for a middleware that reorders or pins one
/// role). The plugin reads it (via `wireMVCMiddlewareFactoryRolesAlias`) and orders the synthesised
/// `create`. It requires `@Factory` on the same type — that's the factory template it maps.
@attached(peer)
public macro MiddlewareFactory(_ roles: MiddlewareRole...) =
    #externalMacro(module: "WireMVCMacros", type: "MiddlewareFactoryMacro")

/// Tells Wire that `@MiddlewareFactory` supplies a factory role mapping over the box roles, in the
/// proposal box's canonical order. The roles stay WireMVC's; the plugin reads them as opaque ordered
/// slot identifiers naming the synthesised `create`'s generic parameters.
public let wireMVCMiddlewareFactoryRolesAlias = WireAdapterAnnotationV1(
    annotation: "MiddlewareFactory",
    capability: .mapsFactoryRoles(roles: ["RequestContext", "Reader", "ResponseSender"])
)
