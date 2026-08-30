# Streaming response tier — a design note

> **Status:** **shipped** (2026-08-09). The tier is `WireMVC/StreamingResponses.swift`; `@HTMLResponse`
> emits it, and `WireMVCElementary` supplies the producer. Streaming is `@HTMLResponse`'s contract from the
> outset — there is no buffered HTML mode and never was one in the shipped surface.
>
> Pinned at three levels: `Tests/WireMVCCodegenTests/HTMLResponseGenerationTests` (9, the emitted terminal
> and its diagnostics), `Fixtures/Tests/StreamingTierTests` (13, the runtime over a recording writer, both
> synthetic bodies and real Elementary HTML), and `Fixtures/Tests/.../HTMLResponseOverTheWireTests` (7, a
> live `NIOHTTPServer`).
>
> Still to come: migrating the SSE and multipart routes off `@RawRoute` onto this tier, which was the
> original motivation and is the larger part of the payoff.
>
> The assumptions the design rests on were checked against the 6.4 snapshot toolchain
> (`6.4.x-snapshot-2026-07-06`) rather than assumed; see *What was verified*.
>
> **This note records two corrected analyses**, both of which changed the design.
>
> 1. The first pass argued for an existential body producer on the grounds that a generic
>    `WireMVCOutcome<Writer>` would infect "the fold, the registry, and the error mapping." Two of those
>    three are false — the fold already carries the sender type, and the registry never names the outcome.
>    The cost is concentrated in one place, and the fix is to *split* the success and error types rather
>    than to erase either of them.
> 2. The second pass claimed the resulting terminal needed a hand-enforced soundness rule, on the strength
>    of a `-typecheck` run that could not have seen the problem (the move-only checker is a SIL pass).
>    Compiled properly, the unsound shape is rejected by the ownership checker and the rule is not the
>    design's to enforce — but the terminal shape had to change to one that compiles.
> 3. The producer protocol carried `: Sendable`, held over from Option B where the producer had to sit inside
>    a `Sendable` outcome. Under Option C it is not merely unnecessary but actively harmful — it is the sole
>    reason a non-`Sendable` body would need an erasure box. Dropped.
> 4. The producer took the writer `inout`. Building the Elementary integration showed that cannot work, nor
>    can consume-and-return across a protocol witness; the producer has to terminate the response itself.
>    The same build surfaced the isolation requirement — see upstream ask 2, which the design had missed
>    entirely and without which ask 1 is dead code.
>
> The pattern across all four is the same: every one was a constraint asserted from reasoning and refuted by
> a compiler. None survived contact with a build.

## Why it exists

WireMVC has exactly two response tiers, and nothing between them.

- **`WireMVCOutcome`** (`WireMVC/Responses.swift:21`) — status, header fields, and an already-encoded
  `body: [UInt8]?`, computed *before* the sender is touched. `Sendable`, so a handler can capture it. It
  participates in the middleware header fold, in `@ResponseHeader` contributions, in `@ErrorResponse`
  mapping, and in the generated typed client.
- **`@RawRoute`** — the handler is handed the sender verbatim. No fold, no header contributions (see
  `WireMVCDiagnostic.responseHeaderOnRawRoute`), no error mapping, no typed client beyond the path shim
  `ControllerClientGeneration` emits.

A route that produces its body *incrementally* has to take the second tier, which means paying for the
whole escape hatch to get one property. That is not hypothetical: in `wire-mvc-examples`, both
`GET /todos/stream` (server-sent events) and `GET /export` (`multipart/mixed`, through a sender-transforming
middleware) are `@RawRoute` for exactly this reason. Neither wanted the sender; both wanted incremental
bytes. Streaming HTML would be the third route to pay the same price.

So the gap is not an HTML gap. It is a missing **third tier**: a typed route whose status and header fields
resolve normally, whose body is produced incrementally, and which keeps everything the typed tier provides
up to the point where the head goes out.

## The primitive: pass the writer, do not store it

