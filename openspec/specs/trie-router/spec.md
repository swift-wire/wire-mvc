# Trie router

## Purpose

The router the proposal-native path serves through, shipped in the opt-in `WireMVCRouter` target.
`TrieRouteBuilder` is the mutable `FinalizableHTTPServerRouteBuilder` that `WireMVC.apply` registers
onto; `finalize()` freezes it into `FrozenTrieRouter`, the `HTTPServerRequestHandler` the server
serves. The routing algorithm itself is the non-generic `RouteTrie`, frozen into `FrozenRouteTrie`,
which resolves a request to a match, a `405` or a `404`. This spec covers matching, precedence,
parameter binding, the trailing-slash policy, registration-time rejection and the router's built-in
miss responses.

Rationale: [WireMVCRouter](../../../Documentation/Notes/WireMVCRouter.md).
Documentation: [WhatDiffersByRuntime](../../../Sources/WireMVC/WireMVC.docc/WhatDiffersByRuntime.md).

## Requirements

### Requirement: Registration and serving are separate types
`TrieRouteBuilder<RequestContext, Reader, ResponseSender>` SHALL conform to
`FinalizableHTTPServerRouteBuilder`, and its `consuming func finalize()` SHALL return a
`FrozenTrieRouter<RequestContext, Reader, ResponseSender>` that conforms to `HTTPServerRequestHandler`
and holds the frozen trie, the handlers in registration order, and the optional not-found and
method-not-allowed handlers. `TrieRouteBuilder.init(for:trailingSlash:)` SHALL infer the three type
parameters from an `HTTPServer`.

#### Scenario: a registered route is served by the frozen router
- **WHEN** a test registers `GET /users` on a `TrieRouteBuilder`, calls `finalize()`, and hands a `GET /users` request to the result's `handle(request:requestContext:reader:responseSender:)`
- **THEN** the registered handler runs

#### Scenario: a hand-written program freezes before serving
- **WHEN** `WireMVCExample` builds `TrieRouteBuilder(for: server)`, applies its graph and calls `finalize()`
- **THEN** every route it drives over HTTP is answered by the frozen router

Pinned by: `Tests/WireMVCRouterTests/SynthesisedMissFramingTests.swift` (`synthesisedMethodNotAllowedStatesZeroLengthBesideAllow`), `Fixtures/Sources/WireMVCExample/main.swift` (the `Run end-to-end example` step of the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: Matching is by whole segment
The router SHALL split a request path on `/` and match it segment by segment against the registered
templates, so a path that stops at a prefix of a template does not match that template.

#### Scenario: a parameter binds its segment
- **WHEN** `GET /users/{id}` is registered and `GET /users/42` is resolved
- **THEN** the match binds `id` to `42`

#### Scenario: several parameters bind in order
- **WHEN** `GET /a/{x}/b/{y}` is registered and `GET /a/1/b/2` is resolved
- **THEN** `x` binds `1` and `y` binds `2`

#### Scenario: a different path misses
- **WHEN** `GET /users/{id}` is registered and `GET /posts/1` is resolved
- **THEN** the resolution is `.notFound`

Pinned by: `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`literalMatchBindsNoParameters`, `pathParameterBinds`, `multipleParametersBind`, `noMatchReturnsNil`, `prefixWithoutRouteReturnsNil`, `binarySearchFindsAmongManyLiterals`).

### Requirement: Precedence is literal, then parameter, then catch-all, whatever the registration order
At each node the router SHALL try the literal child first and the `{param}` edge second, and SHALL
fall back to a `{name*}` catch-all remembered on the way only when the walk cannot advance. The
outcome SHALL NOT depend on the order the routes were registered in.

#### Scenario: all three under one prefix
- **WHEN** `/files/{path*}`, `/files/{name}` and `/files/readme` are registered for `GET` in that order
- **THEN** `/files/readme` resolves to the literal route, `/files/other` to the parameter route, and `/files/a/b` to the catch-all route

#### Scenario: the parameter route registered first
- **WHEN** `/users/{id}` is registered before `/users/me`
- **THEN** `GET /users/me` still resolves to the `/users/me` route

Pinned by: `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`literalBeatsParameter`, `literalBeatsParameterWhicheverRegistersFirst`, `literalAndParameterBothBeatACatchAll`).

