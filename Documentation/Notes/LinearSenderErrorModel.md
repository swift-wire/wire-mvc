# The linear-sender box model — where responses and errors can live

> **Status:** design record. Foundational to WireMVC's error story. Deepens the "Why
> terminal-scoped, not global middleware" section of
> [RouteErrorHandling.md](RouteErrorHandling.md) and the Model-B box in
> [WireMVCMiddleware.md](WireMVCMiddleware.md). Referenced by the M5.5 composition-root
> design (../M5_5_PLAN.md) for the *"what happens when a middleware
> throws"* question, and **corrects** RouteErrorHandling.md's "unmapped throw → framework
> 500" terminus (see [Correction](#correction-wiremvc-must-synthesise-its-own-terminal-500)).

## The model in one paragraph

WireMVC (Model B) makes the response sender a **linear** value — `~Copyable`,
single-owner — that lives *inside* the middleware box and is **consumed** as the box flows
toward the terminal. A response is a *side-effect on the sender*, not a returned value; an
error rides the *throw channel*. Everything about where error handling can and cannot live
follows from **one invariant** plus **one limitation**:

- **Invariant — only the frame currently holding the sender can turn an outcome into a
  response.** The sender is move-only, so at any instant exactly one frame owns it. A
  success writes through it; an error is turned into a written response only by whoever
  holds it *at throw time*.
- **Limitation — writing is `async`, so a value's `deinit` can't do it.** When the
  sender-holding frame unwinds on a throw without writing, the sender is *dropped*, and a
  `deinit` cannot `await` a response onto the wire. This is exactly why the proposal
  defines a dropped, unwritten sender as **"aborted"** rather than a 500.

From those two facts: handler throws are mappable (the terminal holds the sender), middleware
throws are not (the throwing frame drops it), and WireMVC must synthesise its own terminal
500 because the server *aborts* rather than 500s on an escaped throw.

## The invariant, precisely

The box is `RequestResponseMiddlewareBox` (`Sources/WireMVC/Middleware.swift`) in its
`.pending(request, requestContext, reader, responseSender, responseHeaders)` shape. The proposal's middleware
protocol threads it linearly (`swift-http-api-proposal/Sources/Middleware/Middleware.swift:45`):

```swift
func intercept<Return: ~Copyable>(
    input: consuming Input,                                   // the box — moved in
    next: (consuming NextInput) async throws -> Return        // consumes the box downward
) async throws -> Return
where Input: ~Copyable, ~Escapable                            // the box cannot be copied or escape
```

Two things fall out of the signature itself:

- **`Input: ~Copyable, ~Escapable`.** The box (and the sender in it) can't be copied to
  keep a spare handle, and can't escape the call scope — so it can't be stored in a thrown
  `Error` either. The throw channel structurally cannot carry the sender.
- **`next` takes `consuming NextInput`.** Calling `next` *moves the box away*. After
  `try await next(input)`, the caller no longer holds the box — so an outer `do/catch`
  around `next` can *observe* a downstream error but has no sender to answer it with. (This
  is the point RouteErrorHandling.md makes for outer middleware; it generalises to every
  non-holding frame.)

The **terminal** is the one frame that holds the sender when user logic runs — the handler
executes inside `withPendingContents { … responseSender … }`, sender in hand — which is why
`@ErrorResponse` maps there and nowhere else.

## Three throw sites, three outcomes

| Throw origin | Who holds the sender at throw-time | Outcome |
|---|---|---|
| **Handler** (inside the terminal `do`) | the terminal — WireMVC's own generated frame | mapped by `@ErrorResponse`; **WireMVC writes a 500** if unmapped (see correction) |
| **Middleware, intentional response** (auth gate → 401/403) | the middleware — it *destructured* the box to get the sender | it **writes** the response and short-circuits; no throw involved |
| **Middleware, unexpected failure** (`throw` mid-chain) | the middleware — but it *drops* the box on the throw | server **aborts the connection** — no HTTP response |

The middle row is the design's intent: a middleware expresses an *intentional* outcome by
**writing** (it holds the sender exactly when it chooses to respond — fully supported,
including streaming short-circuits and the M5.4R sender transformation). A middleware
*throw* therefore only ever signals an *unexpected* failure — a bug, an I/O fault — and the
abort is the floor for that.