The reason incremental bodies look blocked is an ownership mismatch, and it is worth stating precisely
because it is easy to conclude the wrong thing from it.

The proposal's response writer is non-copyable *and* non-escapable
(`HTTPAPIs/Server/HTTPResponseSender.swift`):

```swift
public protocol HTTPResponseSender<Writer>: ~Copyable, ~Escapable {
    associatedtype Writer: CallerAsyncWriter, ~Copyable, ~Escapable
        where Writer.WriteElement == UInt8, Writer.FinalElement == HTTPFields?
    @_lifetime(copy self)
    consuming func send(_ response: HTTPResponse) async throws -> Writer
}
```

Any design that wants to **store** that writer in an ordinary struct fails — which is exactly why
Elementary's `HTMLStreamWriter` cannot be conformed over it (`AsyncHTMLRenderer` holds `var writer: Writer`),
and why the naive reading is "streaming is impossible here."

It isn't. Nothing requires storage — the writer composes freely as a *generic parameter*, the one position
where a `~Escapable` type is unconstrained. The distinction between **holding** the writer and **being
handed** it is the whole design.

Getting the exact parameter convention right took three attempts, and the two that failed are worth
recording because each looks obviously correct until it is compiled.

**`inout W` — fails.** A producer cannot pass an `inout` writer on to anything that needs ownership (an
Elementary render adapter, say): consuming out of an `inout` demands reinitialisation on every exit path,
including the throwing one, which is impossible when the consuming call is what throws.

**`consuming W -> W` (consume-and-return) — fails at the protocol boundary.** It compiles for a producer
that returns *the same* writer it was handed, and it is exactly the shape Elementary's `render(intoOwned:)`
uses. But a producer that routes the writer through an intermediary and returns what comes back gets
`lifetime-dependent value escapes its scope` on the **protocol witness thunk**: the checker cannot trace
`writer → adapter → returned writer` back to the argument across a conformance. Annotating the requirement
`@_lifetime(copy writer)` does not rescue it.

**What works: the producer terminates the response.**

```swift
public protocol WireMVCBodyProducer {
    consuming func writeBody<W: CallerAsyncWriter & ~Copyable & ~Escapable>(
        into writer: consuming W,
        terminatedBy trailer: HTTPFields?
    ) async throws where W.WriteElement == UInt8, W.FinalElement == HTTPFields?
}
```

Every lifetime-dependent value now stays inside a single function body, so the tier needs **no `@_lifetime`
annotation anywhere**. The producer is an escapable *description* of what to write; only the call touches the
non-escapable writer.

The cost is a real obligation: a producer that forgets to `finish` leaves the response unterminated, which
per the proposal aborts it. That is the same observable outcome as a mid-body throw, so the failure mode is
at least consistent — but it is an obligation the type system does not enforce, and the parameter name is
doing the work of stating it.

**No `Sendable` requirement**, deliberately — see *Sendable: the constraint that should not exist*.

## Where the outcome type goes

Three options were considered. The interesting part is why the obvious two lose.

### Option A — one generic outcome, `WireMVCOutcome<W>`

The claim that this is invasive is mostly wrong, and the part that is right is sharper than "invasive."

- **The middleware fold absorbs it for free.** `RequestResponseMiddlewareBox` (`WireMVC/Middleware.swift:21`)
  is *already* generic over `ResponseSender`, with `ResponseSender.Writer: ~Copyable` in its `where` clause.
  It can name `ResponseSender.Writer` today. `respondingWith` (`Middleware.swift:137`) taking
  `WireMVCOutcome<ResponseSender.Writer>` adds no type parameter to anything.
- **The registry is untouched.** `ResponseHeaderRegistry` never mentions `WireMVCOutcome`; it collects
  `ResponseHeaderContribution`s and `drain()` returns a plain array.
