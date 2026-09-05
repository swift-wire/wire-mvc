# Route error handling — terminal-scoped `@ErrorResponse` (M5.4E design record)

> **Status:** **shipped.** Terminal-scoped `@ErrorResponse` serves in `wire-mvc` — a thrown error is
> mapped to a status by the route's, then the controller's, then the `@WireMVCBootstrap` root's tier, and
> an unmapped throw is written by the terminal rather than re-thrown. Iteration **M5.4E** in
> ../M5_PLAN.md, interleaved with M5.4. Extends the middleware/box model in
> [WireMVCMiddleware.md](WireMVCMiddleware.md) and the M5.0 surface in
> [WireMVCDesign.md](WireMVCDesign.md). Resolves the plan's "Response surface beyond
> `@JSONResponse` — error→response mapping" open decision.

## The model in one paragraph

Error→response mapping is a **terminal (route/controller) concern**, expressed with `@ErrorResponse`
declarations at controller scope (covering every route) and route scope (one route), composed
**route-inner → controller-outer**, first-match-wins. They are consulted inside the terminal's
existing `catch` — the same place the shipped witness already turns a `WireMVCBindingError` into a
status (`RouteCodegen.closureBody`) — so a handler that throws a typed domain error (`NotFound`, a
validation failure), *or* a request-scoped binding that throws while the terminal constructs the
request scope, has that error mapped to a response written on the sender the terminal still holds. An
`@ErrorResponse` is **not** a graph-injected component: it is a `(errorType → status)` pair or an
inline typed-parameter closure `{ (e: E) in … }`, read from the annotation syntax and folded directly
into the generated `catch` — **pure codegen, no `.injectsFromGraph`, no new Core capability.** The
order of consultation is: route pairs → controller pairs → the built-in
`WireMVCBindingError`→status → a `Swift.Error` catch-all if one is declared → **rethrow**. An unmapped
throw is re-thrown out of the middleware chain to the framework, which produces its default (500) —
WireMVC never synthesises a 500 of its own.

> **Correction (M5.5):** the rethrow terminus assumed the framework produces a 500 on an escaped
> throw. It does not — the target servers *abort the connection* (see
> [LinearSenderErrorModel.md](LinearSenderErrorModel.md)). M5.5 replaces the final **rethrow** with a
> built-in **500 write** at the terminal (which holds the sender), so an unmapped *handler* throw is a
> clean 500 rather than a dropped connection. *Middleware* throws still abort — WireMVC never holds
> their sender. The rest of the consultation order below is unchanged.

## Why terminal-scoped, not global middleware — the box forces it

The single load-bearing fact: in the Model-B box, **the sender lives *inside* the box**
(`.pending(request, requestContext, reader, responseSender)`), and calling `next` **consumes the
box**. So an outer middleware that wraps `try await next(input)` in a `do/catch` no longer has the
box — or its sender — on the catch path: the value was moved into `next`, which threw. It can
*observe* the error (log, metric) and rethrow, but it **cannot write a response to it** — there is
structurally no sender in hand.

The **terminal** is the one place that still holds the sender when the handler runs (inside
`withPendingContents { … responseSender … }`), so it is the only place that can convert a thrown
error into a written response. This is the same root as the short-circuit model (a middleware
responds by *writing* via the sender, never by returning a response value): the response is a sender
side-effect, and errors ride the throw channel, which only the sender-holder can turn back into a
response.

The lone exception is a **buffering (erasing) middleware**: one that hands `next` a box with a
*concrete* sender it owns, buffers the downstream response, and flushes on return. Because it kept
the real sender, it *could* respond to a downstream throw — but only by giving up streaming for that
subtree. That is a deliberate, heavy opt-in (already described in
[WireMVCMiddleware.md](WireMVCMiddleware.md)), not the default path, so it doesn't change the rule.

## Two throw sites, one `catch` — the scope-entry throw maps too

A route terminal has two places a request can fail after the middleware chain hands control back:

1. **A handler throw** — `try store.find(id)` throwing `NotFound` from inside the handler `call`.
   Always inside the terminal `do`.
2. **A request-scoped binding construction throw** — for a `@Scoped(seed:)` controller, the
   `let ctrl = try await self._wireEnterScope(request)` line that builds the request scope and the
   controller can throw (a throwing `@Inject init`, or a throwing request-scoped `@Provides`).

M5.4E places the scope-entry line **inside the terminal `do`**, so both throw sites are caught by the
same `catch` and mapped by the same `@ErrorResponse` entries, distinguished by the thrown error's
*type*, not its throw *site*. (App-scoped `@Singleton` controllers have no site (2) per request —
their dependencies are built once at bootstrap — so only handler throws arise there.) This is the
same unification ASP.NET Core (DI-activation throws caught by the exception pipeline) and Spring
(request-scoped bean / argument-resolver throws caught by `HandlerExceptionResolver`) reach; the
type-directedness (axum, tapir) means an app can still distinguish the two by throwing distinct types.

