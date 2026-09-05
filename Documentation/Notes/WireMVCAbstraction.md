# HTTP-framework integration — the two tiers, as built

> **Status:** current, rewritten at M5.6 against what shipped. This note was a design-space
> exploration written at iteration 4a, before M2; it predicted two tiers of HTTP-framework
> integration and a `_wireRegister` mechanism to carry them. **The tiers are right and shipped; the
> mechanism was retired in M2** and every trace of it is gone from here. What survives, and is the
> reason the note still exists, is the **progressive-adoption** story: how an app with an existing
> HTTP framework moves onto Wire in steps, and where each step stops.
>
> The settled surfaces live elsewhere and are authoritative over anything here: Tier 1 in
> [WireHummingbirdDesign.md](https://github.com/swift-wire/swift-wire/blob/main/Documentation/Notes/WireHummingbirdDesign.md), Tier 2 in
> [WireMVCDesign.md](WireMVCDesign.md) (with [WireMVCMiddleware.md](WireMVCMiddleware.md) and
> [RouteErrorHandling.md](RouteErrorHandling.md)). This note describes the *path between them* and
> does not restate either.

## The two tiers

The framing held. Wire offers two levels of HTTP integration with genuinely different trade-offs,
and they are separate packages rather than settings on one.

**Tier 1 — a framework-specific adapter.** The controller keeps its native framework shape. The
adapter automates the *application-level wiring* — constructing the controller from the graph and
mounting it — and abstracts nothing about routing. Routes and handler signatures stay
framework-shaped. Shipped in M2 as the external
[`wire-hummingbird`](https://github.com/tachyonics/wire-hummingbird), since archived.

**Tier 2 — declarative cross-framework routing.** The controller uses Wire-published annotations
(`@Controller`, verb, parameter and response annotations) and the build plugin generates route
registration. The controller's source is portable across runtimes. Shipped in M5 as
[`wire-mvc`](https://github.com/swift-wire/wire-mvc).

Tier 1 is the on-ramp for an app committed to one framework that wants compile-time-validated DI
without changing how it writes controllers. Tier 2 is for portability across runtimes, for a
preference for declarative routing, or for starting fresh.

### What the framing got wrong

Two things, both worth keeping because they are the kind of prediction that looks safe.

**There is no `WireVapor`, and the exploration was written mostly about Vapor.** Tier 1 was argued
through Vapor's `RouteCollection`/`boot(routes:)` idiom as the realistic on-ramp, and the adapter
that actually got built is Hummingbird's. Vapor reaches Wire through **Tier 2** instead —
`WireMVCServerTransport` mounts WireMVC controllers on Vapor — and a Tier-1 `WireVapor` is post-1.0,
conditional on a Vapor variant of task-cluster materialising. The forcing case decides which adapter
exists; the idiom's maturity does not.

**A Tier-2 composition-root macro per framework was anticipated, and retired.** M2 expected a
`@WireHummingbird` macro to generate the entry point, with `@WireVapor` beside it. What shipped is
one proposal-native `@WireMVCBootstrap` (M5.5), on the principle that a composition-root macro fights
the grain in those frameworks' own ecosystems — each has its own opinion about how an app starts, and
a macro that overrides it is a worse citizen than one that stays out of the way.

## The mechanism: collation, not registration

The exploration's mechanism was a generated `_wireRegister(instance:server:)` static member, plus a
Wire-published `WireMVCServer` protocol that framework adapters would conform to. **Both are gone.**

What replaced them is the **contribution-alias** contract (M2, [AdapterModel.md](https://github.com/swift-wire/swift-wire/blob/main/Documentation/Notes/AdapterModel.md)):
an adapter's annotation *aliases* `@Contributes(to: key)`, so an annotated type becomes an ordinary
contributor to a collated key, and the adapter's `apply` walks the collection. There is no
side-effecting registration member, no adapter-specific call the bootstrap has to emit, and nothing
in Wire Core that knows what HTTP is.

The difference is not cosmetic. `_wireRegister` made the graph *drive* registration, which put the
server in the graph and made every adapter a special case in the bootstrap. Collation makes the graph
*expose a collection* and leaves the mounting to the adapter, which is why the router stays outside
the graph, why two adapters coexist on one graph (task-cluster runs WireOpenAPI and WireHummingbird
together), and why M3 could re-home M2's model from `some RouterMethods<Context>` onto
`some ServerTransport` without touching Core.

The exploration's second question — *which* server protocol to target, a Wire-published one or
`swift-http-api-proposal`'s — resolved to the proposal, and further than predicted. It was framed as
a bet on ecosystem timing ("option 2 if the proposal has shipped a usable server abstraction by M5
time"). What actually decided it was a deployment floor: targeting macOS 26 makes `anyAppleOS 26.0`
unconditional, so WireMVC registers on `RoutableHTTPServerBuilder` over the proposal's `HTTPServer`
natively, and `some ServerTransport` is the *opt-in adapter* rather than the core. Neither option 1
nor the timing argument survived; the answer came from somewhere the question did not look.

## Progressive adoption

The path an existing Hummingbird app takes, in the order the steps are actually available. Each is
independently useful — nothing here requires the next step.

### Step 1 — join the graph, change nothing else

Two annotations on an existing controller. Its `addRoutes(to:)` is untouched, its handlers are
untouched, and Hummingbird still owns routing:

```swift
@Singleton
@HummingbirdController("todos")          // aliases @Contributes(to: HummingbirdKeys.routes)
struct TodoController {
    @Inject init(repo: any Repo) { self.repo = repo }

    func addRoutes(to router: some RouterMethods<some RequestContext>) { … }
}
```

The generated witness delegates to the hand-written method under the annotation's path:

```swift
extension TodoController: RouteContributor {
    func addWireRoutes<Context: RequestContext>(to router: some RouterMethods<Context>) {
        addRoutes(to: router.group("todos"))
    }
}
```

and the app mounts the collection in one call, with the router still its own:

```swift
let graph = try await Wire.bootstrap()
let services = WireHummingbird.apply(graph, to: router)
```

What this buys is the list-keeping: every `@HummingbirdController` is constructed with its
dependencies and mounted, with a compile-time error for a dependency that is not bound. What it does
not touch is anything about how a route is written.

The survey behind that shape is in [WireHummingbirdDesign.md](https://github.com/swift-wire/swift-wire/blob/main/Documentation/Notes/WireHummingbirdDesign.md): every
controller in hummingbird-examples already writes `addRoutes(to:)` as a bare convention, and
`Controller(deps).addRoutes(to: router.group("path"))` is the universal wiring line. The annotation
maps onto what was already there rather than asking for a new shape, which is why step 1 is two
annotations rather than a rewrite.

### Step 2 — move services onto `@Inject`

The controller keeps its framework shape and stops reaching into the framework's own service
container for collaborators. This is where compile-time validation starts paying: a missing
dependency is a build error at the controller rather than a runtime lookup failure on the first
request.

Also available at this step, and unrelated to routing: `@HummingbirdService` collates
`[any Service]` for swift-service-lifecycle, and `introspect()` exposes the graph's wiring model —
bindings, kinds, scopes, dependency edges, source locations — with a mountable JSON endpoint.

### Step 3 — write new controllers on Tier 2, beside the old ones

A WireMVC controller mounts on the same Hummingbird router through `WireMVCServerTransport`, so
Tier 1 and Tier 2 controllers serve from one app and one graph. This is the step where routing
changes shape, and it is per-controller rather than per-app — which is the whole point of the tiers
being separate packages rather than a mode.

```swift
@Singleton
@Controller("/tasks")
struct TaskController {
    @Get("/{id}")
    @JSONResponse
    func getTask(@Path id: UUID) async throws -> TaskItem { … }
}
```

What Tier 2 adds beyond portability, none of which Tier 1 expresses: `@Middleware` folded into the
generated route (with type-transforming middleware surfacing as a *compile error* at the generated
seam), `@ErrorResponse` mapping error types to statuses, `@RawRoute` for streaming and proxying, and
request-scoped controllers via `@Scoped(seed: HTTPRequest.self)`.

### Step 4 — Tier 2 alone, with the entry point generated

`@WireMVCBootstrap` on the composition root generates `@main`, folding in the `@NotFound` fallback,
global `@Middleware`, global `@ErrorResponse` tiers and an optional introspection mount. At this
point the app is proposal-native and Hummingbird is a deployment choice rather than a dependency of
the controllers.

There is no step that requires taking this one. An app can stop at 1, 2 or 3 indefinitely.

## Where the tiers stop

- **Request scope is Tier 2's, not Tier 1's.** `wire-hummingbird` collates **app-scoped**
  controllers; per-request controller construction (an app-scoped proxy contributor whose generated
  registration embeds per-request scope entry) shipped in M5.4, on WireMVC. An earlier version of
  this note, and the roadmap until M5.6, said the Tier-1 adapters handled it transparently. They do
  not, and there is nothing to fix — a Hummingbird controller reaches per-request data through
  Hummingbird's own context, which is what a Tier-1 controller is for.
- **Middleware is out of scope for Tier 1** and stays with the app (`router.addMiddleware`). A
  context-typed bidirectional value has no clean collation shape; Hummingbird's `RouterMiddleware` is
  incompatible with the proposal's `Middleware<Input, NextInput>` for the same reason. Tier 2 folds
  its own middleware into the generated route instead of publishing a parallel protocol — the
  exploration's "don't publish a parallel middleware protocol, let the ecosystem converge" held, and
  what it converged on is the proposal's.
- **WebSocket is neither tier's.** An upgrade is not a request→response body, so no transport-level
  adapter carries it. WebSocket routes are registered directly on the framework and coexist.
- **A second Hummingbird adapter would be a naming problem before it was a technical one.** If a
  WireMVC-tier Hummingbird package is ever written, it has to be named against the existing
  `wire-hummingbird` — two packages differing only in which tier they serve, both plausibly called
  the same thing, is a worse outcome than the capability is worth.

## The open questions, answered

The exploration closed with four questions for M5's first sitting. For the record:

1. **Which server protocol on first ship?** The proposal's, natively — see *The mechanism* above.
   Not the predicted reasoning.
2. **One shared adapter package or per-framework?** Neither, as posed. Tier 2 is one package with an
   opt-in `ServerTransport` adapter covering Hummingbird, Vapor and Lambda together, because the
   target is a protocol those runtimes already implement rather than three integrations.
3. **How tightly does WireMVC integrate with WireOpenAPI?** Much more tightly than "parallel adapter
   patterns that coexist", which is what shipped in M5 and was superseded in M6d: an OpenAPI
   operation is now a **WireMVC route**, `@OpenAPIController` contributes to
   `WireMVCKeys.routeContributors`, and `TransportKeys.handlers` retired as a collated key. One
   routing model, not two — see [WireOpenAPIAdvanced.md](https://github.com/swift-wire/wire-open-api/blob/main/Documentation/Notes/WireOpenAPIAdvanced.md).
4. **What does middleware look like by M5 time?** The proposal's `Middleware<Input, NextInput>`,
   composed as a per-route fold — [WireMVCMiddleware.md](WireMVCMiddleware.md).

## References

- [WireHummingbirdDesign.md](https://github.com/swift-wire/swift-wire/blob/main/Documentation/Notes/WireHummingbirdDesign.md) — Tier 1's settled model, and the
  hummingbird-examples controller survey it was refined against.
- [WireMVCDesign.md](WireMVCDesign.md) — Tier 2's settled surface.
- [AdapterModel.md](https://github.com/swift-wire/swift-wire/blob/main/Documentation/Notes/AdapterModel.md) — the contribution-alias contract that replaced `_wireRegister`.
- BootstrapCollation.md — how the apply steps collate, and what a Tier-1 app
  keeps doing by hand.
- `Wire`'s DocC article *Structuring an app with Wire* — the hexagonal framing these tiers sit in.

---

<sub>Milestone shorthand used in this note (M1, M5.4, M7b…) is defined in ROADMAP.md; outstanding gaps are indexed in KnownGaps.md.</sub>