- **The error mapping is where it lands**, and the reason is one line of generated code. The terminal
  (`WireMVCCodegen/RouteCodegen.swift:496`) declares a single variable and assigns it from both paths:

  ```swift
  let wireMVCOutcome: WireMVCOutcome
  do {
      … wireMVCOutcome = <success computation>
  } catch let wireMVCError {
      wireMVCOutcome = <error mapping chain>
  }
  try await wireMVCOutcome.send(on: responseSender)
  ```

  Success and error share a variable, so they share a type. Make it generic and the parameter propagates
  through `wireMVCRespond` (`WireMVC/ErrorResponse.swift:12`) into the mappings *users write*:

  ```swift
  static func mapNotFound<W>(_ e: TodoNotFound) -> WireMVCOutcome<W>   // W is unusable in the body
  ```

Note where the tax lands: on declarations with a **written** return type. An inline gate expression
(`.status(.unauthorized, headerFields: …)`) infers `W` from context and costs nothing. `@ErrorResponse`
mappings are the one place WireMVC asks for a written signature, so they are the one place the parameter
becomes visible — and every controller would pay it for a capability only streaming success paths use.

### Option B — an existential arm on the outcome

Add `producer: (any WireMVCBodyProducer)?` to the existing struct and give `send(on:)` a third path. This
works, and it keeps `WireMVCOutcome` non-generic and `Sendable`.

It is rejected not because the per-response existential is expensive — it isn't — but because it buys
nothing that Option C doesn't buy more cheaply. It erases a type to solve a problem created by unifying two
paths that were never the same path.

### Option C — split the types (recommended)

**The error path can never stream.** Once the head is on the wire, an error cannot become a `404`; the most
it can do is truncate the body. So the success and error outcomes genuinely have different capabilities, and
forcing them through one `let` is what manufactures the constraint.

The terminal therefore discriminates in the `do`/`catch` and consumes the sender **once, outside** it —
preserving the single-consume-site invariant the buffered terminal already maintains
(`RouteCodegen.swift:496-502`), rather than departing from it:

```swift
let wireMVCResult: WireMVCTerminalOutcome<Producer>
do {
    wireMVCResult = .stream(try await controller.page())
} catch let wireMVCError {
    wireMVCResult = .buffered(<error chain>)                 // buffered, non-generic, unchanged
}
switch consume wireMVCResult {
case .stream(let producer):
    try await WireMVCStreamingOutcome(status: …, headerFields: …, producer: producer)
        .send(on: responseSender)                            // generic over a concrete producer, inferred
case .buffered(let outcome):
    try await outcome.send(on: responseSender)
}
```

`WireMVCTerminalOutcome<P>` is generic over the producer type only, inferred at its single construction
site, and appears in no user-written signature — the property the existential was reaching for, without the
erasure.

What this costs: a second outcome type, a terminal-local discriminant, and a second terminal shape in
`RouteCodegen`.

What it does not cost: no existential, no user-facing generic parameter, and no change whatsoever to
`respondingWith`, to `ResponseHeaderRegistry`, to `wireMVCRespond`, or to any `@ErrorResponse` mapping
anyone has already written. The buffered tier is left exactly as it is, which is the right outcome for a
tier that most routes will keep using.

## Soundness: the ownership checker already enforces it

The obvious hazard is that a streaming send takes the sender and *then* throws, leaving the `catch` reaching
for a value that is gone. It needs no new machinery: **the shape that would be unsound does not compile.**

Compiled for real (see *What was verified* — this is a SIL-level check, invisible to `-typecheck`):

| Shape | Result |
| --- | --- |
| Consume in `do` via a **throwing** call, use sender in `catch` | `error: 'sender' consumed more than once` |
| Consume in `do` via a **non-throwing** call, use sender in `catch` | compiles — and is sound |
| Discriminate in `do`/`catch`, one consume site outside, throwing send | compiles |

The middle row is sound for a real reason: if the consume cannot throw, the `catch` is reachable only from
*before* it, so the sender is provably live there. That is the "make the streaming send non-throwing" design,
and it works — at the cost of forcing the send to swallow mid-body errors internally.