## Why a middleware throw cannot become a 500 — owning the code doesn't help

WireMVC owns the *terminal* and the *composition* (the fold that invokes each middleware),
but not the *body* of a user middleware's `intercept`. A middleware throw happens inside
that body, holding the sender (in its `consuming Input` box), which it drops on the throw.
Three routes to recovering it, all closed:

- **Retain a handle — no.** The sender is move-only; WireMVC can't keep a copy while also
  putting it in the box the middleware needs to short-circuit. The only "keep a handle"
  shape is a **buffering proxy** sender that owns the real one and flushes on return — which
  buffers the whole response and forfeits streaming for that subtree (M5.2/M5.4R gone). A
  deliberate, heavy opt-in, never the default.
- **Recover it on drop — no.** When the throwing middleware drops the box, its `deinit`
  runs, but writing a response is `async` and `deinit` can't `await`. That is *precisely*
  the limitation the proposal encodes as "aborted."
- **Wrap the middleware — no.** A generated wrapper that tried to catch the inner
  middleware's throw would itself have to pass the sender *into* the inner via `next`, and
  would lose it the same way.

This is not a WireMVC shortcoming; it is the price of putting the sender *in the chain*
(Model B) so middleware can stream and short-circuit. A two-phase onion model (sender only
at the terminal) *would* let an outer frame 500 a middleware throw — but no middleware could
stream or short-circuit at all. WireMVC chose the streaming-capable model; the
middleware-throw-abort is the corner it gives up, and it gives up the right corner
(intentional responses use writing, not throwing).

## Design space & alternatives — why the linear sender

Model B is not a free choice; it is **entailed by the proposal's `Middleware.intercept<Return>`
signature** (the five-step derivation is in [WireMVCMiddleware.md](WireMVCMiddleware.md): `Return`
is universally generic → the only value of that type is what `next` returns → every middleware must
run `next` → a middleware can't produce the response *as a value* → the response is a sender
side-effect → the sender is a held, linear resource). So "the alternatives" are really "what would
you abandon proposal-nativeness *for*." The space:

| | **A** return-based | **B** linear sender *(current)* | **B′** reference sender | **C** two-phase (sender at terminal) | **D** tiered hybrid | **E** sender-handback |
|---|---|---|---|---|---|---|
| Raw-transport streaming (backpressure, trailers, 1xx, **bidirectional**) | partial¹ | ✅ | ✅ | ✗ | ✅ | ✅ |
| **Writer transformation** (M5.4R) | ✗² | ✅ | ✅ | ✗ | ✅ (stream tier) | ✅ |
| Middleware short-circuit **by streaming** | ✗³ | ✅ | ✅ | ✗ | ✅ (stream tier) | ✅ |
| Exactly-once response — **compile-time** | ✅ (one return) | ✅ (linearity) | ✗ (runtime flag+lock) | ✅ | ✅ | ✅ |
| Error-mapping **placement freedom** (outer mw) | ✅ | ✗ (terminal only) | ✅ | ✅ | partial | partial |
| Middleware **throw** → clean response | ✅ | ✗ → abort | ✅ | ✅ | ✅ (transform tier) | ✗ |
| **Proposal-native** | ✗ | ✅ | ✗ | ✗ | ~ | ~ |
| Codegen / authoring cost | low | high | med | med | **highest** | high |

¹ A streams via a *returned* body value (an `AsyncSequence`), not a held writer. ² You'd transform
the returned body, not the writer. ³ A "short-circuits" by *returning* a response — not a streamed
write from mid-chain.

**The one axis everything else shadows** is response-as-a-constructible-value (A) vs
response-as-a-held-linear-resource (B). If a response is a *value*, any frame can build one — outer
middleware map errors, a middleware throw becomes a returned response. If it's a *held writer*, only
the holder can respond — mapping nails to the terminal, a middleware throw drops the writer. And the
streaming subtlety that settles it: A *can* stream (a lazy body value), so "B for streaming" is too
glib — what A fundamentally *cannot* do is **transform the writer** (M5.4R) or **interleave read/write
at transport level** (bidirectional, trailers, 1xx). Those require holding the writer, and holding a
*linear* writer is exactly what forfeits placement-free error handling. Same coin.

