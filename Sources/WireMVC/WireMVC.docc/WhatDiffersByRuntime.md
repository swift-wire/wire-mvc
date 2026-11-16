# What differs by runtime

The controller is unchanged across runtimes. The router in front of it is not.

## Overview

On the proposal-native path, WireMVC's own router serves the routes. On Hummingbird and Vapor it
*collates* onto the host's router through `ServerTransport`, so the host decides what a miss
means. The table is what falls out of that.

| | Proposal-native | Hummingbird | Vapor |
|---|---|---|---|
| Wrong method on an existing path | `405` + `Allow` | `404` | `404` |
| Percent-decoded path parameters | yes | **no** | yes |
| Trailing slash | policy — lenient (default) or strict | lenient | lenient |
| Duplicate route registration | fatal at startup | fatal at startup | logged, last wins |
| Catch-all `{name*}` | supported | refused at registration | refused at registration |
| Ambient (task-local) context in a handler | yes | yes | yes |
| `HEAD` to a path with only a `GET` route | answered by the `GET` route, no body | `404` unless the router opts in | answered by the `GET` route, no body |

Rows 1, 2 and 6 are pinned by tests in all three runtimes of
[wire-mvc-examples](https://github.com/swift-wire/wire-mvc-examples); rows 3 and 4 are read from
each host's router source; row 5 is enforced by this package. Row 7's native half is pinned by
this package's fixtures; its other two halves are read from each host's source and not yet pinned
by a test. Hummingbird generates a `HEAD` endpoint for each `GET` only when the application builds its
`Router` with `.autoGenerateHeadEndpoints`; without it a `HEAD` is a method mismatch, which Hummingbird
answers `404`. Vapor's responder sends a `HEAD` with no `HEAD` route to the path's `GET` route. Either
way WireMVC does not route a `HEAD` on the bridge, but once a host delivers one to a route — with the
request still saying `HEAD`, as both do — the bridge sends the head alone, with the `Content-Length`
the `GET` would state. An explicit `@Head` route registers as a `HEAD` route on every runtime.

## Two kinds of difference

**Convention** — rows 1 to 4, and 7. Each runtime behaves the way its own ecosystem expects, and that is
the point of collating rather than owning. A Hummingbird application answering Hummingbird's
`404` is correct, and imposing WireMVC's `405` on it would be the wrong kind of consistency.
Nothing here is a defect.

**Capability** — row 5, and the reason it reads differently. Both hosts have wildcard routing of
their own, Hummingbird in four forms and Vapor as `.catchall`, but a WireMVC route template
cannot reach it: the path crosses `ServerTransport.register` as an OpenAPI `{name}` template, and
each adapter interprets a wildcard in it differently.

So a catch-all controller serves on the native runtime only, and putting one in a *shared* module
breaks the others at startup. That is a gap on the bridge's side rather than a limit of the
runtime, and whether it closes is being measured.

The same shape applies to the rest of the `ServerTransport` ceiling: connection metadata,
protocol upgrade and non-`{name}` path syntax are unreachable through the bridge whatever the
host supports.

## What this means for shared code

A controller in a module several runtimes compose is portable as long as it stays inside the
ceiling. The two things to keep out of shared modules are catch-all templates and any route
depending on a capability the bridge cannot carry. Everything else — verbs, typed parameters,
bodies, responses, middleware, error mapping, request scope — is identical across all three.