The third row is the one this note recommends, and it is better on every axis: the send keeps `throws`, so a
mid-body failure propagates to the framework exactly as a buffered send failure does today; no internal error
channel has to be invented; and it preserves the invariant `RouteCodegen` already maintains. `RouteCodegen`
navigates a version of this hazard already — the keyed-harness preamble sits before the `do` specifically so
its explicit `500` "escapes the closure directly rather than re-consuming the `consuming` sender through the
`catch`" (`RouteCodegen.swift:492`).

**What a mid-body error does under the recommended shape.** It propagates, and the writer is dropped without
`finish` — which per the proposal's own semantics aborts the response when the handler scope exits. That is
the honest wire signal for a truncated body, and the error still reaches the server's error handling. Better
than swallowing it, and better than pretending it can become a status code.

A related consequence to document rather than discover: `@ErrorResponse` on a streaming route covers binding
failures, scope-entry throws, and the handler itself — everything before the first byte — and nothing after.
A streaming route declaring a mapping for an error its *body* throws is stating something the mechanism
cannot honour, and is a candidate diagnostic. This is a usability warning, not a soundness guard; soundness
is the checker's.

## Sendable: the constraint that should not exist

The obvious move is to require `WireMVCBodyProducer: Sendable` and inherit the ecosystem's handling of
non-`Sendable` HTML — Elementary's `SendableAnyHTMLBox` / `SendOnceBox`, and
`HummingbirdElementary.HTMLResponse`'s once-only `tryTake()` with an `assertionFailure` and a 500 on second
use. **Do not.** That requirement is not a safeguard here; it is the thing that would manufacture the problem
the boxes exist to solve.

**Why hummingbird-elementary needs the box, and WireMVC does not.** Hummingbird's `ResponseBody` is an
escapable `@Sendable` closure the framework may invoke at its discretion, so the body can in principle be
written more than once; `tryTake()` guards *replay*. WireMVC has no replay hazard: the response sender is
`consuming` and one-shot by the proposal's contract ("exactly one non-informational response per request"),
and `WireMVCOutcome`'s own documentation already records that the terminal "calls `send(on:)` exactly once,
so the `consuming` sender is consumed on a single path." Linearity does the box's job.

Under Option C the producer is never stored in the `Sendable` `WireMVCOutcome` either — it lives in the
terminal-local `WireMVCStreamingOutcome<P>`, constructed and consumed in a single statement, never escaping
its region. Verified: a producer holding a non-`Sendable` class, threaded through a shape mirroring
`withPendingContents`' `nonisolated(nonsending)` closure, compiles clean under `-strict-concurrency=complete`.
Adding `: Sendable` to the protocol immediately rejects it (`stored property … of 'Sendable'-conforming
struct … has non-Sendable type`), which is exactly the pressure that forces an erasure box.

This is a second, independent axis on which Option C beats Option B: not merely no existential, but no
`Sendable` tax and no runtime-checked box. Option B, holding the producer in the `Sendable` `WireMVCOutcome`,
would have required it.

**The one real constraint is Swift's, not WireMVC's.** An `actor` controller returning a non-`Sendable` body
is rejected by region isolation — `non-Sendable '…'-typed result can not be returned from actor-isolated
instance method … to nonisolated context`. The fix is `-> sending some HTML` on the controller's own method,
where the author knows whether the value is genuinely fresh. Struct and class controllers, the common case,
are unaffected. WireMVC neither imposes this nor can relax it, and should not try to paper over it.

## One smaller consequence

**Trailers are the replacement for post-hoc header contribution.** A middleware that wants to contribute a
field computed *from* the body can do that in the buffered tier (the body is in hand when the fold drains).
Streaming forecloses it — except the proposal already models the answer: `Writer.FinalElement == HTTPFields?`.
`WireMVCOutcome.send` (`Responses.swift:92`) passes no trailer today. The streaming tier is the natural first
consumer of that channel, and the natural place for the fold to have somewhere to go.

