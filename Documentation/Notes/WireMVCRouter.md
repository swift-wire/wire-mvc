# WireMVCRouter — the native-path router (ported trie + hardening backlog)

> **Status:** shipped — a faithful port of `wire-mvc-examples`' `TrieRouteBuilder`/`FrozenTrieRouter`,
> refactored around a testable non-generic core. The batteries-included router for the WireMVC-native
> (proposal-server) path, so a `@WireMVCBootstrap` composition root's `createRoutableBuilder(for:)` has
> an obvious thing to return. Opt-in target (`WireMVCRouter`) — the WireMVC core stays router-agnostic
> (it registers onto *any* `RoutableHTTPServerBuilder`), and the `ServerTransport` adapter path uses
> the host framework's router.

## Why it exists

`@WireMVCBootstrap` asks the app for `createRoutableBuilder(for:)`, but the proposal ships no router
(it provides the server + the handler protocol; routing is the framework's job). Without a provided
router, every native-path app would hand-roll or copy one — every example did. `WireMVCRouter` fills
that gap with the trie router already developed in `wire-mvc-examples`.

## The build → freeze → serve lifecycle

The router is a `ServableRoutableHTTPServerBuilder` — the native-path refinement of the core builder
(defined in `WireMVC/Routing.swift`). Registration and serving are **different types**:

- **`TrieRouteBuilder`** (mutable) — the builder `WireMVC.apply` registers routes onto. `finalize()`
  compacts it into the immutable handler.
- **`FrozenTrieRouter`** (immutable) — *is* the proposal's `HTTPServerRequestHandler`; the server serves
  this. Its literal children are segment-sorted arrays (binary search, no per-request hashing).

The generated `@main` (and `WireMVCExample`'s hand-written assembly) do
`apply(&builder) → builder.finalize() → serve(handler:)`. The `finalize()` step is **not** on the
router-agnostic core `RoutableHTTPServerBuilder` — it's on the `ServableRoutableHTTPServerBuilder`
refinement — because the `ServerTransport` adapter's `ServerTransportRouteBuilder`
(`WireMVCServerTransport.swift:207`) also conforms to the core protocol but doesn't serve via
`HTTPServerRequestHandler`; forcing `finalize() -> some HTTPServerRequestHandler` on it would be a
meaningless conformance.

## Design

- **`RouteTrie` → `FrozenRouteTrie`** (non-generic, internal) — the trie algorithm, factored out so it
  is testable without the proposal's `~Copyable` request/response machinery. `RouteTrie.insert` walks a
  flat node array (literal children in a dictionary, one parameter edge per node) and returns a route
  index; `freeze()` sorts literal children for binary search; `FrozenRouteTrie.resolve` returns the
  matched route index + bound `{name}` parameters. Covered by `WireMVCRouterTests` (11 tests).
- **`TrieRouteBuilder` / `FrozenTrieRouter`** (public, generic over the server's associated types) —
  wrap the trie with the parallel handler array; `register` inserts + appends, `finalize` freezes +
  pairs, `handle` resolves + dispatches (or answers `404`).

## What ships (what the tests pin)

Segment-trie matching (`O(path length)`), `{name}` path parameters, query stripping, segment-exact
matching, **literal-before-parameter precedence** (`/users/me` beats `/users/{id}`),
first-registered-wins per node for the method match, and binary-searched literal children after freeze.
Empty path segments are omitted, so `/users/` ≡ `/users` (no trailing-slash policy yet).

## Production hardening backlog

The trie port already covered what were items #1 (radix matching) and part of #3 (literal-before-param).
**Everything below has since shipped except `.redirect` in item 4**, which is deferred with a reason and
tracked as [#182](https://github.com/tachyonics/wire-mvc/issues/182). Kept as a record of what was decided
and why; each item was additive and testable through `RouteTrie`/`FrozenRouteTrie` first.

1. ~~**405 vs 404.**~~ **Shipped.** `resolve` returns a three-way `RouteResolution` — `.matched`,
   `.methodNotAllowed(allowed:)`, `.notFound` — and `FrozenTrieRouter` answers `405` with a deduplicated,
   sorted `Allow`. A node reached but carrying *no* routes stays a 404: it is an interior waypoint
   (`/users` when only `/users/{id}` is registered) and names no resource, so claiming otherwise would be
   worse than the collapse it replaced. The allowed set is the reached node's, which the greedy
   no-backtracking walk makes exact rather than approximate — a backtracking matcher would have to union
   across abandoned candidates. The head itself is written by a **synthesised**
   `registerMethodNotAllowed` handler, the 405 sibling of the synthesised 404: only generated code has a
   `ResponseHeaderCarrying` context, so only it can drain the registry — a router-written head would have
   dropped every global `@Middleware` contribution on the one response an app never declares.

   **This makes the native path stricter than the bridged runtimes, deliberately.** Neither Hummingbird nor
   Vapor answers 405: both route a method mismatch to their not-found responder, so the same app serves
   `405 + Allow` on the proposal runtime and `404` on the other two. Measured, not assumed — pinned by
   `MethodMismatchTests` in each of `HummingbirdExample` and `VaporExample`.

   The two get there differently, which is worth knowing before anyone proposes closing the gap.
   Hummingbird *has* the information and declines to use it: `RouterResponder.respond` resolves the path,
   then looks the method up on the resulting responder chain — which knows its methods — and sends both
   failures to `notFoundResponder`. Vapor cannot tell the cases apart at all: the method is the first path
   component of the lookup (`router.route(path: [method.rawValue] + pathComponents, …)`), so a wrong method
   is an ordinary trie miss, and a 405 would need a second lookup.

   Neither exposes a hook for it — both construct their not-found responder internally, so the
   customisation point is error-handling middleware catching the 404, not a registered fallback. Closing
   the divergence *through the bridge* would therefore mean intercepting misses inside it, which is
   ownership the `ServerTransport` path does not take: there, WireMVC collates onto the host's router
   rather than owning it, the same position file serving sits in.

   That is a statement about the bridge, not about **native per-framework adapters**, which are an open
   question awaiting a rationale rather than a decision already taken (#188 tracks the connection-metadata
   ceiling item, which is one of the arguments for them). The arguments for them are the
   `ServerTransport` ceiling items — connection metadata, protocol upgrade, non-`{name}` path syntax — and
   the argument against is portability. Tracing was measured and is *not* among the arguments for: ambient
   context crosses the bridge intact on the path WireMVC uses (swift-wire's
   [RemainingSurfaceWork.md](https://github.com/tachyonics/swift-wire/blob/main/Documentation/Notes/RemainingSurfaceWork.md)).
   A 405 that matched the native path would be one more item on the *for* side, not a reason on its own.
2. ~~**Full precedence.**~~ **Shipped, in two halves.**

   The half that was separable is done, and it was hiding a silent defect rather than a missing feature.
   A node has one parameter edge, and that edge carried the `{name}`, so the name belonged to whichever
   route registered **first**: with `GET /users/{id}` and `DELETE /users/{userId}`, the DELETE handler's
   value arrived under `"id"`. A `@Path userId` binding would look it up, find nothing, and fail somewhere
   with no visible connection to the registration order that caused it.

   Names now belong to the **route**, not the edge. `resolve` collects matched values *positionally* and
   names them only once a route is chosen, from that route's own template — so each route spells its
   parameters however it likes and the outcome cannot depend on who registered first. Pinned both ways
   round, including for multi-parameter paths where a misalignment would slide a name onto the wrong value.

   Literal-beats-parameter was already order-independent, being decided by structure rather than arrival;
   that is now pinned in both registration orders so it stays so.

   **Parameter-beats-catch-all was the other half**, and it arrived with catch-all (item 3) rather than
   after it: the precedence is not coded anywhere. A literal edge is tried first, then the parameter edge,
   and the catch-all is what is left when neither matches — so `literal > parameter > catch-all` falls out
   of the order the walk tries edges in. Pinned by `RouteTrieTests.literalAndParameterBothBeatACatchAll()`,
   with `earlierParametersStillBindAlongsideACatchAll()` covering the mixed case.
3. ~~**Catch-all / wildcard params.**~~ **Shipped on the native path.** `{name*}` as the final segment
   binds the whole remainder — `/files/{path*}` against `/files/a/b/c.css` binds `path` = `a/b/c.css`.

   **Precedence falls out rather than being coded**, which completes item 2's other half. The catch-all is
   remembered as the walk passes a node carrying one, and consulted *only* when the walk cannot advance —
   so a literal edge wins, then the parameter edge, then the catch-all. `/files/readme`, `/files/other`
   and `/files/a/b` reach three different routes with all three registered.

   **The remainder is bound undecoded** — the one place this router does not percent-decode, and
   deliberately. A single segment has no structure to lose, so decoding it is safe; a remainder spans
   separators, and decoding it would turn `%2F` into a real path boundary before whatever resolves it
   against a filesystem or a bucket ever sees it. That is the traversal class item 6 cites Spring's
   documentation on. A handler wanting components decodes them per segment, which is the only order that
   keeps the structure.

   **One or more segments, and last only.** `/files` does not match `/files/{path*}` — register it
   separately if it should serve; a zero-length remainder pushes `""` handling into every handler.
   A catch-all before the end is rejected, since everything after it is unreachable — the same call
   RoutingKit makes.

   **Not bridgeable, and that is where it is refused.** `WireMVCServerTransport` throws on a catch-all
   route: the path crosses `ServerTransport.register` as an OpenAPI `{name}` template, and the adapters
   interpret a wildcard in it differently — Hummingbird as a single-segment capture named `path*`, Vapor
   as a *literal* segment. Refused at registration rather than at codegen because only there is the
   runtime known: a controller in a shared package does not know whether it will be served natively or
   bridged. Codegen still rejects the shapes no template expresses anywhere — a bare `*`, Hummingbird's
   prefix/suffix forms — and a misplaced catch-all.

   So this is a **portability cliff inside the route surface**, entered knowingly: a controller using a
   catch-all serves on the native runtime only. Both hosts have wildcards of their own, so the gap is on
   the bridge's side, and whether it closes at a small seam is what
   [CatchAllMountingProbe.md](CatchAllMountingProbe.md) measures — now with a native implementation to
   mount, which is what the probe needed.

4. ~~**Trailing-slash policy.**~~ **Shipped, as two of the three.** `TrailingSlashPolicy` is chosen where
   an app builds its router — `TrieRouteBuilder(for: server, trailingSlash:)`, i.e. its
   `createRouteBuilder(for:)` — because it is a property of the app's URL contract, not of a route.

   - `.lenient` (**default**) — `/users/` and `/users` are one resource. What the behaviour already was,
     but as a decision rather than a side effect of omitting empty segments while splitting.
   - `.strict` — `/users/` does not match `/users`. Judged on the path before the query (`/users/?x=1` has
     a trailing slash, `/users?x=1` does not) and before splitting, since splitting is what erased the
     distinction. `/` is exempt: it is the root rather than a trailing slash on something, and rejecting
     it would make the root unreachable.

   Route **templates** normalise slash-free either way — registration splits identically, so `/users/` and
   `/users` are one node, and writing both is now a duplicate. The policy therefore governs the request
   side only.

   **`.redirect` is not built**, and that is the deferral rather than an oversight. Canonicalising means
   *writing a response head* — a 308 with `Location`, preserving the method where a 301 would not — and a
   head written by the router carries no global `@Middleware` contributions, which is the gap the 405
   needed a synthesised handler to close. It would want a third synthesised handler beside `@NotFound`'s
   and the 405's. Cheap to add once something asks; nothing has, and an API-first stack is the context
   where redirecting is least wanted — a 308 on a `POST` is a round trip a client did not ask for.

   Prior art is genuinely split, which is why the policy is explicit rather than picked for everyone.
   **Hummingbird** and **Vapor** are both lenient with no option (each splits omitting empty segments).
   **Express** exposes `strict routing`, default off, and leaves redirecting to middleware.
   **Go's `ServeMux`** redirects (301) toward a registered `/a/`, which surprises people often enough to
   have its own issue ([golang/go#11757](https://github.com/golang/go/issues/11757)). **Django** redirects
   by default via `APPEND_SLASH`, and 404s when it is off. Defaulting to `.lenient` keeps us with the
   Swift neighbours; `.strict` is there for an app that wants one URL per resource.
5. ~~**Duplicate-route diagnostics.**~~ **Shipped.** `insert` reports a `RouteInsertion` — `.inserted` or
   `.duplicate(existing:)` — and `TrieRouteBuilder` turns the second into a `preconditionFailure` naming
   the method and both templates. Fatal at registration, which is startup: a duplicate has no recovery
   better than stopping, and accepting it silently left the second route unreachable (`resolve` takes the
   first match), so a controller's route went dead and surfaced later as a 404 on a route visibly present
   in the source.

   **Duplicate is a property of the node, not of the template text.** A node carries one parameter edge
   and the first name wins, so `/users/{id}` and `/users/{name}` are the same node — registering one
   method on both is a real collision that comparing strings would miss. The message names the template
   that claimed the node, which is what turns "why is my route 404ing" into an answer. The template is
   carried on build nodes only; `freeze()` drops it, so serving pays nothing.

   The trie only *reports*; the builder decides to stop. That split is what keeps the detection unit
   testable — a precondition inside the trie could not be tested without killing the test process.

   Where the neighbours sit: **Hummingbird** also crashes
   (`preconditionFailure("\(method.rawValue) already has a handler")`), while **Vapor** logs at `info`
   and lets the last registration win. Vapor's leniency suits a router whose routes are written by hand
   and may be deliberately overridden; WireMVC's come from `@Controller` annotations collated by codegen,
   where there is no override idiom and a duplicate is unambiguously a mistake.
6. ~~**Percent-decoding** of path parameters (`/users/a%20b` → `a b`).~~ **Shipped.** Applied to bound
   parameters only, *after* the path is split — so `%2F` binds one parameter containing a slash rather
   than reintroducing a path boundary. `+` is left alone: it means space in
   `application/x-www-form-urlencoded`, a query convention, and is an ordinary character in a path
   segment. Malformed input (a stray `%`, a truncated escape, bytes that are not UTF-8) leaves the segment
   exactly as it arrived rather than failing the request — matching Vapor's `removingPercentEncoding ?? $0`
   and keeping a malformed URI a routing question rather than a 400 the router invented. Hand-rolled
   rather than `removingPercentEncoding`, so the router stays free of Foundation on a per-request path;
   a segment with no `%` allocates nothing.

   **Literal segments are matched encoded, and that is settled rather than deferred.** The question is
   whether to decode the path *before* matching, so `/h%C3%A9llo` reaches a route registered as `/héllo`.
   The answer is no, and the industry has been moving in that direction rather than towards it — see
   *Prior art on decode-before-match* below.

   Another **cross-runtime divergence**, and a three-way one. Vapor decodes (RoutingKit's `Parameters.set`),
   Hummingbird does **not** — nothing in its router calls `removingPercentEncoding` — so on that runtime a
   `%`-escaped id reaches a handler still escaped. Measured and pinned by `PathParameterDecodingTests` in
   each of the three example runtimes.

## Prior art on decode-before-match

Recorded because the choice looks arbitrary until you see who has tried the other one. Two camps:

**Decode the whole path, then match.**

- **Go `net/http.ServeMux`** (1.22+) decodes every percent-encoded segment before matching, and
  `PathValue` returns decoded. It has already produced a reported defect: [golang/go#75019](https://github.com/golang/go/issues/75019)
  shows `/;x=y%3ba%3db` matching as `;x=y;a=b`, so an encoded delimiter and a literal one become
  indistinguishable. Closed as not planned, with no raw-value escape hatch.
- **ASP.NET Core** matches literal text against "the decoded representation of the URL's path", with
  acknowledged inconsistencies in whether route *parameters* are decoded
  ([dotnet/aspnetcore#30655](https://github.com/dotnet/aspnetcore/issues/30655)).
- **Spring, legacy** (`AntPathMatcher` + `UrlPathHelper.urlDecode`, on by default since 2.5). Their own
  documentation calls it out: the request URI "needs to be decoded to make it possible to compare to
  controller mappings, but this is undesirable because of the potential to decode reserved characters that
  alter the path structure."

**Match encoded, decode per segment** — what this router does.

- **Spring's `PathPatternParser`**, the replacement for the above and the **default since Spring 6.0**:
  "a parsed `PathPattern` matches to a parsed representation of the path called `RequestPath`, one path
  segment at a time … This allows decoding and sanitizing path segment values individually without the
  risk of altering the structure of the path." That is split-then-decode-per-segment, arrived at
  independently here.
- **Express** matches the encoded path and decodes captured params with `decodeURIComponent`.
- **Vapor** does the same, via RoutingKit's `Parameters.set`.
- **Hummingbird** matches encoded but decodes nothing — the one runtime where an escaped id reaches a
  handler still escaped.

| | Literal matching | Bound parameters |
|---|---|---|
| Go `ServeMux` | decoded | decoded |
| ASP.NET Core | decoded | inconsistent |
| Spring ≤ 5 (legacy) | decoded | decoded |
| **Spring 6 (default)** | **encoded** | **per segment** |
| Express | encoded | decoded |
| Vapor | encoded | decoded |
| **WireMVC** | **encoded** | **decoded** |
| Hummingbird | encoded | not decoded |

The direction of travel is the argument: the framework that shipped our rejected behaviour migrated away
from it, published why, and made the alternative its default. Nothing is moving the other way. RFC 3986
agrees — §2.4 says octets are decoded only "when they are being extracted from the URI for use outside",
which is what handing a parameter to a handler is, and what matching structure is not.

### The one axis where a reasonable implementation differs

**Malformed input.** Express throws `URIError: Failed to decode param` and answers **400**; Vapor is
lenient (`removingPercentEncoding ?? $0`). This router took Vapor's position.

Express's case is real — a malformed URI *is* a client error, and a 400 surfaces it rather than routing an
identifier no client sent. Against it: emitting one would need a fourth `RouteResolution` case, and
leniency keeps a bad URI a routing question rather than an error the router invented. Recorded as a choice
rather than an oversight, so revisiting it starts from the trade rather than from scratch.

**Shipped since v1:** `registerNotFound(handler:)` — `TrieRouteBuilder` stores one
optional fallback handler, `FrozenTrieRouter` dispatches to it on a miss (the built-in 404 is the
never-registered safety net). It's on the `FinalizableHTTPServerRouteBuilder` refinement, so a
`@WireMVCBootstrap`'s generated `@main` registers the app's `@NotFound` handler (or a synthesized 404)
before `finalize()`.

## Relationship to `@WireMVCBootstrap`

- **The `@NotFound` fallback** is what `registerNotFound` exists for; the generated `@main` registers the
  app's `@NotFound` handler (or a synth-404) so it's a real route.
- **The global-middleware front layer** folds the global `@Middleware` into every route *including* the
  fallback — so global concerns (access log, CORS) wrap the 404 too.
