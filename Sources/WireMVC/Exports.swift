// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

// A middleware author conforms to `Middleware` and spells the box over the `AsyncReader`-constrained
// reader, so a middleware (like a controller) needs only `import WireMVC`.
@_exported public import AsyncStreaming
// WireMVC's public surface and its generated `@Controller` witnesses are expressed in terms of the
// proposal's server types (`HTTPServer`, the response sender) and `HTTPRequest`/`HTTPResponse`, so
// re-export those modules. A controller file then needs only `import WireMVC`: the macro-generated
// `registerWireRoutes(on:)` resolves these through here, without the author importing them.
@_exported public import HTTPAPIs
@_exported public import HTTPTypes
@_exported public import Middleware