## Upstream dependencies (Elementary), and what they are not

For HTML specifically, three upstream changes are wanted. Only the third is optional; **the first two are
jointly necessary**, and discovering that is the main thing building the integration bought — the
`~Escapable` relaxation alone compiles and is still unusable for the case it exists for.

None of them blocks the *tier* — a producer can buffer internally, or bridge through a channel, in the
meantime — but streaming HTML needs 1 and 2 together:

1. **Relax `HTMLStreamWriter` and `_AsyncHTMLRendering` to `~Copyable, ~Escapable`.** Implemented and
   passing (125 tests: their 121 unchanged, plus 4 that stream into a genuinely non-escapable writer) —
   [tachyonics/elementary@07eb694](https://github.com/tachyonics/elementary/commit/07eb69492ddf7052616af47518e7f883bd8f2691),
   which `Fixtures` pins by revision.

   The mechanical part is 26 async `_render` implementations gaining `& ~Copyable & ~Escapable` on their
   `Renderer` constraint; every body is pure forwarding, so none of them change.

   **The non-mechanical part is not "borrow instead of store"** — an earlier draft of this note said that,
   and it is wrong twice over. A struct cannot hold a mutable borrow of an arbitrary non-copyable type in
   Swift 6.4 (`missing reinitialization of inout parameter after consume`), and storing was never the
   problem. Two orthogonal properties are in play:

   - `~Copyable` is about **ownership**: storing a non-copyable value forces the container non-copyable.
     The renderer genuinely owns the writer — a move, not a borrow.
   - `~Escapable` is about **lifetime**, and *moving a non-escapable value does not extend its lifetime*.
     So the container inherits the bound and must be non-escapable too, even though it owns the value.
     Verified: `~Copyable` alone gives `stored property 'writer' of 'Escapable'-conforming generic struct
     … has non-Escapable type 'Writer'`.

   Being non-escapable then requires saying *what* bounds it; the compiler refuses to infer between
   `@_lifetime(borrow writer)` and `@_lifetime(copy writer)`. Moving the writer in means `copy` — the
   renderer inherits the writer's own bound. (`copy` there names copying the *lifetime dependency*, not the
   value, which reads as a contradiction on a `consuming` parameter of a non-copyable type.)

   The resulting API is **consume-and-return**: `render(intoOwned:) -> Writer` alongside the existing
   `render(into:) -> Void`, which stays as a one-line forward so `hummingbird-elementary` and
   `vapor-elementary` compile untouched. A happy accident falls out — on a thrown error the writer is not
   returned, so it is dropped, which for a body writer aborts the response. The ownership model produces
   the truncation semantics this note argues for, for free.

   Verified against both adapters: each builds unmodified and warning-free against the fork. Each has one
   failing test, and the identical failure reproduces against Elementary's unmodified `main` — the released
   adapters' expectations predate `HTMLDocument` emitting a charset meta. Upstream drift, unrelated.

2. **Make async rendering inherit the caller's isolation** —
   `.enableUpcomingFeature("NonisolatedNonsendingByDefault")`, or `nonisolated(nonsending)` on the render
   entry points.

   Without this the relaxation in 1 is useless. Elementary's `render` is `@concurrent` by default, so it
   hops to the generic executor, and its arguments must therefore be `sending`:

   ```
   error: sending value of non-Sendable type 'ProposalHTMLStreamWriter<W>' risks causing data races
   note: sending … to @concurrent instance method 'render(intoOwned:chunkSize:)' risks causing races
   ```

   A lifetime-bound writer can *never* be `sending` — being non-escapable is precisely a statement that it
   cannot leave its region. So an executor hop makes streaming into one impossible no matter how the
   ownership is arranged. This is not a nicety about performance; it is the difference between the feature
   existing and not.

   It is also the right semantics on its own terms: there is no reason rendering should hop executors, and
   inheriting the caller's isolation is what lets a server render on the thread already handling the
   request. All 125 fork tests pass with it enabled.

   Two things complicate the upstream PR: it needs tools-version 6.4, the `LifetimeDependence`/`Lifetimes`
   features, and a macOS floor bump (Elementary currently supports iOS 15 with zero dependencies, so this
   likely has to be trait-gated rather than unconditional); and it adds three uses of the underscored
   `@_lifetime`.
