# Trie router

## Purpose

The router the proposal-native path serves through, shipped in the opt-in `WireMVCRouter` target.
`TrieRouteBuilder` is the mutable `FinalizableHTTPServerRouteBuilder` that `WireMVC.apply` registers
onto; `finalize()` freezes it into `FrozenTrieRouter`, the `HTTPServerRequestHandler` the server
serves, and `TrailingSlashPolicy` is the one option it takes. This spec covers which route serves a
request, how its parameters bind, the trailing-slash policy, the registrations it refuses and what it
answers when nothing serves a request.

In the scenarios, a route *serves* a request when the frozen router calls that route's handler, and a
parameter *binds* a value when that handler receives the value under the parameter's name in its path
parameters. A request that *is not found* is handed to the handler given to
`registerNotFound(handler:)`, or answered the built-in `404` when none was given. A request answered
*`405` with `Allow: X`* has the methods `X`, in that order, handed to the handler given to
`registerMethodNotAllowed(handler:)`, or is answered the built-in `405` carrying that header when none
was given. The last two requirements specify both. The routing algorithm behind these outcomes is
internal to the target, and most pins below measure it directly, at the trie level, rather than
through `FrozenTrieRouter`.

Rationale: [WireMVCRouter](../../../Documentation/Notes/WireMVCRouter.md).
Documentation: [WhatDiffersByRuntime](../../../Sources/WireMVC/WireMVC.docc/WhatDiffersByRuntime.md).

## Requirements

### Requirement: Registration and serving are separate types
`TrieRouteBuilder<RequestContext, Reader, ResponseSender>` SHALL conform to
`FinalizableHTTPServerRouteBuilder`, and its `consuming func finalize()` SHALL return a
`FrozenTrieRouter<RequestContext, Reader, ResponseSender>` that conforms to `HTTPServerRequestHandler`
and serves the routes, the not-found handler and the method-not-allowed handler registered on the
builder before it was finalized. `TrieRouteBuilder.init(for:trailingSlash:)` SHALL infer the three type
parameters from an `HTTPServer`.

#### Scenario: a registered route is served by the frozen router
- **WHEN** a test registers `GET /users` on a `TrieRouteBuilder`, calls `finalize()`, and hands a `GET /users` request to the result's `handle(request:requestContext:reader:responseSender:)`
- **THEN** the registered handler runs

#### Scenario: a hand-written program freezes before serving
- **WHEN** `WireMVCExample` builds a `TrieRouteBuilder` with `init(for:)`, applies its graph and calls `finalize()`
- **THEN** every route it drives over HTTP is answered by the frozen router

Pinned by: `Fixtures/Sources/WireMVCExample/main.swift` (the `Run end-to-end example` step of the `BuildAndRun` job in `.github/workflows/build.yml`), `Fixtures/Tests/WireMVCFallbackExampleTests/FallbackTests.swift` (`matchedRouteCarriesTheGlobalHeader`). The first scenario, a unit test dispatching a matched request through `FrozenTrieRouter`, is pinned by nothing yet.

### Requirement: Matching is by whole segment
The router SHALL split a request path on `/` and match it segment by segment against the registered
templates, so a request path that stops at a prefix of a template is not served by that template.

#### Scenario: a parameter binds its segment
- **WHEN** `GET /users/{id}` is registered and `GET /users/42` is requested
- **THEN** that route serves it and `id` binds `42`

#### Scenario: several parameters bind in order
- **WHEN** `GET /a/{x}/b/{y}` is registered and `GET /a/1/b/2` is requested
- **THEN** `x` binds `1` and `y` binds `2`

#### Scenario: a different path misses
- **WHEN** `GET /users/{id}` is registered and `GET /posts/1` is requested
- **THEN** the request is not found