### Requirement: Each route names its own parameters
The router SHALL collect matched parameter values positionally and name them from the chosen route's
own template, so two routes that share a parameter edge under different names each receive their own
names.

#### Scenario: two spellings on one node
- **WHEN** `GET /users/{id}` and `DELETE /users/{userId}` are registered, in either order
- **THEN** `GET /users/9` binds only `id` and `DELETE /users/9` binds only `userId`

Pinned by: `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`eachRouteNamesItsOwnParameters`, `parameterNamingIsIndependentOfRegistrationOrder`, `multipleParametersAreNamedPositionally`).

### Requirement: A catch-all binds one or more trailing segments, undecoded
A final template segment of the form `{name*}` SHALL bind the rest of the request path, separators
included, under `name`. It SHALL match only when at least one segment remains, and the bound remainder
SHALL NOT be percent-decoded. Parameters bound before the catch-all SHALL still bind.

#### Scenario: a deep remainder
- **WHEN** `GET /files/{path*}` is registered and `GET /files/a/b/c.css` is resolved
- **THEN** `path` binds `a/b/c.css`

#### Scenario: no remainder
- **WHEN** `GET /files/{path*}` is registered and `GET /files` is resolved
- **THEN** the resolution is `.notFound`

#### Scenario: an escaped separator in the remainder
- **WHEN** `GET /files/{path*}` is registered and `GET /files/a%2Fb/c` is resolved
- **THEN** `path` binds `a%2Fb/c`

#### Scenario: a parameter before the catch-all
- **WHEN** `GET /u/{id}/files/{path*}` is registered and `GET /u/9/files/a/b` is resolved
- **THEN** `id` binds `9` and `path` binds `a/b`

Pinned by: `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`aCatchAllBindsTheRemainder`, `aCatchAllMatchesOneOrMoreSegments`, `aCatchAllRemainderIsNotDecoded`, `earlierParametersStillBindAlongsideACatchAll`, `aCatchAllRemainderStartsAtTheSegmentItClaims`).

### Requirement: A catch-all before the last segment is rejected
`RouteTrie.insert` SHALL return `.catchAllNotLast(segment)` for a template with a `{name*}` segment
before its last, and `TrieRouteBuilder.register` SHALL turn that into a `preconditionFailure` with the
message `route '<path>': '<segment>' claims the rest of the path, so the segments after it can never
match. A catch-all must be the last segment.` WireMVCRouteGen SHALL report the same template at build
time as the error `catchAllNotLastSegment` with the message `route path "<path>": '<segment>' claims
the rest of the path, so the segments after it can never match — a catch-all must be the last
segment`.

#### Scenario: the trie reports the misplaced segment
- **WHEN** `GET /files/{path*}/edit` is inserted
- **THEN** the insertion is `.catchAllNotLast("{path*}")`

#### Scenario: codegen rejects the template
- **WHEN** `@Controller("/files")` declares `@Get("/{path*}/edit")`
- **THEN** WireMVCRouteGen reports one error containing `must be the last segment`

Pinned by: `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`aCatchAllMustBeTheLastSegment`), `Tests/WireMVCCodegenTests/BindingObligationsTests.swift` (`misplacedCatchAllIsDiagnosed`). The builder's `preconditionFailure` is pinned by nothing yet.

### Requirement: Other wildcard segments are rejected
`RouteTrie.insert` SHALL return `.unsupportedSegment(segment)` for a template containing a bare `*` or
`**` segment, and `TrieRouteBuilder.register` SHALL turn that into a `preconditionFailure` with the
message `route '<path>' uses '<segment>': the only wildcard WireMVC route templates express is the
trailing catch-all, '{name*}'. Register the concrete paths, or serve this shape with the host
framework's own router.` WireMVCRouteGen SHALL report the same segments at build time as the error
`wildcardPathSegment` with the message `route path "<path>" uses '<segment>': the only wildcard
WireMVC route templates express is the trailing catch-all, '{name*}'`, and SHALL NOT report a trailing
`{name*}` or an ordinary `{name}`.

