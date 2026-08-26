# Scope-aware middleware and bindings — a design note

> **Status:** design note, 2026-08-26; **step 1 built, 2026-08-27** (see *Proposed sequence*).
> Everything else here is still a design. It records why a route-scope
> `@Middleware` cannot reach a request-scoped binding, what four other frameworks do about it, and — on
> that evidence — **a decision that a middleware's dependencies stay app-scoped permanently**, rather than
> build a scoped tier. What replaces the scoped tier is two smaller things: route identity carried on the
> box, and authorisation moved into the argument.
>
> It also **corrects two claims** made in
> [wire-mvc-examples' parity note](https://github.com/tachyonics/wire-mvc-examples/blob/main/Documentation/Notes/HummingbirdExamplesParity.md)
> and in swift-wire's `RemainingSurfaceWork.md` while the `auth-abac` item was being written. See
> *Two claims to withdraw*.
>
> Written out of that item, which is the first thing in these repositories to want any of this. Every
> compiler diagnostic quoted below was produced by compiling the case against `SwiftHttpServerExample`,
> not reasoned about — the same discipline the static-file item needed, and for the same reason: three
> steps of the obvious reasoning turned out to be wrong.

## The problem, in one route

`auth-abac` wanted a route-scope gate that could see the request-scoped identity its controller already
injects. It cannot, so the gate resolves the subject from the request and the request-scoped `Caller`
binding resolves it again a moment later. Two dictionary reads in that example; two round trips against a
real identity provider.

The shape of every generated register closure is what decides it:

```swift
let wireMVCChain = wireCompose { self._wireFactory_….create(…) }        // ← fold built here
try await wireMVCChain.intercept(input: wireMVCBaseBox) { finalBox in
    return try await finalBox.withPendingContents { request, _, _, responseSender, drain in
        do {
            let (controller, teardown) = try await self._wireEnterScope(request)  // ← scope entered here
```

The fold is built and entered **before** the scope, because the scope entry happens inside the fold's own
terminal. So at the moment a middleware is constructed there is no request scope in existence.

## What is actually blocking it

Four layers, in increasing order of how much they matter.

**1. `@Factory` is a lifetime macro that nothing recognises as one.** Compare the attachment kinds:

```swift
@attached(member, names: named(init), named(key))  public macro Singleton(…)
@attached(member, names: named(init), named(key))  public macro Scoped<Seed>(seed:…)
@attached(member, names: named(init))              public macro Factory(_ key: FactoryKey)
@attached(peer)                                    public macro Contributes(to:…)
@attached(peer)                                    public macro Provides(…)
```

`@Factory` sits in the lifetime-macro family by attachment shape — it synthesises the `init` because no
other such macro is present to do it. Which is why adding one is `invalid redeclaration of 'init(…)'`: a
contradiction surfacing as a name collision, because nothing in the model knows the two are alternatives.
See *The decision* for what each of the two objects' lifetimes actually is.

**2. Annotating the template both ways discovers it twice, in incompatible roles.** With the `init`
supplied by hand — both macros defer to a user-written one — a single build emits both of:

```
note:  scope '_WireFactory_ControllerMiddleware_screenAccess' to @Scoped(seed:) too …   ← template role
error: '@Singleton ScreenAccess' can't be a single instance: generic parameters … unbound  ← binding role
```

`DiscoveredFactoryTemplate` has no `scope` field, so there is nowhere to record the intent; and a factory
template's generics are *assisted*, which is precisely what a binding's may not be. That collision is the
generic-arity error.

**This is not a type-system problem.** The synthesised factory is non-generic — the assisted parameters
live on `create`, not on the struct — so a factory *object* would sit in a scope perfectly well. What
cannot be scoped is the *template as a binding*, which is what the annotation asks for.

swift-wire's guided fix-it for this names a combination that has no spelling; filed as
[swift-wire PendingIssues/16](https://github.com/tachyonics/swift-wire/blob/main/PendingIssues/16-factory-template-scope-hint.md).

**3. A seeded scope returns exactly one subject, and is pruned to it.** `ScopeEntryEmission.swift:124`
emits `return (subject, teardown)`, and `:80` prunes with `reachableBindings(from: subjectLocal)`. A
controller does not depend on its own middleware, so a scoped middleware would be unreachable from the
subject and pruned away — and there would be no slot to hand it back through.

**4. There is no channel from a middleware to the handler.** The terminal destructures the box and
**discards the context** — `withPendingContents { request, _, _, responseSender, drain in` — so even a
context-transforming middleware, which the box does support, reaches no handler.

## Two claims to withdraw

**"Closing the double resolution needs a framework change, not an application one."** False. An application
closes the *cost* by caching the directory lookup, which is what a deployment with a real identity provider
does anyway. What a framework change buys is narrower: the two tiers agreeing *by construction* rather than
by both happening to call the same method. In the shipped example both go through
`PrincipalDirectory.principal(presentedBy:)`, so they cannot diverge on parsing either. The item is
therefore smaller than those notes say.

**The implied fix — "let middleware be scoped" — is the wrong answer for this shape.** Simply moving the
scope outside the fold costs four things, three of them behavioural:

- **A gate refusal currently skips scope construction entirely.** When a middleware responds the box
  becomes `.responded`, and `withPendingContents` is a no-op in that state (`Middleware.swift:206`), so
  `_wireEnterScope` is never called. That is the whole value of a pre-authorisation filter.
- **Scope-entry throws would bypass the fold.** `Unauthenticated` is caught in the terminal today, after
  every middleware ran. Outside the fold, a `401` would carry no contributed header fields — CORS's
  `Access-Control-Allow-Origin` and `ResponseDefaults`' `x-content-type-options` both vanish, and a
  cross-origin caller cannot read the `401` it was given. Always-run observers stop observing.
- **The scope would be seeded from the wrong request.** The terminal seeds from the request destructured
  out of the *final* box. A transforming middleware rebuilds the box through `withContents` and passes
  `request:` explicitly, so a rewrite upstream is visible to the scope today and would not be.
- **Teardown ordering flips relative to the response.** The teardown `defer` sits inside the terminal's
  `do`, and `send(on:)` is after the `do`/`catch` — so request-scoped teardown completes *before* the
  response is written. Wrapping the scope around the fold runs it after.

## What the prior art does

| framework | outer tier | inner tier | boundary |
|---|---|---|---|
| ASP.NET Core | middleware (`IApplicationBuilder`) | MVC filters — authorization → resource → action → exception → result | routing + model binding |
| Spring | servlet `Filter` | `HandlerInterceptor`, then method security (`@PreAuthorize`) | dispatcher / method invocation |
| Symfony | `kernel.request` listeners | `kernel.controller_arguments` listeners (where `#[IsGranted]` runs) | argument resolution |
| NestJS | middleware | guards → interceptors → pipes | route resolution |
| Hummingbird | router middleware | — | one tier only |

**Four of five have two tiers, and none of them splits on the scope boundary.** ASP.NET is explicit that
its inner tier exists for a different reason: *"filters differ from middleware in that they're part of the
runtime, which means that they have access to context and constructs"* — `ActionExecutingContext`, the
selected action, the bound arguments. Their guidance: *"Use filters when your logic is action-specific or
varies by endpoint; use middleware for consistent global behavior."*

**And ASP.NET solves our exact problem without a second tier:**

> "Middleware is constructed once per *application lifetime*… Because middleware is constructed at app
> startup, not per-request, *scoped* lifetime services used by middleware constructors aren't shared with
> other dependency-injected types during each request. If you must share a *scoped* service between your
> middleware and other types, **add these services to the `InvokeAsync` method's signature**."

```csharp
public async Task InvokeAsync(HttpContext httpContext, IMyScopedService svc)
```

Method injection — an assisted parameter. Note *why* their constructor injection fails: the middleware
**object** outlives the request, while the DI scope exists for the whole pipeline. Ours is the harder case:
the scope genuinely does not exist yet. NestJS is the one framework that does allow a request-scoped guard,
and documents the cost as a caveat — a request-scoped provider pulls its whole consumer chain into the
request scope.

**Nobody injects the principal into a policy component as a constructor dependency.** Spring reads
`SecurityContextHolder` (thread-local); ASP.NET reads `AuthorizationHandlerContext.User`; Hummingbird reads
`context.identity`; Symfony passes `TokenInterface $token` **as a parameter** to `voteOnAttribute`. Always
ambient or an argument, never a dependency.

**Route context lives with the request, not in a concept of its own.** Symfony puts it in
`$request->attributes` (`_route`, `_route_params`); Spring stores path variables as a request attribute
under `HandlerMapping.URI_TEMPLATE_VARIABLES_ATTRIBUTE`; ASP.NET carries `Request`, `RouteData`, `User` and
`RequestServices` on one `HttpContext`. NestJS is the outlier, passing an `ExecutionContext` parameter. All
three of the majority *mutate an ambient object and key it stringly*, which is the part not to copy.

## The decision: a factory template's lifetime is its own, and it is not a scope

**The middleware is neither a singleton nor scoped, and it does not need to be either.** Being precise
about which of the two objects has which lifetime is what settles this:

| | lifetime | a graph binding? |
|---|---|---|
| `_WireFactory_<key>` — the factory | app; constructed once in the graph body | yes |
| `ScreenAccess<Ctx, Reader, Sender>` — the product | **per `create` call** — per request, per route | no |

The product is per-request, and it has to be: it is generic over the box roles, so its type is not
determined until the use site. That is not a scope, it is *per-call* — the third lifetime every mainstream
container has and Wire does not name (`AddTransient`, Spring's `prototype`, Guice's unscoped default).

**So `@Factory` already is that lifetime**, and the thing missing is that nothing says so. An earlier draft
of this note proposed requiring `@Singleton @Factory(K)`, which is wrong for exactly the reason
`@ScopedFactory` was rejected two paragraphs later: it names the *factory's* lifetime while sitting on the
*product's* declaration, and the product is not a singleton.

**Dagger, which Wire borrowed "assisted parameters" from, has this model exactly** — and its assisted type
carries no scope annotation at all:

> "**@AssistedInject types cannot be scoped.**" … "Only the factory becomes a graph binding … The factory
> has application lifetime. The product objects have whatever lifetime the caller determines — each factory
> call creates a new instance with **no scope management**."

So: `@Factory(K)` stays as it is written today, **no pair required and no migration**, and gains three
things it should always have had.

1. **A documented lifetime.** A `@Factory` template is constructed per `create` call and is not a binding;
   its `@Inject` members are resolved **once, where the factory is constructed** — app scope. That second
   half is the constraint that actually bites, and the reason a scoped dependency is impossible. The
   product's own lifetime was never the obstacle.
2. **A mutual-exclusion diagnostic.** `@Factory` alongside `@Singleton` or `@Scoped(seed:)` is two lifetime
   macros on one type. Diagnosed as that, which is a better error than `invalid redeclaration of 'init(…)'`
   — and dissolves it, since only one such macro may be present to synthesise the initialiser.
3. **A cross-scope hint that is true.** Today's fix-it offers a fix that cannot be written. It becomes:

   ```
   error: no binding produces 'Caller'
   note: 'Caller' is bound in @Scoped(seed: HTTPRequest.self) scope, not @Singleton
   note: 'ScreenAccess' is a @Factory template. Its @Inject members are resolved once, where the
         factory is constructed — app scope — while the template itself is constructed per `create`
         call and has no scope of its own, so a scoped value cannot be one of them. Take it as an
         assisted parameter, or move the concern to where the scope is live: a handler, or a
         RequestBound binding.
   ```

**What is declined, and what would reopen it.** A second, scoped middleware tier — folded inside the scope,
its factory's dependencies resolved per request. Declined on three grounds. The prior art is unanimous that
an outer middleware tier's dependencies are app-scoped: ASP.NET's middleware "is constructed once per
application lifetime" with scoped services arriving by method injection, Dagger forbids scoping an assisted
type outright, and NestJS — the one framework permitting a request-scoped guard — documents the cost as a
caveat rather than recommending it. After *Route identity* below, the tier's only remaining charter is
scope injection, which the survey says is exactly what does not earn a tier. And nothing else in the stack
consumes a factory, so a scoped template would have no client but a tier we are not building.

It reopens on a concrete forcing case: **a rule that must run before the handler *and* needs request-scoped
state** — a per-route rate limiter keyed on identity, or an audit record that must exist whether or not the
handler runs. `auth-abac` is not one; it wants authorisation, which the argument seam serves better.
Reopening is cheap by construction: the constraint is a diagnostic, not an architecture.

## Route identity: `RouteContext`, one type and two carriers

A middleware is not told which route it is folded onto. The matched template and the path parameters stay
in the generated register closure and never enter the box, which is why `auth-abac` could not express a
per-route rule without a distinct `FactoryKey` and middleware type per route.

**The courier cannot carry them, and the reason is ordering.** `GlobalMiddlewareHandler.handle` builds its
box from `handle`'s four values and *then* calls `inner.handle` — the router. So the courier is constructed
**before the match happens**; there are no path parameters in existence. The courier exists to carry things
*down through* `handle` (the response-header registry, contributed above the router and drained below it).
Path parameters travel the other way: produced *by* the router, consumed below it. They never cross the
boundary the courier exists to cross.

**They are already in the right frame.** `builder.register(…) { request, requestContext, pathParameters,
reader, responseSender in }` — third parameter, dropped today for any route without a `@Path`. So no
plumbing is needed to get them there; the only question is whether they go into the **box**.

```swift
RequestResponseMiddlewareBox.pending(request:requestContext:route:reader:responseSender:responseHeaders:)
public var peekedRoute: RouteContext?     // alongside peekedRequest
```

**Carry the template, not just the parameters.** `["id": "notes"]` gives the values but not the identity —
`/documents/{id}` and `/things/{id}` are indistinguishable from parameters alone. The template is the
`path:` argument to `builder.register`, compile-time text the codegen already holds. So the payload is
`RouteContext { template, pathParameters }`.

**One type, two carriers**, which is what unifies this with the seeding idea:

| carrier | reaches | prerequisite |
|---|---|---|
| the **box** | tier-1 middleware, as it exists today | none |
| the **seed** | the controller and every scope member | a seeded scope yielding more than its subject |

The seed carrier also retires a papercut the box cannot touch, because a handler has no access to the box:
`TodosController.create`, `JobsController.submit` and `DocumentsController.create` each hand-write a
`Location` under a comment apologising that "`@Controller("/todos")` is compile-time text the handler has
no runtime access to".

Seeding it is not a new concept, either — `GraphInputsScanning.swift` sets that up:

> "A seeded scope takes a value the graph cannot construct (the request); `@GraphInputs` gives the *root*
> graph the same door. **Each stored property of the annotated struct becomes an ordinary app-scope
> binding** whose producer is the caller-supplied value."

The asymmetry is that the root graph takes a *struct* whose fields each become bindings, while a seeded
scope takes a *single value*. Closing it makes `@Scoped(seed: WireMVCRequestScope.self)` — `{ request,
route }` — and **injection sites do not change**, because `HTTPRequest` is still a scope binding; it just
arrives as a property of the seed. Seed identity *is* scope identity ("sibling seeded scopes are isolated
by design"), so the annotation moves on four types in wire-mvc-examples, one line each.

**Three things to get right.**

- **The global tier has no route, and that must be visible rather than silently empty.** `peekedRoute` is
  `RouteContext?`: `nil` means "you are outside the router", an empty `pathParameters` means "matched, and
  this route has none". An empty dictionary would conflate them — the same care that gave the three
  reachable `404`s distinct bodies so `StaticFileServingTests` could tell which layer answered.
- **The `.responded` case keeps only the request today**, "so always-run observe middleware can still read
  it". Route context should follow the same rule, for the same reason.
- **Phase 5 is an allocation pass**, so whether holding the dictionary longer costs anything is to be
  measured rather than asserted. It is already a closure parameter, so it ought to be a move.
- `registerNotFound` has no matched template, and `[String: Substring]` borrows the request's storage —
  safe only because the request rides alongside it, which is a property of the type's design and belongs in
  its doc comment.

## Scoped state in tier 1: assisted parameters

ASP.NET's answer, at the constructor rather than the method. Tier 1 keeps its position and is handed what
it needs.

```swift
@Factory(ControllerMiddleware.screenAccess)
@MiddlewareFactory
public struct ScreenAccess<Ctx, Reader, Sender>: Middleware {
    @Inject   var engine: PolicyEngine       // graph — resolved once, app scope
    @Assisted var caller: Lazy<Caller>       // use-site — supplied per request by the fold
```

```swift
// emitted create, today and with an assisted value
func create<RequestContext, Reader, ResponseSender>(_: RequestContext.Type, …)
func create<RequestContext, Reader, ResponseSender>(caller: Lazy<Caller>, _: RequestContext.Type, …)
```

**The emission already exists.** Under a keyed test suite the fold calls
`create(doubles: wireMVCDoubles, Builder.RequestContext.Base.self, …)` — a per-request value threaded into
`create` ahead of the box-role metatypes (`RouteCodegen.swift:339`). What is new is a user being able to
declare one. `@Assisted` is also consistent vocabulary: `@Factory`'s own documentation already calls the
template's generics "assisted parameters".

**`Lazy<Caller>` rather than `Caller` is load-bearing.** `Lazy.get()` is `async throws` regardless of `T`'s
init colour and memoises through a tri-state `Mutex`, so *forcing it* is what enters the scope and never
forcing it costs nothing — which preserves the pre-authorisation property that reordering would destroy.

Declining rather than propagating keeps authentication where it belongs:

```swift
// An unauthenticated request is the terminal's to answer, so the fold keeps running
// and its contributions still land on the 401.
guard let caller = try? await caller.get() else { return try await next(input) }
```

**Nothing forces this today**, and after *Route identity* it may never be forced: the remaining demand is a
middleware that must run *before* the scope exists and still needs something from it, which is narrow.

## Authorisation in the argument: graph-aware bindings

Give `RequestBound` access to the graph, so a binding can consult an injected policy engine, store, or the
request-scoped caller.

```swift
@Get("/{id}")
@JSONResponse
public func read(@AuthorizedDocument(.read) document: Document) -> Document { document }
```

```swift
@Scoped(seed: HTTPRequest.self)
public struct AuthorizedDocument: RequestBound {
    public typealias Value = Document
    @Inject var documents: DocumentStore
    @Inject var policies: PolicyEngine
    @Inject var caller: Caller

    public func bind(name: String, request: HTTPRequest,
                     pathParameters: [String: Substring], body: [UInt8]?) async throws -> Document {
        guard let id = pathParameters["id"].map(String.init),
              let document = documents.find(id: id) else { throw DocumentNotFound() }
        try policies.authorize(caller.query(action(from: name), on: document.attributes))
        return document
    }
}
```

**The seam is already on the right side of the scope**, which is the decisive advantage. Binding happens
*after* scope entry in every generated route:

```swift
let (controller, teardown) = try await self._wireEnterScope(request)
let requestBody = try await WireMVCRequest.collectBody(reader)
let input = try await JSONBody<CreateDocument>.bind(…)
```

No reordering, no lazy handle, no assisted parameter. Every workaround above compensates for the fold being
on the wrong side of the scope; this seam simply is not. It is also already the *only* consumer of
`pathParameters`, which is why route-shaped logic has had to be a binding — a monopoly *Route identity*
breaks at the other end.

**What it buys is not brevity.** `DocumentsController` states that "the order of the two lines in each item
handler is load-bearing, and it is load first" — restated in four handlers, any of which could get it
wrong, and a *new* route that omits `try policies.authorize(…)` compiles, serves, and is unauthorised with
nothing but review to catch it. With the binding, a route taking a `Document` cannot skip the check,
because the check is how a `Document` comes into existence. **An unauthorised route stops being writable**,
which is categorically stronger than anything the middleware tiers offer, and it is the design's own idiom
one level in: authentication is already a precondition of the *scope* existing.

Prior art: Symfony's argument resolver plus `#[IsGranted('edit', 'post')]`, and Spring's
`@PreAuthorize("hasPermission(#contact, 'write')")` over a resolved parameter.

**Costs.**

- **The typed client.** The emitter uses the handler's parameter type on both sides, so a loading binding
  would emit `AuthorizedDocument<Document>.send(value: document)` — nonsense; the client must send an id.
  The protocols already anticipate a mismatch: `RequestSendable` declares its **own** `Value`, deliberately,
  "so a streaming binding — which implements `RequestBodyReading` and never `RequestBound` — can still be
  sent". What is missing is codegen reading the send-side `Value` rather than assuming the parameter type.
  The fallback is loud rather than silent: a binding that cannot be sent has "its route reported rather
  than silently dropped".
- **It widens "binding" from decode to resolve.** A `bind` that reads a store changes the failure surface
  and the timing. Symfony keeps these as two concepts — the Serializer decodes, the ArgumentResolver loads
  — so the question is whether `RequestBound` absorbs both roles or gains a sibling.
- **An instance form.** `bind` is a static requirement today, emitted as
  `try await \(binding.wrapper)<\(type)>.bind(\(args))`.
- **An annotation-argument channel.** `bind` receives `name: String` (the attribute's argument when given),
  so `@AuthorizedDocument("read")` works stringly. Doing it properly means passing the annotation's
  arguments verbatim, which Wire already does for `@ConfigProperty`.

**What it does not solve:** the collection route, which has no single resource to bind and keeps filtering
in the handler; and tier-1 screening, which stays outside the scope — correctly, since refusing before any
of this runs is the point.

## What each piece solves

| | route identity in tier 1 | scoped state in tier 1 | authorisation unforgettable | prerequisite |
|---|---|---|---|---|
| `RouteContext` on the box | ✔ | ✘ | ✘ | none |
| `RouteContext` in the seed | n/a (reaches the scope) | n/a | ✘ | scope-entry widening |
| assisted parameters | ✘ | ✔ | ✘ | none beyond the emission |
| graph-aware bindings | already has `pathParameters` | ✔ (in the binding) | ✔ | scope-entry widening |
| ~~scoped middleware tier~~ | ✔ | ✔ | ✘ | **declined** |

## Proposed sequence

Each step names what forces it. A step with no forcing case is not scheduled — the argument
`StreamingResponseTier.md` makes against itself applies here too: a capability with no route asking for it
is the weak case restated.

**1 — wire-mvc: `RouteContext` on the box. Done, 2026-08-27.** A sixth field on `.pending`, a
`peekedRoute: RouteContext?` accessor, and the register closure passing what it already receives. **No
prerequisite** — not the scope-entry widening, not the `@Factory` change, not a tier. **Forced by:** a
middleware cannot tell which route it is folded onto, which is why `auth-abac` could only express per-route
policy as a distinct key and middleware type per route. Also the step that retires the scoped tier's
charter, so it comes first.

Three things the design above got right and one it did not say:

- **The route rides in `.responded` too**, as the note argued it should, so an always-run observer can log
  which route a gate refused.
- **`nil` really is a distinct answer from empty**, and is now load-bearing rather than documented: the
  global tier's box carries `route: nil` because it folds around `handle` and the match has not happened,
  and `WireMVCFallbackExample` asserts `(none)` against `(empty)` on the wire so the distinction cannot
  quietly collapse.
- **`route:` is a required argument, not a defaulted one**, for the reason the response-header registry is:
  a transforming middleware rebuilds the box through `withContents`, and a defaulted parameter would let it
  unname the route silently. The one transforming middleware in the fixtures took the break, which is the
  evidence that the compile error fires.
- **What the note did not say:** the *destructures* change too, not only `.pending`. `withContents` and
  `withPendingContents` both yield the route, so the terminal sees it off the **final** box rather than off
  the register closure — the same property the request already had, and the one that makes an upstream
  rewrite visible to whatever consumes it. That costs every terminal an extra `_`, which is the whole price.

The terminal's `@Path` binds still read the register closure's `pathParameters` directly, not the box's.
Nothing yet wants the boxed copy there, and routing the binds through the box would be a behavioural change
(a middleware could rewrite a path parameter) that no route is asking for.

**2 — swift-wire: name `@Factory` as a lifetime, and diagnose it as one.** Documentation, plus two
diagnostics: `@Factory` alongside `@Singleton`/`@Scoped` refused as two lifetime macros on one type, and a
cross-scope hint that says what is actually true. **No source migration** — `@Factory(K)` is already
written correctly everywhere; what changes is what the compiler says when it is combined or when a scoped
value is asked of it. **Forced by:**
[PendingIssues/16](https://github.com/tachyonics/swift-wire/blob/main/PendingIssues/16-factory-template-scope-hint.md),
where the shipped fix-it names a fix that cannot be written.

**3 — swift-wire: a seeded scope yields more than its subject.** `ScopeEntryEmission` returns the subject
plus any scope binding a consumer asked for; `reachableBindings(from:)` takes a set of roots. **Forced by:**
step 4.

**4 — wire-mvc: graph-aware bindings.** An instance form for `RequestBound`, resolved from the scope;
codegen reading `RequestSendable.Value` for the client's send side; a diagnostic for a scoped binding on a
`@Singleton @Controller`. **Forced by:** `auth-abac`. **Stop here if that is the whole appetite** — this
closes the item on its own.

**5 — wire-mvc: `RouteContext` in the seed as well.** The composite seed, so the controller and every scope
member can reach it. **Forced by:** three controllers hand-writing a `Location` under a comment apologising
for it. Cheap once step 3 lands; skip it if step 3 never does.

**6 — wire-mvc: assisted parameters.** **Forced by: nothing today**, and possibly never after step 1. Do
not schedule without a middleware that must run before the scope exists and still needs something from it.

**Declined — the scoped middleware tier.** Reasons and the reopening condition are in *The decision* above.

**Never — the bound-arguments tier.** ASP.NET's *action*-filter position, seeing decoded arguments. The box
is one type across every route on a controller, which is what lets one `@Middleware(key)` fold uniformly;
an argument-aware `Input` differs per route, so one key could no longer name one middleware. Both escapes
are bad: an untyped bag — ASP.NET's own `IDictionary<string, object?>`, an admission — or a middleware
generic over an argument tuple, which is the user-written-constraint tax `StreamingResponseTier.md`
identifies as tier-killing. Worse, some routes have no bound arguments *by design*: `POST /upload/stream`
hands the reader to the handler as a live stream, so such a middleware would cover some of a controller's
routes and silently not others. And `collectBody` consumes the `~Copyable` reader to produce the arguments,
so the resulting box is a different box with different linear contents, not the same box with extra fields.
Recorded here so a later reader finds the argument rather than the gap.

## What this does not change

The `auth-abac` **two-tier authorisation split is not a framework limitation and no step here removes it.**
An ABAC decision is a function of subject, action, resource and environment; the resource is not loaded when
the front tier runs, so partial evaluation is sound for denial and unsound for permission, and the gate must
answer deny-or-undecided. Every framework in the survey has the same split — ASP.NET names both halves,
*declarative* and *imperative*. Graph-aware bindings move the second half from the handler body into the
argument; they do not merge the halves. The authorisation model itself, including where this stack's
abstention handling is better and worse than Symfony's voters, belongs to the parity note rather than here.