Pinned by: at the trie level, `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`literalMatchBindsNoParameters`, `pathParameterBinds`, `multipleParametersBind`, `noMatchReturnsNil`, `prefixWithoutRouteReturnsNil`, `binarySearchFindsAmongManyLiterals`).

### Requirement: Precedence is literal, then parameter, then catch-all, whatever the registration order
At each segment the router SHALL prefer a template with a literal there over one with a `{param}`
there, and SHALL NOT backtrack once a literal has matched. When neither can serve the request, either
because no template continues with the next segment or because the template the path reaches has no
route for the request's method, the router SHALL fall back to a `{name*}` catch-all registered under
the longest prefix of the request path that carries one, provided at least one segment remains after
that prefix. Only that longest prefix SHALL be consulted: if its catch-alls have no route for the
request's method, the request is not found, even when a catch-all under a shorter prefix would serve
it, which is tracked in https://github.com/swift-wire/wire-mvc/issues/243. Which route serves a
request SHALL NOT depend on the order the routes were registered in.

#### Scenario: all three under one prefix
- **WHEN** `/files/{path*}`, `/files/{name}` and `/files/readme` are registered for `GET` in that order
- **THEN** `/files/readme` is served by the literal route, `/files/other` by the parameter route, and `/files/a/b` by the catch-all route

#### Scenario: the parameter route registered first
- **WHEN** `/users/{id}` is registered before `/users/me`
- **THEN** `GET /users/me` is still served by the `/users/me` route

#### Scenario: a shallower catch-all is not consulted
- **WHEN** `GET /{all*}` and `POST /files/{path*}` are registered and `GET /files/a/b` is requested
- **THEN** the request is not found, while `GET /other/a` is served by the `/{all*}` route

Pinned by: at the trie level, `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`literalBeatsParameter`, `literalBeatsParameterWhicheverRegistersFirst`, `literalAndParameterBothBeatACatchAll`). Consulting only the longest catch-all prefix is pinned by nothing yet.

### Requirement: Each route names its own parameters
The router SHALL name the values a request binds from the template of the route that serves it, so two
routes whose templates differ only in a parameter's name, registered for different methods, each
receive their own names.

#### Scenario: two spellings on one path
- **WHEN** `GET /users/{id}` and `DELETE /users/{userId}` are registered, in either order
- **THEN** `GET /users/9` binds only `id` and `DELETE /users/9` binds only `userId`

Pinned by: at the trie level, `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`eachRouteNamesItsOwnParameters`, `parameterNamingIsIndependentOfRegistrationOrder`, `multipleParametersAreNamedPositionally`).

### Requirement: A catch-all binds one or more trailing segments, undecoded
A final template segment of the form `{name*}` SHALL bind the rest of the request path, separators
included, under `name`. It SHALL serve a request only when at least one segment remains, and the bound
remainder SHALL NOT be percent-decoded. Parameters bound before the catch-all SHALL still bind.

#### Scenario: a deep remainder
- **WHEN** `GET /files/{path*}` is registered and `GET /files/a/b/c.css` is requested
- **THEN** `path` binds `a/b/c.css`

#### Scenario: no remainder
- **WHEN** `GET /files/{path*}` is registered and `GET /files` is requested
- **THEN** the request is not found

#### Scenario: an escaped separator in the remainder
- **WHEN** `GET /files/{path*}` is registered and `GET /files/a%2Fb/c` is requested
- **THEN** `path` binds `a%2Fb/c`

#### Scenario: a parameter before the catch-all
- **WHEN** `GET /u/{id}/files/{path*}` is registered and `GET /u/9/files/a/b` is requested
- **THEN** `id` binds `9` and `path` binds `a/b`

Pinned by: at the trie level, `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`aCatchAllBindsTheRemainder`, `aCatchAllMatchesOneOrMoreSegments`, `aCatchAllRemainderIsNotDecoded`, `earlierParametersStillBindAlongsideACatchAll`, `aCatchAllRemainderStartsAtTheSegmentItClaims`).