Why each non-B option doesn't pay off:

- **A (return-based)** — the industry default (Vapor `ErrorMiddleware`, axum `IntoResponse`, Spring
  `@ControllerAdvice`, ASP.NET exception filters); trivial global error middleware, because their
  response is a *returned value* any outer frame can construct. But adopting it means not threading
  the proposal's sender: the body becomes an erased/boxed streaming value, writer transformation and
  transport bidirectional are gone, heap/existential returns to the hot path, and you're no longer the
  proposal's `Middleware` — a different framework built *on top of* the proposal.
- **B′ (reference/shared sender)** — keep sender-in-chain but shareable, buying back placement
  freedom. Costs the whole reason the `~Copyable` enum exists: exactly-once/first-wins becomes a
  runtime flag + lock over a shared mutable writer, and concurrency-hostile. Trades a compile-time
  guarantee for an ergonomic one.
- **C (two-phase, sender at terminal only)** — *does* make middleware throws 500-able (the writer
  isn't materialized until the terminal), but forfeits streaming short-circuit and writer
  transformation entirely: the servlet-filter model, a strict M5.2/M5.4R downgrade.
- **D (tiered hybrid)** — C-for-transform-only + B-for-streaming; recovers middleware-throw-500 for
  the non-streaming tier while keeping B where needed. But two middleware categories with a cliff
  between them and the most intricate codegen; high cost for a corner with an acceptable floor.
- **E (sender-handback via `Return`)** — keep B, return the unconsumed sender+error up the chain to a
  global handler. Buys *zero* coverage over per-route folding (the sender only ever exists at the
  terminal) and still can't help a middleware throw, for a register/router/adapter re-plumb.

**What WireMVC buys back on top of B**, bounding the loss: A's error *scoping* (route→controller→global
tiers, most-specific-wins) folded per-terminal instead of layered outer — same authoring UX, different
placement; [terminal-owns-500](#correction-wiremvc-must-synthesise-its-own-terminal-500); the synthetic
fallback route (M5_5_PLAN.md); the transform-only escape hatch (a slice of D) if a
real need appears. The one irreducible loss versus A is mapping a genuine middleware *throw* —
reserved, correctly, for unexpected failure.

**Verdict.** For a batteries-included app framework (error-ergonomics first, streaming a nice-to-have),
A is the better pick and the industry agrees. For a **proposal-native, transport-faithful layer** with
hard writer-transformation and bidirectional requirements (M5.2/M5.4R), B is correct and effectively
*forced*; its costs are bounded by the buy-backs to one well-justified corner. You'd revisit B only if
the proposal changed `intercept`'s shape (pinning `Return`) — the proposal becoming a higher-level thing.

## What the server actually does on an escaped throw

The server WireMVC-examples links is **`swift-http-server`** (the proposal ships a separate
*testing* `NIOHTTPServer` that behaves the same way but marks the path TODO). Both `handle`
and `intercept` are `async throws`; the handler consumes a `sending` sender
(`HTTPServerRequestHandler.swift:85`). When the handler throws, the real server
(`swift-http-server/Sources/NIOHTTPServer/NIOHTTPServer.swift:262`):

```swift
do {
    try await handler.handle( …, responseSender: ResponseSender(writer: outbound, writerState: writerState))
} catch {
    logger.error("Error thrown while handling request: \(error)")
    if !writerState.wrapped.withLock({ $0.finishedWriting }) {
        logger.error("Did not write response but error thrown.")   // logs only — no 500
    }
    throw error
}
// :281 — deliberate, not a TODO:
// "If the handler didn't properly conclude the response, the HTTP codec is in an
//  inconsistent state and the connection cannot be reused."
```

The re-thrown error reaches the HTTP/1.1 connection loop
(`NIOHTTPServer+HTTP1_1.swift:191`), which does `try? await channel.channel.close()`. The
`ResponseSender` is a `~Copyable` struct with **no `deinit`** — dropping it unwritten does
nothing on its own; the flag it shares (`finishedWriting`) only lets the server *log* the
miss. So on the wire an escaped throw is a **connection close / premature EOF** — not a
timeout (fast), not a 500 (no HTTP response). The proposal contract states the same at the
sender level (`HTTPResponseSender.swift:56`): *"Dropping the writer without calling `finish`
causes the response to be **aborted** when the handler scope exits."*

## Correction: WireMVC must synthesise its own terminal 500

RouteErrorHandling.md's model paragraph ends an unmapped throw with *"re-thrown out of the
middleware chain to the framework, which produces its default (500) — WireMVC never
synthesises a 500 of its own."* The investigation above shows the premise is false for the
servers WireMVC actually targets: **an escaped throw is a connection abort, not a 500.** So
the terminal's outermost tier must **write a 500**, never rethrow:

```
route @ErrorResponse → controller @ErrorResponse → global @ErrorResponse
  → built-in WireMVCBindingError → .status
  → Swift.Error catch-all, if declared
  → built-in 500 write            // was: "throw wireMVCError" (→ abort, not 500)
```

The terminal holds the sender, so writing a minimal `500` there is always safe and gives the
client a real HTTP error instead of a dropped connection. This is an **M5.5 change** (folded
in with the global error tier — see ../M5_5_PLAN.md); it supersedes the
rethrow terminus for *handler* errors. **Middleware** throws are unaffected — WireMVC never
holds their sender, so they still fall through to the server's abort floor, which is the
correct outcome for an unexpected failure.

## Accepting the asymmetry — throwing bindings vs throwing middleware

The asymmetry — a handler/binding throw is mappable, a middleware throw is not — is an **accepted
design property**, on one condition: **the server must respond appropriately** to the
middleware-throw path — a clean terminal 500, not a silent connection abort. That makes the
[`didSendHead` server fix](#feedback-for-the-proposal--server) the assumption the acceptance rests
on, not a nice-to-have: a middleware throw is *allowed* to be unmappable **because** it still yields a
definite HTTP error — just one WireMVC didn't shape. (Today's connection-abort is a temporary
shortfall against that assumption, not the intended floor.)

Given that, the asymmetry is a **feature**: the two throw channels have different capabilities, and
the difference steers each use case to the right tool.

- **"Extract-a-request-value-or-fail-with-a-status"** → a **throwing binding**, not a throwing
  middleware. A request-scoped `@Inject init` / `@Provides` that throws at scope entry is caught in
  the terminal `catch` and mapped by `@ErrorResponse` (RouteErrorHandling.md's *two throw sites*,
  site 2). This is axum's extractor-`Rejection: IntoResponse` lineage — construction-failure-as-typed-
  error — and it lands **mapped**. Missing auth principal, failed extraction, absent tenant: all belong
  here. Pushing them toward bindings also composes with DI — the failing extraction *is* a graph
  binding, so it can `@Inject` what it needs to decide.
- **Reject-with-a-response as a cross-cutting gate** → a middleware that **writes** (short-circuits to
  `.responded`, holding the sender). Intentional, holds the sender, fully supported — including a
  streamed rejection.
- **A middleware `throw`** → reserved for the genuinely unexpected (a bug, an I/O fault). Not a
  control-flow tool; its floor is the server's terminal 500.

So nothing that *wants* a mapped response is pushed onto the un-mappable channel: it's a throwing
binding (mapped) or a writing middleware (self-responds). The middleware throw stays what it should be
— the "could not serve this request" signal — and the throwing binding is the first-class home for
"well-formed-but-rejected," which is where most real rejection use cases naturally belong. The
asymmetry doesn't cost expressiveness; it *directs* it.

## The one escape hatch (deferred)

The *only* way to make a middleware's throw become a 500 is to run that middleware where
**WireMVC holds the sender across it**: hand it a sender-less box (transformed
request/context/reader only), keep the sender in WireMVC's frame, and re-attach it before
continuing inward. A throw then unwinds into WireMVC's frame, sender in hand → 500. This
works *only* for a middleware that promises never to respond/stream itself — a pure
request/response transformer — so it would need a distinct transform-only `@Middleware`
flavour. A real affordance, but it adds a second middleware category; not built
speculatively. The rule "throw ⇒ abort, write ⇒ respond" ships without it.

## The honest signature — a non-throwing `intercept`

The primary recommendation for the proposal follows from the type theory, and it is the honest one:
**`intercept` should not throw.**

Every exit from `intercept` is enforced-linear *except* the throw. The signature makes the only
obtainable `Return` the one `next` hands back, so a normal return **must** reach `next`, consuming the
box. `throws` is the one exit that bypasses that — you can leave without consuming the box — and
`~Escapable` makes the bypass **unrecoverable**: a `~Escapable` value cannot leave the frame except by
being consumed into `next`, and the throw channel requires a `Copyable & Escapable` error, so the box
can never travel out on it. A throw taken while holding an unconsumed box therefore *destroys* it,
silently, with no salvage path.

So `throws` is an **unenforced escape from the linear discipline the rest of the signature so
carefully enforces**, and `~Escapable` guarantees that escape is lossy. The exactly-once guarantee the
linearity exists to provide holds on every path but a throw-while-holding-the-box.

Making `intercept` **non-throwing** closes the hole: every exit must then consume the box, so "a
request always gets a response" becomes a **structural** property — a compiler-checked guarantee, not
a courtesy the server has to remember to implement (which, [as we saw](#what-the-server-actually-does-on-an-escaped-throw),
it currently doesn't). It also makes the signature *honest*: today `throws` is advertised as an
ordinary exit while being, for any middleware holding the sender, a trap the types don't warn about. A
middleware's fallible work would instead be handled where the sender is in hand — caught and turned
into a written response — which is the only place it could ever have produced one anyway.

The alternative — an `Escapable` box that a `~Copyable` error could carry back — drops non-escapability
(and the lifetime guarantees the streaming model leans on) to keep `throws`. Keeping *both* `throws`
and a `~Escapable` linear `Input`, as the proposal does today, is precisely the compromise that yields
abort-on-middleware-throw. Removing `throws` is the smaller, cleaner change, and the one that makes the
model say what it means.

## Feedback for the proposal / server

Surfaced by this analysis, worth filing upstream:

- **Make `intercept` non-throwing** — the primary recommendation, argued in full at
  [The honest signature](#the-honest-signature--a-non-throwing-intercept). It turns "a request
  always gets a response" from a runtime courtesy the server must remember to implement into a
  compile-time property. The narrower alternative — keep `throws` but **mandate** a terminal server
  response on escape — is strictly weaker (a runtime promise vs a structural guarantee). The proposal
  currently specifies neither, leaving the path as "abort."
- **`swift-http-server`'s abort is coarser than it needs to be.** Its "codec is
  inconsistent → close" reasoning only holds once a **response head has been sent**; when the
  handler threw *before writing anything*, the codec is clean and a `500` is safe. But
  `finishedWriting` is `false` for *both* "wrote nothing" and "sent head, didn't finish," so
  the server can't distinguish them. Concrete, well-scoped fix: track a `didSendHead` bit in
  `WriterState`; in the catch, `!didSendHead ⇒ write a 500 and close cleanly`, else keep the
  current close. The server already retains `outbound`, so it has everything it needs. This is
  **the assumption the accepted middleware-throw asymmetry rests on**
  ([Accepting the asymmetry](#accepting-the-asymmetry--throwing-bindings-vs-throwing-middleware)):
  a middleware throw is only *allowed* to be unmappable because it still yields a definite HTTP
  error. Until it lands, that path is a connection abort — a temporary shortfall against the
  design, not the intended floor. (WireMVC owns the terminal 500 for *handler* errors regardless,
  since it holds the sender there.)

## Prior art (grounding)

The model-by-model framework mapping is in
[Design space & alternatives](#design-space--alternatives--why-the-linear-sender); two groundings
worth keeping separate:

- The middleware-throw-abort is not exotic: it is the same shape as **`hyper` dropping a connection**
  when a service future errors without producing a `Response`. Sender/stream-based stacks land here.
- The takeaway `@ErrorResponse` embodies: adopt the return-based stacks' **scoping tiers**
  (route/controller/global, most-specific-wins) but keep **placement at the sender-holder** — because
  "a middleware that throws" is categorically not a "map-to-response" event but a "could not serve this
  request" one.

---

<sub>Milestone shorthand used in this note (M1, M5.4, M7b…) is defined in ROADMAP.md; outstanding gaps are indexed in KnownGaps.md.</sub>
