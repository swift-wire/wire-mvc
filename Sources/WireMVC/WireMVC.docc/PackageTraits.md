# Package traits

What the three traits pull in, and why they are off by default.

## Overview

wire-mvc's core depends on no HTTP server and no HTML library. Three package traits opt into the
integrations that do, and each is off by default so that a consumer resolves only what it
actually serves.

```swift
.package(url: "https://github.com/swift-wire/wire-mvc.git", branch: "main",
         traits: ["NIOHTTPServer", "Elementary"]),
```

## The three

**`ServerTransport`** enables the adapter that serves proposal-native WireMVC controllers on a
`some ServerTransport` — which is how a controller reaches Hummingbird or Vapor, through
swift-openapi-hummingbird and -vapor. Off by default, the core stays proposal-only and does not
resolve OpenAPIRuntime.

**`NIOHTTPServer`** enables live-server test support: the test-server conformance and the
corresponding suite mode. Off by default, the NIO stack is pruned from the graph of a consumer
that does not serve on it — so a framework-agnostic package depending on `WireMVC` resolves no
NIO at all. Enable it to run a live suite. See <doc:TestingAnApp>.

**`Elementary`** enables HTML responses. Off by default for the same reason: a consumer serving
no HTML should not resolve an HTML library. Enable it to use `@HTMLResponse`.

## Choosing

Take `NIOHTTPServer` if you serve on the proposal-native stack or want live tests. Take
`ServerTransport` if you mount onto Hummingbird or Vapor. Take `Elementary` if any route returns
HTML. A library that only *declares* controllers, leaving the serving to its consumer, usually
needs none of them.

What differs once you have chosen a runtime is set out in <doc:WhatDiffersByRuntime>.