### Requirement: A catch-all before the last segment is rejected
`TrieRouteBuilder.register` SHALL stop the process with a `preconditionFailure` for a template with a
`{name*}` segment before its last, with the message `route '<path>': '<segment>' claims the rest of the
path, so the segments after it can never match. A catch-all must be the last segment.` WireMVCRouteGen
SHALL report the same template at build time as the error `catchAllNotLastSegment` with the message
`route path "<path>": '<segment>' claims the rest of the path, so the segments after it can never
match — a catch-all must be the last segment`.

#### Scenario: registration names the misplaced segment
- **WHEN** `GET /files/{path*}/edit` is registered on a `TrieRouteBuilder`
- **THEN** registration fails with `route '/files/{path*}/edit': '{path*}' claims the rest of the path, so the segments after it can never match. A catch-all must be the last segment.`

#### Scenario: codegen rejects the template
- **WHEN** `@Controller("/files")` declares `@Get("/{path*}/edit")`
- **THEN** WireMVCRouteGen reports one error containing `must be the last segment`

Pinned by: at the trie level, `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`aCatchAllMustBeTheLastSegment`), which measures that the template is refused naming `{path*}`; `Tests/WireMVCCodegenTests/BindingObligationsTests.swift` (`misplacedCatchAllIsDiagnosed`). The builder's `preconditionFailure` and its message are pinned by nothing yet.

### Requirement: Other wildcard segments are rejected
`TrieRouteBuilder.register` SHALL stop the process with a `preconditionFailure` for a template
containing a bare `*` or `**` segment, with the message `route '<path>' uses '<segment>': the only
wildcard WireMVC route templates express is the trailing catch-all, '{name*}'. Register the concrete
paths, or serve this shape with the host framework's own router.` WireMVCRouteGen SHALL report the
same segments at build time as the error `wildcardPathSegment` with the message `route path "<path>"
uses '<segment>': the only wildcard WireMVC route templates express is the trailing catch-all,
'{name*}'`, and SHALL NOT report a trailing `{name*}` or an ordinary `{name}`.

#### Scenario: registration names each shape
- **WHEN** `GET /files/*` and `GET /files/**` are each registered on a `TrieRouteBuilder`
- **THEN** registration fails with `route '/files/*' uses '*': …` and `route '/files/**' uses '**': …` respectively

#### Scenario: codegen rejects a bare star
- **WHEN** `@Controller("/files")` declares `@Get("/*")`
- **THEN** WireMVCRouteGen reports one error whose message contains `{name*}`

#### Scenario: codegen accepts a trailing catch-all
- **WHEN** `@Controller("/files")` declares `@Get("/{path*}")` with `@Path path: String`
- **THEN** WireMVCRouteGen reports no error

