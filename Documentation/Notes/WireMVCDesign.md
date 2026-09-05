# WireMVC design — M5.0 decision record

> **Status:** the settled M5.0 surface for `WireMVC` (the cross-framework
> declarative-routing adapter). Authoritative for Tier 2's surface;
> [WireMVCAbstraction.md](WireMVCAbstraction.md) — rewritten at M5.6 off the retired
> `_wireRegister` model — is its companion rather than its predecessor, and carries the
> **progressive-adoption** path between Tier 1 (`wire-hummingbird`) and this. The milestone sits in
> ROADMAP.md; the iteration plan is M5_PLAN.md.
>
> **Update — proposal-native pivot (reconciled below).** M5.0 originally standardised on
> `some ServerTransport` (OpenAPIRuntime) as the core target, with the
> `swift-http-api-proposal` server surface named the *tracked successor* behind the same
> seam. That successor is now the **core**, ahead of the planned timeline: deploying against
> macOS 26 makes `anyAppleOS 26.0` unconditional, so Wire's ungated generated code compiles
> against the proposal's server API today. WireMVC registers routes on
> `RoutableHTTPServerBuilder` (over the proposal's `HTTPServer`/`HTTPServerRequestHandler`);
> `some ServerTransport` is **retained as an opt-in adapter** (`WireMVCServerTransport`,
> behind a `ServerTransport` package trait) so Hummingbird/Vapor still mount the same
> controllers. The inversion is proven by
> `spike-12` (routing over
> `HTTPServer.serve`), `spike-13`
> (the `ServerTransport` bridge), and
> `spike-14` (streaming through both).
> `spike-11` remains the
> proof of the decoded-witness *shape* (decode → call → encode); only its registration
> target moved from `transport.register` to `builder.register`.
>
> **Update — codegen mechanism (M5.3, reconciled below).** Two things were refined after M5.0.
> (1) Route-witness **generation moved from the `@Controller` macro to the build plugin** — where this
> record says "the macro emits/generates," that codegen is now plugin-owned (`@Controller` is a marker;
> WireGen emits the route-contributor proxy struct and WireMVC's `WireMVCRouteGen` emits the witness).
> (2) The `@Controller` alias became **`.contributesProxy(to:)`** — the controller stays a plain binding
> and the plugin contributes a generated proxy in its place, so the "no new contract" note under
> *Controller & scope* no longer holds. Both are recorded in
> Archive/WireMVCCodegen.md; the M5.0 **surface** decisions below are
> otherwise unchanged.

The headline, unchanged: WireMVC is a **spec-free, annotation-driven analogue of the OpenAPI
generator's registration codegen**. `@Controller`/verb/param/response annotations fold into a
Wire collation surface (`WireMVCKeys.routeContributors`); because the target is the proposal's
**routing-surface protocol** rather than any one framework, controllers mount cross-runtime
unchanged — natively on the proposal server, and on Hummingbird/Vapor through the
`ServerTransport` adapter.

## Decisions

### Target protocol — `RoutableHTTPServerBuilder` over the proposal server (adapter for `ServerTransport`)

WireMVC registers routes on **`RoutableHTTPServerBuilder`** — a small WireMVC-owned
per-route registration surface parameterised over the proposal server's associated
`RequestContext` / `Reader` / `ResponseSender`, so a *Router* built on the proposal's
`HTTPServer.serve(handler:)` conforms to it and WireMVC never reimplements routing. The
genericity is on the **contributor's method** (`registerWireRoutes<Builder: RoutableHTTPServerBuilder>`),
not the contributor type, so `any RouteContributor` still boxes and collates through Wire's
`CollectedKey` (below), while the builder keeps the server's `~Copyable` streaming
associated types and is never boxed. (Superseded decision: M5.0 first standardised on
`some ServerTransport`; see the pivot banner. The core no longer depends on `OpenAPIRuntime`
at all — that dependency moved to the opt-in adapter.)

**`some ServerTransport` is retained as an opt-in adapter.** `WireMVCServerTransport` (a
separate module behind the `ServerTransport` package trait, off by default so the core
resolves proposal-only) bridges the same proposal-native controllers onto a
`some ServerTransport`, so Hummingbird/Vapor mount them via `swift-openapi-hummingbird` /
`swift-openapi-vapor` unchanged. The `ServerTransport` register closure is
`request → (HTTPResponse, HTTPBody?)`; the bridge fabricates a proposal `Reader` from the
request `HTTPBody?` and a `ResponseSender` that feeds the response `HTTPBody` (streaming —
see `spike-14`). This inverts the
original cost: OpenAPIRuntime is now a dependency only of the adapter a consumer explicitly
opts into, not of the core.

**Not a permanent wedding either way:** the route-descriptor table (below) stays the
portability layer, so the registration backend (`builder.register` for the proposal server,
`transport.register` inside the adapter) is swappable off the same descriptors.

### Dispatch — dynamic registration now; static-capable by construction

Register routes on a runtime router/transport (dynamic dispatch) — the proven norm
(swift-openapi-generator, axum, Hummingbird, …; genuine compile-time *dispatch* is rare —
essentially only Go's `ogen` and Play). Route-conflict/exhaustiveness detection comes from
the **build plugin's global view**, not from generated dispatch, and WireMVC's plugin
already has that. **Design rule:** the macro's source-of-truth artifact is the **route
descriptor table** (method, path, param decode, handler ref, middleware chain); a *dynamic
backend* (emit `register` calls) ships now, an optional *static backend* (one generated
dispatch) and **content-type routing between handlers** are future capabilities derivable
off the same table. Do not make "emit `register` calls" the macro's only output.

### Controller & scope

- `@Controller` — the annotation name (generic, per Spring/Micronaut/NestJS prior art;
  the framework-specific adapters keep their qualified `@HummingbirdController` /
  `@OpenAPIController` names — the portable surface earns the plain one).
- It is a `@Contributes(to: WireMVCKeys.routeContributors)` **alias** — no new contract.
  (WireMVC uses its own collated key rather than re-homing into M3's `TransportKeys.handlers`,
  because its witness registers on `RoutableHTTPServerBuilder`, not `some ServerTransport`;
  the two surfaces still coexist on one graph — see the plan's *task-cluster* note.)
- **Requires an explicit scope** (`@Singleton` → app-scope, M5.1; `@Scoped(seed:)` →
  request-scope, M5.4). Bare `@Controller` with no scope is a diagnostic.
- **Optional path prefix:** `@Controller("/users")` groups and verb subpaths append; bare
  `@Controller` with the full path on each verb is also allowed.

### Routes & methods

- Verbs: `@Get` / `@Post` / `@Put` / `@Patch` / `@Delete`; one verb per func.
- Path templates use `{name}` placeholders (matches `ServerTransport`/OpenAPI path
  strings). Wildcards/catch-alls deferred (the raw handler covers them).

### Handler params (request inputs)

- Every handler param carries a **source** annotation — `@Path` / `@Query` / `@JSONBody` /
  `@Header`; an unannotated param is a diagnostic. Only the **name string** is inferred
  from the parameter, never the source (guessing path-vs-query is unsafe): `@Path id`
  binds `{id}`, `@Path("user_id") id` overrides. Dependencies come via controller
  `@Inject` properties, not handler params.
- **Optionality & defaults via Swift-native** optionals/defaults, not annotation args:
  `@Query page: Int = 1`, `@Query filter: String?`.
- **String → typed conversion via `LosslessStringConvertible`**, with WireMVC adding
  conformances for common non-conformers (`UUID`, …); a custom type conforms to
  participate. (Matches Vapor; no converter registry — a language feature, not framework
  magic.)
- `@JSONBody` — the request-body annotation names the codec, symmetric with
  `@JSONResponse`. Rationale: WireMVC fixes the decoder at codegen (no runtime content
  negotiation), so a generic `@Body` would falsely imply negotiation; the statically-typed
  prior art (axum/Rocket `Json<T>`) names the codec too, just in the type. At most one
  `@JSONBody` per handler. Future `@FormBody` / `@MultipartBody` are siblings.

### `@JSONBody` content-type handling (the validate model)

Naming the codec on the param gives the **axum/validate model** (one handler, validated),
not the JAX-RS/Rocket route-between-handlers model — which also yields the *correct* status
(Rocket's routing model collapses "wrong type" into 404):

- Contradictory `Content-Type` → **415 Unsupported Media Type**.
- **Missing** `Content-Type` → **lenient**: attempt the JSON decode anyway (only a
  *contradictory* type is rejected — greenfield-friendly, avoids axum's 415-on-missing).
- Malformed / undeserializable JSON → **422 Unprocessable Content**.

Multi-content-type on one route, if ever wanted, is the future capability above: sibling
handlers by codec, routed by the plugin with **compile-time** collision detection and the
correct 415/406 (better than Rocket's launch-time / 404).

### Responses — one annotation per route, validated against the return type

Every route declares **exactly one** response annotation; the macro validates it against
the signature. No route relies on an implicit status.

- `@JSONResponse[(status:)]` — has an `Encodable` body, JSON-encoded, default `200`.
  Error on a `Void` func.
- `@ResponseStatus(_)` — no body, status only, for `Void` funcs. **The status argument is
  always required for now** (no bare default); this can be relaxed after feedback —
  loosening a rule is non-breaking, tightening isn't. Error on a body-returning func.
- A `Void` func with no response annotation is a diagnostic ("add `@ResponseStatus`").

This makes every route's response mode a visible, greppable annotation (the reason
explicit `@JSONResponse` was chosen over JSON-by-default), and dissolves the 200-vs-204
*silent-default* debate — nothing is implicit. (Prior art: the required-annotation
discipline is JAX-RS/OpenAPI-flavored; `@ResponseStatus` is the Spring name.)

> **Refined once a status can be returned.** A handler may now return its status in a response
> tuple, which leaves the annotation nothing to say for some shapes — a bodiless
> `(status:headers:)` return takes **no** response annotation, and `@JSONResponse(status:)`
> beside a returned status is rejected. The rule holds in substance (every route states its mode
> exactly once, in an annotation *or* in a return type that says it unambiguously) and the
> `Void`-with-no-annotation diagnostic is unchanged. See *What the response annotation is for,
> once a status can be returned* below.

### Handler shape & errors

- `async` / `throws` / sync / non-throwing handlers all supported; the generated witness
  awaits / `try`s as needed.
- Thrown error → **500** baseline in M5 core; typed error→response mapping deferred.

### Middleware (spelling here; full model settled in M5.3)

- `@Middleware(expr)` repeatable at controller + route scope; composed source-order,
  controller-outer → route-inner → handler. The middleware *is* the proposal's `Middleware`
  (a Wire component referenced from the graph); each route's chain is a `MiddlewareBuilder` fold
  and every handler is its terminal, projecting params off the fold's final box. The full
  record — box projection, capabilities, folds, `@RawRoute`, plugin-generated forwarding — is
  [WireMVCMiddleware.md](WireMVCMiddleware.md).

## Deferred (explicitly not M5.0)

- Raw escape-hatch handler spelling → **M5.2, decided: `@RawRoute`** (see
  [WireMVCMiddleware.md](WireMVCMiddleware.md)).
- Content negotiation beyond JSON, and content-type routing between handlers → future
  capability off the route-descriptor table.
- **Streaming / SSE → raw handler (M5.2).** The `RoutableHTTPServerBuilder` handler already
  hands the raw proposal primitives (`consuming sending Reader` / `ResponseSender`) to the
  closure, so the raw escape hatch *is* that signature with decode/encode skipped —
  `spike-14` streams SSE end-to-end
  both natively and through the `ServerTransport` adapter (with real backpressure), so
  streaming needs **no** framework-specific adapter.
- **WebSocket → escape-to-framework, not a WireMVC route.** An upgrade is not a
  request→response body; neither the proposal server's handler model nor `ServerTransport`'s
  `register → (HTTPResponse, HTTPBody?)` expresses it, so no transport-level adapter (generic
  or framework-specific) carries it. WebSocket routes are registered directly on the
  framework and WireMVC coexists — unless/until the proposal *and* OpenAPIRuntime both grow
  upgrade support.
- Typed error→response mapping → **shipped** as `@ErrorResponse` (M5.4E); see
  [RouteErrorHandling.md](RouteErrorHandling.md).
- Response header/cookie control → **shipped**: `@ResponseHeader` + the response tuple for routes, and
  `ResponseHeaderRegistry` on the box for middleware (see below). A session cookie is expressible.
  The **global** tier lands with it (`WireMVCContext` as a courier), so a global `@Middleware` reaches a
  route's response — including routes with no `@Middleware` of their own, raw routes, and the 404.
- `@Head` / `@Options` verbs → later or via the raw handler.

## Added after M5.0

- **`@Coding` — the settings a route encodes and decodes with** (dates, JSON options), at three scopes
  with the innermost winning, the same tiering `@Middleware` and `@ErrorResponse` use. It arrived during
  M6d and the reasoning is recorded there — see *Middleware, errors, configuration* in
  [WireOpenAPIAdvanced.md](https://github.com/swift-wire/wire-open-api/blob/main/Documentation/Notes/WireOpenAPIAdvanced.md) — because the question was asked from the OpenAPI
  side and the answer is why it landed **here** instead: a `@Get` route returning a `Date` has exactly
  the same question as a generated operation, and the two were answering it differently. Foundation
  writes seconds since 2001; the OpenAPI runtime writes ISO8601.
- `WireMVCCoding.default` is therefore **not** Foundation's default. ISO8601 dates are a deliberate
  change of behaviour: a number since 2001 is not something an API client can read, and matching the
  OpenAPI runtime is what lets one app serve both kinds of route consistently.
- Selection is a `BindingKey<WireMVCCoding>`, or `WireMVCCoding.self` for an app with one coding —
  the two forms `@Middleware` has, for the same reason.

### Response header fields — `WireMVCOutcome` carries them

`WireMVCOutcome` became a **struct** (`status`, `headerFields`, `body: [UInt8]?`) where it was a two-case
enum. The cases only ever differed in whether a body was present, so a third component would have had to be
duplicated across both payloads. `.status(_:)` and `.body(_:_:)` survive as static factories, so no
construction site changed — including the emitted witness, which is byte-identical before and after.

The forcing case was not DX. `send(on:)` built `HTTPResponse(status:)` with **no** fields, and nothing
downstream synthesises any (checked: `WireMVCRouter`, `WireMVCServerTransport`, the proposal's
`HTTPResponseSender`, `NIOHTTPServer`) — so every `@JSONResponse` route was shipping its body untyped.
`WireMVCOutcome.json` now seeds `Content-Type: application/json` unless the caller supplies one, matching
the OpenAPI generator's `ContentType.applicationJSON` (plain, no charset) so one app's two kinds of route
agree. `.status(_:)` and `.body(_:_:)` seed nothing: neither knows what the bytes are.

Because `@ErrorResponse` mappings already return a `WireMVCOutcome`, error responses gained header fields
by the same change — which is what makes a `401` able to carry the `WWW-Authenticate` that RFC 9110 §11.6.1
requires of it. That was previously unexpressible at any tier.

### The route surface — `@ResponseHeader` and the response tuple

Two spellings, split by whether the value is known before the program runs:

```swift
@Singleton @Controller("/docs") @ResponseHeader(.cacheControl, "no-store")
struct DocController {
    @Get("/{id}") @JSONResponse @ResponseHeader(.vary, "Origin", .append)
    func document(@Path id: UUID) async throws
    -> (status: HTTPResponse.Status, headers: HTTPFields, body: Document) {
        let doc = try await store.document(id)
        return (.ok, [.eTag: doc.etag], doc)
    }
}
```

`@ResponseHeader` is repeatable at controller and route scope for **constants**. A **computed** field is
returned in a labelled tuple, in any of four shapes: `(headers:body:)`, `(status:body:)`,
`(status:headers:body:)`, or `(status:headers:)` for a bodiless response — which is the computed-redirect
shape (a returned `Location`), the single most common need in the example sweep.

### What the response annotation is for, once a status can be returned

Allowing a returned status forced the annotation's job to be stated precisely, because for some shapes it
had nothing left to say. It carries two things — the response **mode** (is there a body, and in which
codec) and the **status** when that is static — and a returned status takes the second away:

| Return | Mode declared by | Status from |
| --- | --- | --- |
| `Void` | `@ResponseStatus` | its argument (required) |
| `T` | `@JSONResponse` — names the codec | its argument (default `.ok`) |
| `(headers:body:)` | `@JSONResponse` — codec | its argument |
| `(status:body:)` / `(status:headers:body:)` | `@JSONResponse` — codec | **the return**; the argument is rejected |
| `(status:headers:)` | **the return type** | **the return**; any annotation is rejected |

So a **bodiless response tuple takes no response annotation at all**, and writing one is a diagnostic. Both
facts an annotation could state are already in the signature, more explicitly than an attribute puts them:
no `body` label means no body, and `status:` means the status is computed. A bare `@ResponseStatus()` was
considered and rejected — it would have been a mandatory declaration carrying no information, which is the
thing the annotation rule exists to prevent, not an instance of it.

A body-carrying tuple still needs `@JSONResponse`, because *that* names the codec (and is what makes a
future `@HTMLResponse` its sibling); only its `status:` argument is rejected. Making the dead value
unwritable is stronger than diagnosing it after the fact.

**The M5.0 rule survives in substance**, restated: *every route states its response mode exactly once — in
an annotation, or in a return type that says it unambiguously.* The silent-default the original rule was
written against is untouched: a `Void` handler with no annotation is still a diagnostic, because there the
status genuinely is unstated.

**Returned, not mutated through an out-parameter.** The first design handed the handler a mutable
`ResponseHeaderSink`; it was wrong twice over. Mechanically, a property wrapper is the only custom attribute
a function parameter accepts and one applied to `inout` projects an *immutable* binding, so the spelling
does not work at all. Architecturally, it was the wrong lineage: value-carried response metadata is what
every typed/declarative framework does (axum's tuple `IntoResponse`, Spring's `ResponseEntity`, JAX-RS
`Response`, Hummingbird's `EditedResponse`), while the mutate-a-handle model belongs to the context-centric
family (Go's `ResponseWriter`, Express, FastAPI's `response:` parameter). Decisively, an `@Operation` route
already returns the OpenAPI generator's `Output.Ok(headers:body:)` — value-carried — so a sink would have
re-opened the split M6d closed.

**Keyed on labels, not element type spellings.** The macro is syntactic, so matching on `HTTPFields` would
misread a body type spelled that way and would inherit the type-spelling fragility
[WireMVCMiddleware.md](WireMVCMiddleware.md) already records as a residual. An *unlabelled* tuple stays a
body, so no existing handler changes meaning.

**One vocabulary of verbs, shared with middleware.** `set` (default), `append`, `setIfAbsent`. The earlier
draft gave annotations a fixed replace rule and reserved verbs for middleware, justified by annotations
being statically visible to each other — an inner scope can always restate a combined value. That argument
has exactly one hole, and `Set-Cookie` is it: RFC 6265 §3 forbids folding that field, so "restate combined"
is unavailable precisely where a second value is most wanted. Rather than special-case the field, the verbs
are uniform. Annotations and middleware differ in *when* their value exists and in *what they reach*, not in
how contributions combine.

**Resolution is one ordered application**, `WireMVCResponseHeaders.resolved`:

```
controller @ResponseHeader → route @ResponseHeader → handler return → middleware (outer last)
```

Tier order *is* application order — there is no separate override pass, so a route's `.set` replaces the
controller's and its `.append` adds to it by construction. Middleware last and outer-wins matches
Hummingbird and Vapor, where middleware mutate on the way out; it keeps a policy header set at the app edge
from being overridden by something nested inside it.

**It never folds.** Every write goes through `HTTPFields`' multi-value subscript, so repeated fields stay
separate field lines. Folding would be *legal* for list-valued fields — RFC 9110 §5.3 makes the two forms
semantically identical — but is forbidden for `Set-Cookie` and required against by HTTP/2 (RFC 9113 §8.2.3),
so staying multi-line is correct everywhere with no per-field knowledge and no RFC field table. A caller
wanting one folded line writes the combined value with `.set`. There is deliberately **no** fold verb: for
list fields it would be redundant, for `Set-Cookie` harmful, and for singular fields (`Content-Type`,
`Location`) neither append nor fold is valid anyway. `HTTPFields`' *single*-value subscript folds on write
and its getter joins on read without special-casing `Set-Cookie`, so touching it anywhere in the resolve
path is the one invariant that would break this silently.

### The middleware channel — `ResponseHeaderRegistry` on the box

A middleware has no return value to carry a field in (the proposal's `Middleware.intercept` is universally
generic in `Return`), so it contributes through the box:

```swift
return try await input.contributing { headers in
    headers.add(.set(.strictTransportSecurity, "max-age=31536000"))  // known on the way in
    headers.onSend {                                                 // not knowable until the handler ran
        guard let cookie = try await store.persistIfEdited(session) else { return [] }
        return [.append(.setCookie, cookie.description)]
    }
} then: { input in
    try await next(input)
}
```

**Registered on the way in, evaluated on the way out.** This is the load-bearing constraint, and it is not
a choice: the terminal writes the response *during* `next` (see
[WireMVCMiddleware.md](WireMVCMiddleware.md), *Short-circuit & the box shape*), so by the time an outer
middleware resumes the bytes are gone. Mutating a response after `next` — what Hummingbird's
`SessionMiddleware` does — is not expressible here at all. `onSend` is the shape that survives it, and is
ASP.NET Core's `HttpResponse.OnStarting` for the same reason: headers stop being writable once the body
starts.

**Ordering.** Drain applies registration calls in **reverse**, so the outermost middleware — which
registers first, on the way in — applies last and wins. That matches a wrap-style stack's natural
behaviour (Hummingbird and Vapor middleware mutate on the way out, outermost last) and keeps a policy
header set at the app edge from being overridden by something nested inside it. Order *within* one call is
preserved, so a middleware never sees its own contributions reversed.

**Threaded by the box, enforced by the compiler.** The registry is a `~Copyable` value carried in the box's
`pending` state — not in `responded`, which holds none, because nothing drains a box whose response is
already written and a field contributed there could never reach it. It is a **required** parameter of
`pending(…)`: a transforming middleware that rebuilds the box must thread it out of
`withContents(pending:responded:)` and back in, and one that forgets fails to compile rather than silently
discarding every contribution. The fixture `MultiPartMiddleware` proved this the moment the parameter
landed. Same principle as the projection guarantee — the compiler enforces participation, nothing asserts
it.

Linearity is why the destructures yield it rather than an accessor handing it out: a `~Copyable` value
cannot be reached off a borrow, so `withPendingContents` / `withContents` gained it as a trailing
parameter, and contribution is `contributing(_:then:)` — a consuming method over the same primitive, which
hands the registry `inout` so conditional fields go in one pass. That is also the fix for a region
problem: a registry read into a local before the destructure is task-isolated, and a sender wrapped with
one cannot then be handed on `sending`. See wire-mvc's `LinearResponseHeaderRegistry.md`.

**The gate path drains too.** A gate short-circuits the terminal, so `respondingWith(_:)` — responding with
a `WireMVCOutcome` — drains into it before sending. Without that, contributions would vanish on exactly the
paths that most want them (a `401` needing its challenge, a redirect needing a cookie set on the way out).
Raw `responding` keeps handing over the sender and does **not** drain; that is documented on it, and it
stays for streaming, which has no outcome shape.

### The global tier — `WireMVCContext` as a courier

A *global* `@Middleware` initially could not contribute at all. The global tier is a front layer wrapping
`router.handle` (M5.5 Phase 5) and builds its own box; the route builds a fresh one inside, so the two
registries never met. That is the security-headers and CORS case, so it is not a corner.

**Why the obvious fixes don't work.** `GlobalMiddlewareHandler` declares its associated types *equal* to its
inner's, and `HTTPServerRequestHandler.handle` takes exactly four values and is the proposal's, not ours.
So the front layer cannot wrap the sender, cannot wrap the context, and has no parameter to hand anything
down in. Two designs were worked through and rejected:

- **Fold the global chain into every route** (threading it through `registerWireRoutes`, as `coding:`
  already is). Costs one fold entry per route, moves globals *inside* route matching, and needs a
  `Middleware`-shaped constraint across two method generic parameters — close enough to spike-15's
  inexpressible fold to be a real risk.
- **`finalize(globalMiddleware:)`, folding globals at the router.** *Not expressible*: `ServingHandler` is a
  single associated type on `FinalizableHTTPServerRouteBuilder` and cannot be parameterised by the chain
  per call. Same family of failure as spike-15 — `Middleware`'s two primary associated types not fitting
  through a boundary that wants one type.
- **A WireMVC-owned handler protocol with a fifth parameter.** Expressible, but it invents a second channel
  for exactly what `RequestContext` is: `HTTPServerCapability.RequestContext` is an *empty marker* whose
  documented purpose is per-request capabilities, and this record's own rule is *enrichment rides
  `RequestContext`*.

**The design.** `WireMVCContext<Base>` carries the registry from a handler at the top of the stack
(`WireMVCContextHandler`, always present) down through the front layer to the router. It conforms with
`RequestContext == Base` while its inner conforms with the wrapper — different types on different
conformances, which is what lets it wrap where the front layer cannot. That the front layer *couldn't* was
a declaration choice in it, not a language constraint; mistaking one for the other is what sent the first
two designs down blind alleys.

**It is a courier, not a carrier — and is unwrapped on arrival.** The registry lives on the *box*, where
route and controller middleware already reach it; the context only gets it across `handle`. So the
generated register closure calls `takeContents()` — one consuming destructure yielding both the registry
and the base, since a linear registry cannot be handed out by a getter and two consuming methods cannot
both be called on one courier — and builds the route's box over the **unwrapped** context. Nothing below routing meets the type: a context-transforming middleware wraps the app's real
context, and the plugin's capability-forwarding conformances stay one layer shallower. The anticipated
pressure on that — M6b putting a per-request *logger* on the context, something route code genuinely
consumes, which would have earned the exposure and taken the unwrap out — **did not arrive**: M6b's logger
is an ordinary `@Scoped(seed: HTTPRequest.self)` binding that route code reaches by `@Inject`, so it never
touched the context. The courier stays a courier and the unwrap stands.

**Spiked before building** (wrapper, consuming unwrap, differing inner/outer conformances, a route
end-to-end): all four compile. The unwrap is `WireDisconnected/take()`'s shape — `consume base` out of a
consuming method — which was the piece most likely to fail given this package's history with linear values.

**Raw routes take a wrapping sender, not a drain.** A `@RawRoute` writes its own head, so there is no
outcome to inject into; `ResponseHeaderApplyingSender` resolves contributions into whatever head is written
through it instead. That is what reaches the `@NotFound` fallback, which *must* be raw and was otherwise
the one response a global header could never appear on. The explicit-role form is excluded — its sender is
a transformed slot whose type a middleware pins, and naming a transformed slot is already the "I am taking
over this primitive" signal.

**Every typed route drains**, not only those with a fold. The byte-identical emission plain routes used to
keep was given up deliberately: most routes have no `@Middleware` of their own, and a conditional drain
would have missed exactly those, silently.

**`WireMVCContext` is `public`, and that is forced.** A `@WireMVCBootstrap`'s `createRouteBuilder(for:)`
names its builder's context type and is written in the app's module, so an internal type cannot appear
there. The escape considered was an adapter `HTTPServer` whose `RequestContext` *is* the courier: the app's
signature is generic, so it would name the type without spelling it. **Spiked, and it does not save the
access** — the adapter must be public for the generated `@main` to name it, and

    type alias 'RequestContext' must be declared public because it matches a requirement
    in public protocol 'HTTPServer'

so its witness, and therefore the courier, must be public too. A public conformance to a public protocol
cannot hide its associated types. Both routes end in the same place.

**The adapter is still worth building, for a different reason.** It compiles — including for a base server
that is itself `~Copyable`/`~Escapable`, which `HTTPServer` permits — and it moves the wrapping into
`serve(handler:)`. That leaves `createServer()` and `createRouteBuilder(for:)` **unchanged in every app**,
where the direct approach makes every composition root edit three type arguments. Source compatibility, not
encapsulation, is what it buys.

**Not addressed:** `Content-Length`. Nothing sets it, so bodies frame as chunked. Fixing it is a framing
decision (a declared length conflicts with a `Transfer-Encoding` the transport may add) and wants deciding
on its own, not as a side effect of the header work.

## The generated shape (from spike-12)

Per route, the macro emits one `builder.register(method:path:handler:)` call with a thin
closure; decode/encode/status logic lives in a WireMVC runtime support layer the closure
calls. The handler receives the matched path parameters plus the proposal's `~Copyable`
streaming reader and response sender:

```swift
// @Get("/{id}") @JSONResponse  →  200, JSON body
builder.register(
    method: .get,
    path: "/users/{id}",                                              // prefix + subpath
    handler: { _, pathParameters, _, responseSender in
        let id = String(pathParameters["id"] ?? "")                   // @Path id
        let result = try await self.getUser(id: id)
        try await WireMVCResponse.json(result, status: .ok, on: responseSender)  // @JSONResponse
    }
)
```

The witness that carries these registrations is `registerWireRoutes<Builder: RoutableHTTPServerBuilder>(on:)`
— generic over the builder, with the `~Copyable` inverse requirements restated at the generic
boundary (they don't propagate; the proposal's own `serve` does the same). See
`spike-12` for the full
hand-written witness served on a real `NIOHTTPServer`, and
`spike-13` for the same
witness driven through `some ServerTransport`. spike-11's decode/encode logic is unchanged;
only the registration target moved from `transport.register` to `builder.register`.
