// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

public import ServiceLifecycle
public import Wire

// The service collation feature: the collation key, the `@BackgroundService` macro, and the
// contribution alias. `Service` is referenced in the key's `CollectedKey<any Service>`, so
// `import ServiceLifecycle` is genuinely used here.

extension WireMVCKeys {
    /// App-scoped `ServiceLifecycle` services (a database client, a connection pool) the graph runs
    /// alongside the server, handed to the app's `ServiceGroup` (`Application(services:)` on
    /// Hummingbird/Vapor, a `ServiceGroup` on the proposal server). Context-free — `any Service`
    /// carries no request context — so it collates the way controllers do. A `@Singleton`/`@Provides`
    /// binding fans into it via `@Contributes(to: WireMVCKeys.services)`, or the `@BackgroundService`
    /// sugar below.
    public static let services = CollectedKey<any Service>()
}

/// Marks a binding as a `ServiceLifecycle.Service` collated into the graph's services — sugar for
/// `@Contributes(to: WireMVCKeys.services)`, which Wire reads it as. It expands to nothing, so it goes
/// on either producer form: a `@Singleton`/`@Scoped` service *type* (`@Singleton @BackgroundService
/// final class Worker: Service`) or a `@Provides` *function* returning a service (`@Provides
/// @BackgroundService func makeClient() -> ValkeyClient`). The annotated or returned type must itself
/// conform to `Service` — the marker doesn't add the conformance.
@attached(peer)
public macro BackgroundService() =
    #externalMacro(module: "WireMVCMacros", type: "BackgroundServiceMacro")

/// Tells Wire that `@BackgroundService` aliases `@Contributes(to: WireMVCKeys.services)`, so a service
/// needs only `@Singleton @BackgroundService` — the plugin collates it without a separate
/// `@Contributes`.
public let wireMVCServiceAlias = WireAdapterAnnotationV1(
    annotation: "BackgroundService",
    capability: .contributes(to: WireMVCKeys.services)
)