Pinned by: at the trie level, `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`otherWildcardShapesAreStillRejected`, `ordinaryParametersAreUnaffected`), which measure that `*` and `**` are refused naming the segment and that ordinary parameters are accepted; `Tests/WireMVCCodegenTests/BindingObligationsTests.swift` (`unexpressibleWildcardIsDiagnosed`, `catchAllTemplateIsNotDiagnosed`, `ordinaryParameterIsNotDiagnosed`). The builder's `preconditionFailure` and its message are pinned by nothing yet.

### Requirement: A duplicate route stops registration
`TrieRouteBuilder.register` SHALL stop the process with a `preconditionFailure` when a route for the
same method is already registered on a template that is the same route as the one being registered.
Two templates that differ only in parameter names, or only in a trailing slash, are the same route, and
so are two catch-alls under one prefix. The message SHALL be `duplicate route: <METHOD> '<path>' is
registered twice.` when the two templates are equal as written, and `duplicate route: <METHOD> '<path>'
collides with '<existing>' — they differ only in parameter *names*, which a router cannot tell apart,
so only the first would ever be reached.` otherwise, where `<existing>` is the earlier template as it
was written. The same path registered for different methods, and distinct paths sharing a prefix, SHALL
each register.

#### Scenario: the same template twice
- **WHEN** `GET /users` is registered twice
- **THEN** the second registration fails with `duplicate route: GET '/users' is registered twice.`

#### Scenario: parameter names that differ only in spelling
- **WHEN** `GET /users/{id}` then `GET /users/{name}` are registered
- **THEN** the second registration fails with `duplicate route: GET '/users/{name}' collides with '/users/{id}' — they differ only in parameter *names*, which a router cannot tell apart, so only the first would ever be reached.`

#### Scenario: different methods on one path
- **WHEN** `GET`, `POST` and `DELETE` are registered on `/users`
- **THEN** all three register, and each method's request is served by its own route

Pinned by: at the trie level, `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`registeringTheSameMethodAndPathTwiceIsADuplicate`, `parameterNamesThatDifferOnlyInSpellingStillCollide`, `twoCatchAllsAtOneNodeAreADuplicate`, `aDuplicateConsumesNoRouteIndex`, `aRejectedDuplicateLeavesTheFirstRouteServing`, `differentMethodsOnOnePathAreNotDuplicates`, `distinctPathsSharingAPrefixAreNotDuplicates`), which measure that the trie refuses each duplicate naming the earlier template and accepts the rest; `aDuplicateConsumesNoRouteIndex` and `aRejectedDuplicateLeavesTheFirstRouteServing` measure bookkeeping with no effect through `TrieRouteBuilder`, whose registration stops the process. The builder's `preconditionFailure` and its messages are pinned by nothing yet.

### Requirement: A wrong method on a registered path is a 405 with a sorted `Allow`
When a request's path reaches a template carrying exact (non-catch-all) routes but none for the
request's method, and no catch-all the request passed has a route for that method, the router SHALL
answer `405` with `Allow` listing the distinct methods registered on that template, sorted by raw value
and joined by `, `. The methods SHALL be those of the template the literal-first walk reached, not a
union with templates it passed over. A request that a catch-all route would serve but for its method
SHALL be not found rather than a `405`, which is tracked in
https://github.com/swift-wire/wire-mvc/issues/244.

#### Scenario: three methods registered out of order
- **WHEN** `POST`, `GET` and `DELETE` are registered on `/users` and `PUT /users` is requested
- **THEN** the answer is `405` with `Allow: DELETE, GET, POST`

#### Scenario: a literal wins the walk
- **WHEN** `GET /users/me` and `DELETE /users/{id}` are registered and `DELETE /users/me` is requested
- **THEN** the answer is `405` with `Allow: GET`

#### Scenario: over a real server
- **WHEN** the `WireMVCFallbackExample` app serves `GET /ping` and a client sends `DELETE /ping`
- **THEN** the response is `405` with `Allow: GET`

#### Scenario: a catch-all for the method pre-empts the 405
- **WHEN** `GET /files/{path*}` and `POST /files/upload` are registered and `GET /files/upload` is requested
- **THEN** the catch-all route serves it with `path` bound to `upload`

#### Scenario: a wrong method on a catch-all
- **WHEN** only `GET /files/{path*}` is registered and `DELETE /files/x` is requested
- **THEN** the request is not found

Pinned by: at the trie level, `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`methodMismatchIsMethodNotAllowed`, `allowedMethodsAreDeduplicatedAndSorted`, `methodNotAllowedIsReportedForTheNodeActuallyReached`), which measure the allowed methods and their order; `Fixtures/Tests/WireMVCFallbackExampleTests/FallbackTests.swift` (`aWrongMethodOnARealRouteIsMethodNotAllowed`). Joining several methods into one `Allow` header and the two catch-all conditions are pinned by nothing yet.

### Requirement: An interior path is a 404
A request whose path is only a prefix of registered templates, with no route of its own, SHALL be not
found, unless a catch-all the request passed has a route for its method, in which case that catch-all
SHALL serve it with the remainder after the catch-all's prefix.

#### Scenario: a waypoint to a parameter route
- **WHEN** only `GET /users/{id}` is registered and `POST /users` is requested
- **THEN** the request is not found

#### Scenario: an interior path under a catch-all
- **WHEN** `GET /files/{path*}` and `GET /files/a/b` are registered and `GET /files/a` is requested
- **THEN** the catch-all route serves it with `path` bound to `a`

Pinned by: at the trie level, `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`anInteriorNodeIsNotFoundRatherThanMethodNotAllowed`, `prefixWithoutRouteReturnsNil`). The catch-all exception is pinned by nothing yet.