3. **Flush control.** Chunking is purely size-driven (`buffer.count >= chunkSize`) and `flush()` is internal,
   so a shell intended to reach the browser immediately may simply sit in the buffer. Without this, streaming
   HTML cannot do the one thing streaming HTML is for.

1 and 2 should be one PR — separately, the first is dead code. `WireMVCBodyProducer` and
`ElementaryProducer` in `Fixtures/StreamingBodyProducers` are the working use case to point at.

The manifest cost on Elementary's side is small: tools-version 6.1 → 6.4, plus
`.enableExperimentalFeature("Lifetimes")` and `.enableUpcomingFeature("NonisolatedNonsendingByDefault")`.
The platform floor is **unchanged** (macOS 14 / iOS 15) — `~Escapable` and `@_lifetime` are compile-time
features with no deployment-target cost. Note that `@_lifetime` is the correct spelling today: the
non-underscored `@lifetime` parses but warns `Unsupported use of @lifetime, use @_lifetime`, and the gating
flag is `Lifetimes`, not `LifetimeDependence`.

## What falls out

Once the tier exists, `GET /todos/stream` and `GET /export` should migrate onto it and recover their typed
clients, their `@ResponseHeader` contributions, and their pre-head error mapping. `@RawRoute` then shrinks to
what it should always have been: the hatch for routes that genuinely need the whole sender — protocol
switching, hijacking, informational responses — rather than the catch-all for "produces bytes incrementally."

That is also the stronger internal argument for the work. "Streaming HTML needs a new response tier" is a
weak case. "Two shipped example routes pay full `@RawRoute` cost for something that should be typed, and HTML
would be the third" is not.

**Still outstanding.** `@HTMLResponse` shipped; the migration did not. `GET /todos/stream` and `GET /export`
in `wire-mvc-examples` are still `@RawRoute`, and they were the original motivation. Until they move, the
tier has one client and the argument above is a promise rather than a result.

## What `@HTMLResponse` emits

The generated terminal for `func home() async throws -> some HTML`:

```swift
try await wireMVCStreamingTerminal(
responseSender: responseSender,
responseHeaders: wireMVCResponseHeaderDrain,
building: {
return WireMVCStreamingOutcome(
status: .ok,
headerFields: WireMVCResponseHeaders.resolved(statics: [.setIfAbsent(.contentType, "text/html; charset=utf-8")]),
producer: WireMVCHTMLProducer(try await self._wireSubject.home())
)
},
errorMapping: { wireMVCError in … }
)
```

The registry is **handed to the terminal** rather than drained in the `building` closure. That is not a
formatting choice: a route needs the contributions on the mapped path too, and draining at both sites ran a
deferred contribution twice — while a noncopyable value captured by a closure cannot be consumed at all, so
`building` could not hold the drain even once. wire-mvc's
[`LinearResponseHeaderRegistry.md`](LinearResponseHeaderRegistry.md) carries the account, under *The sequel*.

Four decisions in that, three of which the build forced.

**The producer type is never spelled.** `Producer` is inferred from `building`'s return type. Nothing else
would work: the handler returns an opaque `some HTML`, which the generated code cannot name.

**`return` is not optional.** Swift infers a closure's result type from a bare trailing expression only when
it is the *sole* statement, so the moment a route has a `@Path` binding — or a scope prologue, or a body
collection — `Producer` becomes uninferrable. The codegen emits `return` in both cases rather than tracking
which shape it is in. This compiled for the no-binding route and failed for the next one along, which is
precisely the class of bug only a fixture catches.

