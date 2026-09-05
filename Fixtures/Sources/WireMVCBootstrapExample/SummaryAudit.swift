// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

package import Wire
package import WireMVC

// A mock-CONSUMING middleware factory: unlike `AccessLog` (which injects nothing), `SummaryAudit`
// `@Inject`s the `@BindType`'d `NoteBackend`. In production the factory holds the real backend, built once when
// the route contributor's facade runs. But under a keyed suite the mock arrives per request (header →
// `TestBindStore`, after the server is up), so the factory can't hold it — swift-wire re-emits it as a variant
// factory whose `create(doubles:)` sources `backend` from the per-request doubles, and wire-mvc's variant
// witness threads those doubles to the `create` call (a per-request fold). Its `intercept` touches `backend`,
// so the supplied mock records the middleware's own call — distinct from the handler's — proving the one mock
// instance threads both the app-scoped controller's reconstruction and its lifted factory.

/// Factory-key namespace for the summary-audit middleware.
package enum SummaryAuditKeys {
    package static let factory = FactoryKey()
}

/// Records an `audit` call against the injected `NoteBackend`, then forwards — the mock-consuming counterpart
/// to `AccessLog`, lifted onto the app-scoped `SummaryController` via `@Middleware(SummaryAuditKeys.factory)`.
@Factory(SummaryAuditKeys.factory)
@MiddlewareFactory  // bare → positional: <Ctx, Reader, Sender> map to the roles in order (canonical)
package struct SummaryAudit<
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Sender: HTTPResponseSender & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    @Inject var backend: any NoteBackend

    package typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    package typealias NextInput = Input

    package func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        _ = await backend.note("audit")
        return try await next(input)
    }
}