### Requirement: The query is stripped before matching
The router SHALL match only the part of the request path before the first `?`.

#### Scenario: a query on a parameter route
- **WHEN** `GET /users/{id}` is registered and `GET /users/42?trace=abc` is requested
- **THEN** `id` binds `42`

Pinned by: at the trie level, `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`queryStringIsIgnored`).

### Requirement: Runs of separators collapse
The router SHALL treat a run of `/` in a request path as one separator, and SHALL split a template the
same way when it is registered. A trailing run of `/` is subject to the `TrailingSlashPolicy`: under
`.strict` the request is not found.

#### Scenario: doubled separators
- **WHEN** `GET /a/b` is registered on a `TrieRouteBuilder` with `.lenient`, and `//a/b`, `/a//b` and `/a/b//` are requested
- **THEN** that route serves each

#### Scenario: a parameter after doubled separators
- **WHEN** `GET /users/{id}` is registered and `GET /users//42` is requested
- **THEN** `id` binds `42`

Pinned by: at the trie level, `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`repeatedSeparatorsCollapseToOneSegment`, `aParameterBindsAcrossRepeatedSeparators`).

### Requirement: `TrailingSlashPolicy` governs the request side, lenient by default
`TrailingSlashPolicy` SHALL have the cases `.lenient` and `.strict`, and both `TrieRouteBuilder`
initialisers SHALL default to `.lenient`. Under `.lenient` a trailing slash on a request path SHALL be
ignored. Under `.strict` a request whose path is longer than `/` and ends in `/` before its query SHALL
be not found, and `/` itself SHALL still be served. A template written with a trailing slash SHALL be
the same route as the slash-free template under either policy, so registering both for one method is a
duplicate. A `.redirect` policy is not built: https://github.com/swift-wire/wire-mvc/issues/182.

#### Scenario: lenient
- **WHEN** `GET /users` is registered on a `TrieRouteBuilder` with `.lenient` and `GET /users/` is requested
- **THEN** that route serves it

#### Scenario: strict
- **WHEN** `GET /users` is registered on a `TrieRouteBuilder` with `.strict`, and `/users/` and `/users/?x=1` are requested
- **THEN** both are not found, while `/users` and `/users?x=1` are served

#### Scenario: strict root
- **WHEN** `GET /` is registered on a `TrieRouteBuilder` with `.strict` and `GET /` is requested
- **THEN** that route serves it

#### Scenario: templates normalise
- **WHEN** `GET /users/` then `GET /users` are registered
- **THEN** the second registration fails with `duplicate route: GET '/users' collides with '/users/' — they differ only in parameter *names*, which a router cannot tell apart, so only the first would ever be reached.`

Pinned by: at the trie level, `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`lenientTreatsATrailingSlashAsTheSameResource`, `strictRejectsATrailingSlash`, `strictStillServesTheRoot`, `strictAppliesBeforeTheQueryIsConsidered`, `aTemplateWrittenWithATrailingSlashNormalises`, `strictDoesNotAffectAnUnmatchedPath`); `aTemplateWrittenWithATrailingSlashNormalises` measures that the trie refuses the second template naming `/users/`, not the builder's message. The `.lenient` default of the `TrieRouteBuilder` initialisers is pinned by nothing yet.

