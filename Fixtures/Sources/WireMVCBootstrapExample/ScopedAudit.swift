// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

package import Wire
package import WireMVC

// The mock-CONSUMING middleware factory for a SEED-SCOPED subject. `SummaryAudit` covers the seedless subject
// and `AccessLog` covers a seed-scoped subject with a NON-mock factory; this covers the remaining corner, a
// seed-scoped subject whose factory injects the `@BindType`'d slot. Like `SummaryAudit`, the factory can't hold
// the mock — it arrives per request, after the facade has run — so swift-wire re-emits it as a variant factory
// whose `create(doubles:)` sources `backend` per request.

/// Factory-key namespace for the scoped-audit middleware.
package enum ScopedAuditKeys {
    package static let factory = FactoryKey()
}

/// Records a `scoped-audit` call against the injected `NoteBackend`, then forwards.
@Factory(ScopedAuditKeys.factory)
@MiddlewareFactory  // bare → positional: <Ctx, Reader, Sender> map to the roles in order (canonical)
package struct ScopedAudit<
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
        _ = await backend.note("scoped-audit")
        return try await next(input)
    }
}