**Content-Type goes through the existing header machinery**, seeded as a `.setIfAbsent` static placed first.
A route's own `@ResponseHeader(.contentType, …)` — a `.set`, applied later — still wins by the ordinary tier
rule, and a handler-returned field wins over that. No second place content types come from. Charset is
included, unlike `WireMVCOutcome.json`'s bare `application/json`: a browser sniffs an HTML body without it.

**Everything that can fail before the head sits inside `building`** — scope entry, body collection, parameter
binding, the handler call, the header drain — so all of it maps through the same `@ErrorResponse` chain a
`@JSONResponse` route uses. That is not a nicety: it is what makes the streaming tier's error handling equal
to the buffered tier's *up to the first byte*, which is as far as any streaming design can go.

## How it is pinned

The tier is exercised at two levels below the codegen, in `Fixtures`. Package settings mirror
`wire-mvc-examples/Controllers` exactly (`strictMemorySafety`, `LifetimeDependence`,
`Lifetimes`, `NonisolatedNonsendingByDefault`, …) so the ownership surface is identical to the real thing.

**Layer 1 — the tier alone**, with a `ChunkProducer` standing in for a rendered body and no Elementary
dependency, so the design is validated independently of whether Elementary can be adapted at all. It also
composes with the **real** `WireMVCOutcome`, since "the buffered tier is untouched" is a claim under test.

Seven tests, covering every claim this note makes:

| Claim | How it is pinned |
| --- | --- |
| The body is written incrementally | Four chunks arrive as **four separate writes** after the head, not one |
| Streaming is real, not buffering-then-flushing | A gated producer proves the head and first chunk are observable **while the producer is still suspended**; the response is still open |
| Pre-head errors map normally | A handler throw yields exactly `head(404)` + `finished` — nothing streamed |
| Post-head errors truncate honestly | A mid-body throw propagates, the already-written chunks stand, and the writer is dropped without `finish` — the peer records **`aborted`**, not a well-formed short response |
| Trailers carry post-head metadata | Trailing fields arrive with the end of body |
| The buffered tier is untouched | `BufferedOutcome` still sends head+body in one `sendAndFinish` |
| Non-`Sendable` bodies need no box | A producer holding a non-`Sendable` class streams normally |

Two **negative** checks matter as much as the passing ones, and were run by temporarily reintroducing each
mistake into the real package:

- Sending inside the `do` (the shape the first draft of this note proposed) fails to build:
  `error: 'responseSender' consumed more than once`.
- Adding `: Sendable` back to `WireMVCBodyProducer` fails to build: `stored property 'model' of
  'Sendable'-conforming struct 'NonSendableProducer' has non-Sendable type 'NonSendableModel'`.

Both were reverted and the suite confirmed green again.

**Layer 2 — real Elementary HTML**, via `ElementaryProducer` and a `ProposalHTMLStreamWriter` adapter, against
the Elementary fork (`tachyonics/elementary`, pinned to `07eb694`). Six further tests:

| Claim | How it is pinned |
| --- | --- |
| Fragments and full documents render | Doctype, `<title>`, and per-item `<li id=…>` all present |
| **A large page is chunked, not buffered** | A 200-item page arrives in >10 separate writes, and reassembling them equals `TodosPage(...).render()` byte for byte |
| **The head is out while the page still renders** | A gated `AsyncContent` tail: bytes reach the peer before it resolves, and the response is still open. A buffering implementation *deadlocks* this rather than failing it |
| `AsyncForEach` streams as it resolves | Multiple writes, correct concatenation |
| Trailers survive the Elementary path | Delivered after the rendered body |

Against upstream Elementary this layer does not compile at all — which is the point of it.

**Layer 3 — over real HTTP**, in `HTMLResponseOverTheWireTests`: four `@HTMLResponse` routes on the
fixtures' `NIOHTTPServer`, seven tests. The seeded content type, an annotated `404` alongside a route
constant, a binding failure mapping to `400` *before* the head, an `@ErrorResponse` handler throw doing the
same, and the global middleware tier contributing to a streamed head.