### Requirement: Parameters are percent-decoded after splitting
The router SHALL percent-decode each bound `{name}` value after the path is split, accepting upper- and
lower-case hex, and SHALL leave `+` unchanged. A malformed escape (a `%` not followed by two hex digits)
SHALL be kept verbatim while the segment's other escapes are still decoded, and a segment whose decoded
bytes are not valid UTF-8 SHALL bind exactly as it arrived.

#### Scenario: an escaped space
- **WHEN** `GET /users/{name}` is registered and `GET /users/a%20b` is requested
- **THEN** `name` binds `a b`

#### Scenario: an escaped slash stays inside one parameter
- **WHEN** `GET /files/{path}` is registered and `GET /files/a%2Fb` is requested
- **THEN** `path` binds `a/b` and it is the only parameter

#### Scenario: multi-byte UTF-8
- **WHEN** `GET /greet/{word}` is registered and `GET /greet/h%C3%A9llo` is requested
- **THEN** `word` binds `héllo`

#### Scenario: malformed input
- **WHEN** `GET /x/{v}` is registered and `/x/a%`, `/x/a%2`, `/x/a%zz` and `/x/%FF` are requested
- **THEN** `v` binds `a%`, `a%2`, `a%zz` and `%FF`

#### Scenario: a malformed escape beside a valid one
- **WHEN** `GET /x/{v}` is registered and `GET /x/a%zz%20b` is requested
- **THEN** `v` binds `a%zz b`

#### Scenario: a plus sign
- **WHEN** `GET /users/{name}` is registered and `GET /users/a+b` is requested
- **THEN** `name` binds `a+b`

Pinned by: at the trie level, `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`aPercentEscapeInAParameterIsDecoded`, `anEncodedSlashStaysInsideOneParameter`, `multiByteUTF8Decodes`, `lowerAndUpperCaseHexBothDecode`, `plusIsNotASpaceInAPath`, `malformedEscapesAreLeftAlone`, `bytesThatAreNotUTF8LeaveTheSegmentRaw`, `aSegmentWithoutEscapesIsUntouched`). Decoding the other escapes beside a malformed one is pinned by nothing yet.

### Requirement: Literal segments are matched encoded
The router SHALL compare a request segment against a template's literal segment as it arrived, without
percent-decoding it first.

#### Scenario: an escaped literal
- **WHEN** only `GET /héllo` is registered and `GET /h%C3%A9llo` is requested
- **THEN** the request is not found

Pinned by: nothing yet.

### Requirement: Misses dispatch to the registered fallbacks
When a not-found handler was given to `registerNotFound(handler:)`, `FrozenTrieRouter` SHALL hand it
every request that is not found, with empty path parameters. When a method-not-allowed handler was given
to `registerMethodNotAllowed(handler:)`, `FrozenTrieRouter` SHALL hand it every request answered `405`,
with the allowed methods in the order the previous requirements give.

#### Scenario: the generated fallbacks carry global middleware
- **WHEN** the `WireMVCFallbackExample` app, which declares a global `@Middleware` stamping `x-stamp: global` and no `@NotFound`, is sent `GET /no/such/route` and `DELETE /ping`
- **THEN** the responses are `404` and `405` and both carry `x-stamp: global`

Pinned by: `Fixtures/Tests/WireMVCFallbackExampleTests/FallbackTests.swift` (`synthesisedNotFoundCarriesTheGlobalHeader`, `aMethodNotAllowedCarriesTheGlobalHeader`).

### Requirement: The built-in misses state a zero length
When no not-found handler was registered, `FrozenTrieRouter` SHALL answer a request that is not found
with a bodiless `404` carrying `Content-Length: 0`. When no method-not-allowed handler was registered,
it SHALL answer a wrong-method request with a bodiless `405` carrying `Allow` (the allowed methods
joined by `, `) and `Content-Length: 0`.

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
