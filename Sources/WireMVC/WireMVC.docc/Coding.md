# Coding

Choosing the encoder and decoder a scope's routes use.

## Overview

`WireMVCCoding` carries the settings routes encode and decode with — date strategy, JSON options.
`@Coding` names which binding supplies them, at three scopes, innermost winning: the composition
root sets the application's, a controller overrides it for its routes, a route for itself.

That is the same tiering `@Middleware`, `@ErrorResponse` and `@ResponseHeader` use, for the same
reason — a policy is usually scope-wide and occasionally not.

## The two forms

```swift
@WireMVCBootstrap
@Coding(WireMVCCoding.self)          // the app's single, unkeyed coding
struct AppBootstrap { … }
```

```swift
extension WireMVCCoding {
    static let reports = BindingKey<WireMVCCoding>()
}

@Provides(WireMVCCoding.reports) static let reportCoding = WireMVCCoding(…)

@Controller("/reports")
@Coding(WireMVCCoding.reports)       // this controller's routes only
struct ReportsController { … }
```

The unkeyed form is for an application with one coding, which is most of them: there is nothing
to tell apart, so there is no name to invent. Naming it at two nested scopes overrides nothing —
both select the same binding — and that is diagnosed rather than silently ignored.

## Why a key rather than a type

The tiers all select the same *type*, and swift-wire keys the graph by type. So
`@Coding(WireMVCCoding.self)` names one binding at every scope, and an override could never
resolve to anything different. A `BindingKey` is what swift-wire already offers for binding one
type several times.

## How the settings reach the route

Through the same capability a keyed `@Middleware` uses: the route-contributor proxy gains a field
and the generated witness reads it. That is what lets the settings come from the graph while the
code that consumes them — a binding's `bind`, an outcome's encode — stays static.

Coding travels *inward* rather than wrapping, unlike middleware. Middleware composes as a
function of the request, so wrapping the finished router once is enough; coding is consumed at
leaf sites inside each route, so it has to be handed down to them.