#### Scenario: the trie reports each shape
- **WHEN** `GET /files/*` and `GET /files/**` are inserted
- **THEN** the insertions are `.unsupportedSegment("*")` and `.unsupportedSegment("**")`

#### Scenario: codegen rejects a bare star
- **WHEN** `@Controller("/files")` declares `@Get("/*")`
- **THEN** WireMVCRouteGen reports one error whose message contains `{name*}`

#### Scenario: codegen accepts a trailing catch-all
- **WHEN** `@Controller("/files")` declares `@Get("/{path*}")` with `@Path path: String`
- **THEN** WireMVCRouteGen reports no error

Pinned by: `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`otherWildcardShapesAreStillRejected`, `ordinaryParametersAreUnaffected`), `Tests/WireMVCCodegenTests/BindingObligationsTests.swift` (`unexpressibleWildcardIsDiagnosed`, `catchAllTemplateIsNotDiagnosed`, `ordinaryParameterIsNotDiagnosed`). The builder's `preconditionFailure` is pinned by nothing yet.

### Requirement: A duplicate route stops registration
`RouteTrie.insert` SHALL return `.duplicate(existing:)` when a route for the same method already
occupies the node a template reaches, naming the template that claimed it, and SHALL NOT consume a
route index for it. Two templates that differ only in parameter names, or two catch-alls at one node,
SHALL be duplicates. `TrieRouteBuilder.register` SHALL turn a duplicate into a `preconditionFailure`
whose message is `duplicate route: <METHOD> '<path>' is registered twice.` when the templates are equal,
and `duplicate route: <METHOD> '<path>' collides with '<existing>' — they differ only in parameter
*names*, which a router cannot tell apart, so only the first would ever be reached.` otherwise.

#### Scenario: the same template twice
- **WHEN** `GET /users` is inserted twice
- **THEN** the second insertion is `.duplicate(existing: "/users")` and `GET /users` still resolves to the first

#### Scenario: parameter names that differ only in spelling
- **WHEN** `GET /users/{id}` then `GET /users/{name}` are inserted
- **THEN** the second insertion is `.duplicate(existing: "/users/{id}")`

#### Scenario: different methods on one path
- **WHEN** `GET`, `POST` and `DELETE` are inserted on `/users`
- **THEN** the insertions are indices `0`, `1` and `2`

Pinned by: `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`registeringTheSameMethodAndPathTwiceIsADuplicate`, `parameterNamesThatDifferOnlyInSpellingStillCollide`, `twoCatchAllsAtOneNodeAreADuplicate`, `aDuplicateConsumesNoRouteIndex`, `aRejectedDuplicateLeavesTheFirstRouteServing`, `differentMethodsOnOnePathAreNotDuplicates`, `distinctPathsSharingAPrefixAreNotDuplicates`). The builder's `preconditionFailure` is pinned by nothing yet.

### Requirement: A wrong method on a route-carrying node is a 405 with a sorted `Allow`
When the walk reaches a node that carries routes but none for the request's method, the router SHALL
resolve `.methodNotAllowed(allowed:)` with the node's distinct methods sorted by raw value. The allowed
set SHALL be that of the node the greedy walk reached, not a union with nodes it passed over.

#### Scenario: three methods registered out of order
- **WHEN** `POST`, `GET` and `DELETE` are registered on `/users` and `PUT /users` is resolved
- **THEN** the resolution is `.methodNotAllowed(allowed: [.delete, .get, .post])`

#### Scenario: a literal wins the walk
- **WHEN** `GET /users/me` and `DELETE /users/{id}` are registered and `DELETE /users/me` is resolved
- **THEN** the resolution is `.methodNotAllowed(allowed: [.get])`

#### Scenario: over a real server
- **WHEN** the `WireMVCFallbackExample` app serves `GET /ping` and a client sends `DELETE /ping`
- **THEN** the response is `405` with `Allow: GET`