The **auth-failure division of labor (M5.4)** is unaffected and complementary: a gate middleware that
writes 401/403 and short-circuits to `.responded` runs *before* the terminal, so `withPendingContents`
skips the terminal body and the scope is never entered — no throw. A throwing scoped binding is the
alternative for "load-the-request-value-or-fail" auth (axum's extractor-rejection lineage) and is now
first-class via site (2). "One producer per status" stays a usage guideline, not a mechanism
constraint.

## The `@ErrorResponse` surface

`@ErrorResponse` is a peer marker (expands to nothing) read by the route codegen, at **controller and
route scope**. Two shipped forms, distinguished syntactically:

```swift
@ErrorResponse(Gone.self, .gone)                        // (1) type → status shorthand
@ErrorResponse({ (e: ValidationError) in                // (2) inline typed-parameter closure
    try .json(Problem(e.message), status: .unprocessableContent)
})
```

- **(1) `@ErrorResponse(E.self, .status)`** — the ultralight common case (`NotFound → 404`). No
  function, the codegen emits `(err is E ? WireMVCOutcome.status(<status>) : nil)`. Splices only a
  status expression — the same thing `@JSONResponse(status:)` already splices.
- **(2) `@ErrorResponse({ (e: E) in … })`** — an inline typed-parameter closure, the `@Teardown(<action>)`
  shape swift-wire already ships. The parameter type must be annotated (diagnostic otherwise) and is the
  matched error type; the codegen splices the closure through the `wireMVCRespond(to:_:)` helper, which
  casts and applies. Use for a richer response (a JSON body, logic).

**Static by construction.** A closure in an attribute has no `self`, so both forms are static — they map
a handler throw *and* a throwing request-scoped binding at scope entry, and there is no non-static case
to reject.

**The `Swift.Error` catch-all.** A form-(2) closure whose parameter is `Swift.Error` (`any Error`) — or
a form-(1) pair keyed on `Swift.Error` — matches every error, so it is the catch-all. It is consulted
*after* the built-in `WireMVCBindingError`→status (so validation stays 415/422 by default; a catch-all
written as a "500 envelope" does not silently swallow validation), and *before* the final rethrow. A
closure catch-all folds through `wireMVCRespondAny(to:_:)` as the non-optional terminal of the chain. At
most one per scope; a catch-all that is not the last error entry at its scope is diagnosed.

**Consultation order** (in the generated `catch let wireMVCError`):

```
route @ErrorResponse (source order)
  → controller @ErrorResponse (source order)
  → built-in WireMVCBindingError → .status(bindingError.status)
  → Swift.Error catch-all, if declared
  → throw wireMVCError   // rethrow out of the chain → framework default (500)
```

Route entries override controller entries for the same error type (route is consulted first);
two entries for the same error type *at the same scope* is a diagnostic. The chain is a `??` cascade of
`wireMVCRespond(to:_:)` (typed, optional) / inline `is`-status / the built-in / `wireMVCRespondAny`
(catch-all, non-optional); with no catch-all it terminates in `else { throw wireMVCError }`.

## Deferred: a named-function reference, and a graph-injected handler

Two richer spellings are **not** in the shipped surface:

- **A named-function reference `@ErrorResponse(SomeType.map)`** — attractive (a reusable, greppable
  mapping method), but blocked by the Swift compiler, not the codegen. `@ErrorResponse` is a typed peer
  macro (`(E) throws -> WireMVCOutcome`), so the compiler type-checks its argument even though the macro
  expands to nothing. A reference to the **annotated controller's own** method
  (`@ErrorResponse(UsersController.map)`) forces the compiler to resolve `UsersController` while its
  attached macros are mid-expansion → **circular reference resolving attached macro** (observed, not
  theoretical). A reference to a **separate** type compiles, but then the syntactic `WireMVCRouteGen`
  tool must read that method's parameter type across files — cross-type resolution it does not do, and
  it cannot see a *dependency module's* source at all. So the codegen diagnoses any `@ErrorResponse`
  function reference and steers to an inline closure. Deferred.
- **A graph-injected handler (the dependency-bearing tier)** — a mapping that needs an injected logger /
  localizer / request-scoped value. This is the reserved home for the "form 2" ergonomics *and* for
  deps, and it sidesteps the circular reference precisely because it is spelled as a **type metatype of
  an external binding**, e.g. `@ErrorResponse(MyErrorHandler.self)` where `MyErrorHandler` is a
  `@Singleton`/`@Scoped` conforming to a WireMVC error-handler protocol. Referencing an *external* type's
  metatype is not circular, and it rides the same `.injectsFromGraph` machinery `@Middleware` uses — the
  plugin lifts the binding onto the route-contributor proxy (`_wire<Handler>`) and the terminal consults
  `self._wireHandler.map(error)`, so the handler can `@Inject` its own dependencies. (One wrinkle to
  resolve when built: the status form's first argument is *also* a `.self`, so the graph-injected form
  likely needs a distinct spelling or a disambiguated injection pass.) Parallel to `@Middleware`'s
  generic-with-deps factory tier; deferred until an example forces injected deps in a mapping.

The two shipped forms are pure `error → response` codegen — no `.injectsFromGraph`, no new Core
capability — which is the whole M5.4E surface.

## Scope boundary

- **Raw handlers own their errors.** Once a `@RawRoute` handler starts streaming, the response is
  committed (the box's *no response post-processing* property), so a mid-stream throw cannot be
  remapped. `@ErrorResponse` is a typed-terminal concern; a raw handler that wants error responses
  writes them itself before it starts streaming.
- **Not global middleware.** Cross-cutting *observation* of errors (logging, tracing a failure) is a
  normal `@Middleware` that catches-and-rethrows around `next` — it just can't produce the response.
- **Header/status control beyond the mapped status** stays out of M5.4E (the plan's narrow
  status+JSON response surface); grows only when an example forces it.

## Prior art

The design space splits on **how a framework's handler/middleware yields a response**, which decides
where error handling can live:

- **Return-based stacks** — Vapor `ErrorMiddleware` (global), Spring MVC `@ExceptionHandler`
  (controller) + `@ControllerAdvice` (global), ASP.NET Core exception filters (action/controller/
  global) — map errors in *outer middleware* **because their response is a returned value**. Their
  *scoping* (route/controller/global, most-specific-wins) is the model `@ErrorResponse` copies; their
  *placement freedom* is what the box model removes.
- **Effect/sender-based streaming stacks** (ours) push response-writing to where the sender is held.
  The closest precedents are **Rust axum** (`Result<impl IntoResponse, E: IntoResponse>` — a
  type-directed error→response conversion at the handler, plus extractor `Rejection: IntoResponse` for
  construction failures — our two throw sites) and **tapir** (`errorOut` — a typed error output
  declared per endpoint). Both terminal/route-scoped and type-directed — `@ErrorResponse`'s shape.
- **`@ErrorResponse(E.self, .status)` specifically** is Spring's `@ResponseStatus(NOT_FOUND)` **moved
  off the exception class and onto the route/controller**, so the domain error stays a plain
  `struct NotFound: Error {}` with no WireMVC import — keeping controllers framework-agnostic.

Takeaway: adopt the return-based stacks' **scoping** (controller/route tiers, most-specific-wins) but
the effect-based stacks' **placement** (at the terminal, type-directed), because the box model makes
the terminal the only sender-holder.

## What this rests on

- **Shipped terminal codegen** — the `do/catch` that already maps `WireMVCBindingError` to a status
  and sends one `WireMVCOutcome` (`Sources/WireMVCCodegen/RouteCodegen.swift`). M5.4E generalises the
  `catch` and moves the scope-entry line inside the `do`; it does not add a runtime layer.
- **The Model-B box** — `RequestResponseMiddlewareBox` (`Sources/WireMVC/Middleware.swift`): sender
  inside the box, consumed into `next`, so only the terminal can respond to a throw.
- **`@Teardown(<action>)`** — swift-wire's shipped producer-form teardown reads a typed-parameter
  closure's parameter type and splices its body; the closure form (2) reuses that mechanism.
- **`wireMVCRespond` / `wireMVCRespondAny`** (`Sources/WireMVC/ErrorResponse.swift`) — the `throws`
  helpers the generated `??` chain folds each closure through, so the codegen needs no per-mapping
  effects analysis and the whole chain takes a single `try`.
- **`WireMVCOutcome.json`** — M5.4E adds a `static func json(_:status:) throws -> WireMVCOutcome`
  factory so a mapping can spell `.json(Problem(e.message), status:)` (today JSON lives only on
  `WireMVCResponse.json`).
- **No new Core capability** — unlike the earlier `@ErrorMap`-component sketch, the settled surface is
  pure adapter codegen: no `.injectsFromGraph`, no proxy field, no swift-wire change.

## Resolved / deferred

- **Resolved (shipped):** terminal-scoped `@ErrorResponse` — the `(E.self, .status)` shorthand and the
  inline typed-parameter closure — at controller + route scope, `Swift.Error` catch-all, consultation
  order ending in rethrow, scope-entry inside the `do`. Proven end-to-end in `WireMVCExample` (a thrown
  `UserStore.NotFound` maps to a 404 JSON body, served on `NIOHTTPServer`) and by the `WireMVCCodegen`
  golden/diagnostic tests. Pure adapter codegen; no swift-wire change.
- **Deferred:**
  - **A named-function reference** (`@ErrorResponse(SomeType.map)`) — blocked for the self-reference case
    by the compiler's circular-reference-in-attached-macro rule, and for the separate-type case by the
    tool's lack of cross-module signature resolution. Use an inline closure. (See the deferred section
    above.)
  - **A graph-injected handler** — the dependency-bearing tier, spelled as an external binding's metatype
    (`@ErrorResponse(MyErrorHandler.self)` / a distinct annotation) and lifted via `.injectsFromGraph`,
    for a mapping that needs `@Inject`ed deps. This is the reserved home for the "form 2" ergonomics.
    Lands when an example forces injected deps in a mapping.

---

<sub>Milestone shorthand used in this note (M1, M5.4, M7b…) is defined in ROADMAP.md; outstanding gaps are indexed in KnownGaps.md.</sub>
