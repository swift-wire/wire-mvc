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

The trie port already covers what were items #1 (radix matching) and part of #3 (literal-before-param).
What remains, roughly by value; each is additive and testable through `RouteTrie`/`FrozenRouteTrie` first:

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
   the divergence would therefore mean intercepting misses inside the `ServerTransport` bridge, which is
   ownership WireMVC declines on those runtimes for the same reason file serving is native-path-only: it
   collates onto the host's router rather than owning it.
2. **Full precedence.** Literal beats parameter already; add parameter beats catch-all, and make it
   order-independent (replace first-registered-wins among ambiguous routes).
3. **Catch-all / wildcard params.** `{path*}` capturing the remainder (proxying, static files).
4. **Trailing-slash policy.** A deliberate choice (strict / redirect / lenient) instead of the
   incidental "empty segments omitted" behavior.
5. **Duplicate-route diagnostics.** Two registrations for the same method+template — surface it (a
   precondition today only guards index/handler drift).
6. ~~**Percent-decoding** of path parameters (`/users/a%20b` → `a b`).~~ **Shipped.** Applied to bound
   parameters only, *after* the path is split — so `%2F` binds one parameter containing a slash rather
   than reintroducing a path boundary. `+` is left alone: it means space in
   `application/x-www-form-urlencoded`, a query convention, and is an ordinary character in a path
   segment. Malformed input (a stray `%`, a truncated escape, bytes that are not UTF-8) leaves the segment
   exactly as it arrived rather than failing the request — matching Vapor's `removingPercentEncoding ?? $0`
   and keeping a malformed URI a routing question rather than a 400 the router invented. Hand-rolled
   rather than `removingPercentEncoding`, so the router stays free of Foundation on a per-request path;
   a segment with no `%` allocates nothing.

   **Literal segments are still matched raw**, which is a separate decision and remains open: whether
   `/h%C3%A9llo` should reach a route registered as `/héllo` is a question about routing semantics, not
   about what a handler receives once a route is chosen.

   Another **cross-runtime divergence**, and a three-way one. Vapor decodes (RoutingKit's `Parameters.set`),
   Hummingbird does **not** — nothing in its router calls `removingPercentEncoding` — so on that runtime a
   `%`-escaped id reaches a handler still escaped. Measured and pinned by `PathParameterDecodingTests` in
   each of the three example runtimes.

**Shipped since v1:** `registerNotFound(handler:)` (M5.5 Phase 4) — `TrieRouteBuilder` stores one
optional fallback handler, `FrozenTrieRouter` dispatches to it on a miss (the built-in 404 is the
never-registered safety net). It's on the `FinalizableHTTPServerRouteBuilder` refinement, so a
`@WireMVCBootstrap`'s generated `@main` registers the app's `@NotFound` handler (or a synthesized 404)
before `finalize()`.

## Relationship to M5.5 phases

- **Phase 4** added `registerNotFound` here; the generated `@main` registers the `@NotFound` fallback
  handler (or a synth-404) so it's a real route.
- **Phase 5** (global middleware fold) folds the global `@Middleware` into every route *including* the
  fallback — so global concerns (access log, CORS) wrap the 404 too.