Pinned by: `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`methodMismatchIsMethodNotAllowed`, `allowedMethodsAreDeduplicatedAndSorted`, `methodNotAllowedIsReportedForTheNodeActuallyReached`), `Fixtures/Tests/WireMVCFallbackExampleTests/FallbackTests.swift` (`aWrongMethodOnARealRouteIsMethodNotAllowed`).

### Requirement: An interior node is a 404
A node the walk reaches that carries no routes SHALL resolve `.notFound`, whatever the method.

#### Scenario: a waypoint to a parameter route
- **WHEN** only `GET /users/{id}` is registered and `POST /users` is resolved
- **THEN** the resolution is `.notFound`

Pinned by: `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`anInteriorNodeIsNotFoundRatherThanMethodNotAllowed`, `prefixWithoutRouteReturnsNil`).

### Requirement: The query is stripped before matching
The router SHALL match only the part of the request path before the first `?`.

#### Scenario: a query on a parameter route
- **WHEN** `GET /users/{id}` is registered and `GET /users/42?trace=abc` is resolved
- **THEN** `id` binds `42`

Pinned by: `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`queryStringIsIgnored`).

### Requirement: Runs of separators collapse
The router SHALL treat a run of `/` in a request path as one separator, and templates SHALL be split
the same way at registration.

#### Scenario: doubled separators
- **WHEN** `GET /a/b` is registered and `//a/b`, `/a//b` and `/a/b//` are resolved
- **THEN** each resolves to that route

#### Scenario: a parameter after doubled separators
- **WHEN** `GET /users/{id}` is registered and `GET /users//42` is resolved
- **THEN** `id` binds `42`

Pinned by: `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`repeatedSeparatorsCollapseToOneSegment`, `aParameterBindsAcrossRepeatedSeparators`).

### Requirement: `TrailingSlashPolicy` governs the request side, lenient by default
`TrailingSlashPolicy` SHALL have the cases `.lenient` and `.strict`, and `TrieRouteBuilder.init`
SHALL default to `.lenient`. Under `.lenient` a trailing slash on a request path SHALL be ignored.
Under `.strict` a request path longer than `/` that ends in `/` before its query SHALL resolve
`.notFound`, and `/` itself SHALL still match. A template written with a trailing slash SHALL register
the same node as the slash-free template under either policy. A `.redirect` policy is not built:
https://github.com/swift-wire/wire-mvc/issues/182.

#### Scenario: lenient
- **WHEN** `GET /users` is registered, the trie is frozen `.lenient`, and `GET /users/` is resolved
- **THEN** it resolves to that route

#### Scenario: strict
- **WHEN** `GET /users` is registered, the trie is frozen `.strict`, and `/users/` and `/users/?x=1` are resolved
- **THEN** both resolve `.notFound`, while `/users` and `/users?x=1` match

#### Scenario: strict root
- **WHEN** `GET /` is registered, the trie is frozen `.strict`, and `GET /` is resolved
- **THEN** it resolves to that route

#### Scenario: templates normalise
- **WHEN** `GET /users/` then `GET /users` are inserted
- **THEN** the second insertion is `.duplicate(existing: "/users/")`

Pinned by: `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`lenientTreatsATrailingSlashAsTheSameResource`, `strictRejectsATrailingSlash`, `strictStillServesTheRoot`, `strictAppliesBeforeTheQueryIsConsidered`, `aTemplateWrittenWithATrailingSlashNormalises`, `strictDoesNotAffectAnUnmatchedPath`). The `.lenient` default of `TrieRouteBuilder.init` is pinned by nothing yet.

### Requirement: Parameters are percent-decoded after splitting
The router SHALL percent-decode each bound `{name}` value after the path is split, accepting upper- and
lower-case hex, and SHALL leave `+` unchanged. A segment with a malformed escape, or whose decoded bytes
are not valid UTF-8, SHALL bind exactly as it arrived.

#### Scenario: an escaped space
- **WHEN** `GET /users/{name}` is registered and `GET /users/a%20b` is resolved
- **THEN** `name` binds `a b`