Its limit is worth stating, because the obvious assertion does not hold. A collecting client cannot see
individual writes, so "streamed" is only inferable from the response head — and this stack reports
`Transfer-Encoding: Identity`, not `chunked`. What is observable is the **absence of `Content-Length`** on a
~28 KB body: a buffered response knows its size, a streamed one does not. That is the regression signal at
this level. The byte-exact evidence — many separate writes, the head observable while the body is still
rendering — needs the recording writer in layer 1, and only exists there.

## What was verified

All checks ran under the `6.4.x-snapshot-2026-07-06` toolchain via `swiftly run`, with a deliberate error
introduced first to confirm the harness reports failures — `swiftly` exits `0` while printing a
toolchain-selection failure, so an empty output and a `0` exit are not on their own evidence that anything
was compiled.

**Methodology note, learned the hard way.** `-typecheck` is *not* sufficient for any ownership claim: the
move-only checker is a SIL pass, so `swiftc -typecheck` happily accepts a straight-line
consume-then-use of a `~Copyable` value. An earlier draft of this note "verified" its consuming claims that
way and drew the wrong conclusion from the silence. Ownership questions must be compiled (`swiftc -c`); only
pure type-system questions may use `-typecheck`.

Type-system claims (`-typecheck` is legitimate here):

1. **The producer protocol survives existential use.** A `Sendable` protocol with a
   `~Copyable & ~Escapable` generic method parameter, held as `any BodyProducer` in a struct, and called
   with `&writer`. Checked for Option B; it also establishes that the protocol shape itself is sound, which
   Option C relies on.
2. **Structural opaque result types work in the response-tuple position** — so
   `-> (status: HTTPResponse.Status, headers: HTTPFields, body: some HTML)` is expressible and both tiers can
   offer the same return shapes the JSON tier does. (Relevant to `@HTMLResponse` as much as to this note.)

Ownership claims (compiled with `-c`):

3. **The unsound terminal shape is rejected.** A throwing consume inside the `do` with a `catch` that uses
   the sender gives `error: 'sender' consumed more than once`. The soundness requirement is the checker's,
   not the design's.
4. **A non-throwing consume inside the `do` is accepted**, correctly — the `catch` is reachable only from
   before it.
5. **The recommended hoisted shape is accepted**: discriminate into a `~Copyable` enum inside the
   `do`/`catch`, then consume the sender in mutually exclusive `switch` arms outside it, with the send still
   `throws`.

Concurrency claims (compiled with `-c -strict-concurrency=complete`):

6. **A non-`Sendable` producer needs no box.** A producer with a non-`Sendable` stored class, constructed and
   consumed inside a `nonisolated(nonsending)` closure mirroring `withPendingContents`, compiles with no
   diagnostic.
7. **`: Sendable` on the protocol is what breaks it** — `stored property 'model' of 'Sendable'-conforming
   struct 'Producer' has non-Sendable type`. The requirement creates the problem rather than guarding
   against one.
8. **An actor-isolated controller returning a non-`Sendable` body is rejected** by region isolation, and
   `-> sending` on the controller method fixes it. Swift's rule, at the right declaration.

Integration claims (against `tachyonics/elementary` @ `07eb694`):

9. **`inout W` and consume-and-return both fail** for a producer that routes the writer through an
   adapter — the second with `lifetime-dependent value escapes its scope` on the protocol witness thunk.
   The producer-terminates shape is what compiles.
10. **`@concurrent` rendering blocks streaming outright**, independently of ownership: a non-escapable
    writer can never be `sending`. `NonisolatedNonsendingByDefault` on Elementary resolves it.
11. **Both Elementary adapters build unmodified** against the fork, warning-free — and their one failing
    test each reproduces identically against Elementary's unmodified `main`, so it is upstream drift and
    not caused by the change.