#### Scenario: an escaped slash stays inside one parameter
- **WHEN** `GET /files/{path}` is registered and `GET /files/a%2Fb` is resolved
- **THEN** `path` binds `a/b` and it is the only parameter

#### Scenario: multi-byte UTF-8
- **WHEN** `GET /greet/{word}` is registered and `GET /greet/h%C3%A9llo` is resolved
- **THEN** `word` binds `héllo`

#### Scenario: malformed input
- **WHEN** `GET /x/{v}` is registered and `/x/a%`, `/x/a%2`, `/x/a%zz` and `/x/%FF` are resolved
- **THEN** `v` binds `a%`, `a%2`, `a%zz` and `%FF`

#### Scenario: a plus sign
- **WHEN** `GET /users/{name}` is registered and `GET /users/a+b` is resolved
- **THEN** `name` binds `a+b`

Pinned by: `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`aPercentEscapeInAParameterIsDecoded`, `anEncodedSlashStaysInsideOneParameter`, `multiByteUTF8Decodes`, `lowerAndUpperCaseHexBothDecode`, `plusIsNotASpaceInAPath`, `malformedEscapesAreLeftAlone`, `bytesThatAreNotUTF8LeaveTheSegmentRaw`, `aSegmentWithoutEscapesIsUntouched`).

### Requirement: Literal segments are matched encoded
The router SHALL compare a request segment against literal children as it arrived, without
percent-decoding it first.

#### Scenario: an escaped literal
- **WHEN** only `GET /héllo` is registered and `GET /h%C3%A9llo` is resolved
- **THEN** the resolution is `.notFound`

Pinned by: nothing yet.

### Requirement: Misses dispatch to the registered fallbacks
`FrozenTrieRouter` SHALL dispatch a `.notFound` resolution to the handler given to
`registerNotFound(handler:)` with empty path parameters, and a `.methodNotAllowed` resolution to the
handler given to `registerMethodNotAllowed(handler:)` with the allowed methods, when each was
registered.

#### Scenario: the generated fallbacks carry global middleware
- **WHEN** the `WireMVCFallbackExample` app, which declares a global `@Middleware` stamping `x-stamp: global` and no `@NotFound`, is sent `GET /no/such/route` and `DELETE /ping`
- **THEN** the responses are `404` and `405` and both carry `x-stamp: global`

Pinned by: `Fixtures/Tests/WireMVCFallbackExampleTests/FallbackTests.swift` (`synthesisedNotFoundCarriesTheGlobalHeader`, `aMethodNotAllowedCarriesTheGlobalHeader`).

### Requirement: The built-in misses state a zero length
When no not-found handler was registered, `FrozenTrieRouter` SHALL answer a `.notFound` with a bodiless
`404` carrying `Content-Length: 0`. When no method-not-allowed handler was registered, it SHALL answer a
`.methodNotAllowed` with a bodiless `405` carrying `Allow` (the allowed methods joined by `, `) and
`Content-Length: 0`.

#### Scenario: a path miss
- **WHEN** a `TrieRouteBuilder` with only `GET /users` and no fallbacks is finalized and handles `GET /nope`
- **THEN** the head is `404` with `Content-Length: 0`

#### Scenario: a method miss
- **WHEN** the same router handles `POST /users`
- **THEN** the head is `405` with `Allow: GET` and `Content-Length: 0`

Pinned by: `Tests/WireMVCRouterTests/SynthesisedMissFramingTests.swift` (`synthesisedNotFoundStatesZeroLength`, `synthesisedMethodNotAllowedStatesZeroLengthBesideAllow`).

## Related specifications

- [route-builder-contract](../route-builder-contract/spec.md)
- [controllers-and-routes](../controllers-and-routes/spec.md)
- [composition-root](../composition-root/spec.md)
- [server-transport-bridge](../server-transport-bridge/spec.md)
- [runtime-differences](../runtime-differences/spec.md)
- [responses-and-modes](../responses-and-modes/spec.md)
- [middleware](../middleware/spec.md)
- [testing-harness](../testing-harness/spec.md)
