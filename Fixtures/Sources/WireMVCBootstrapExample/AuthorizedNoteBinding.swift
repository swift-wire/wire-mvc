// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

package import HTTPTypes
package import Wire
package import WireMVC

/// The **graph-aware binding** case, in two types.
///
/// Every other binding in these fixtures *decodes* — `@Path` reads a matched segment, `@TextBody` the
/// collected bytes, `@DigestBody` the stream — and each is one property wrapper whose `static bind` does
/// the work, because everything it needs is already in the request. This one *resolves*: it reads a
/// backend and refuses a note the caller may not have, which needs `@Inject` members, which needs an
/// instance.
///
/// One type cannot be both. A parameter attribute has to be a property wrapper — the language allows
/// nothing else there — and a wrapper's instance holds the value the call site supplies, while a graph
/// binding's instance holds the dependencies the graph supplied. Neither initialiser can be total. So the
/// wrapper stays exactly what every other binding's is, and names the worker.
///
/// Nothing here connects the worker to the route. `@RequestBinding` declares swift-wire's
/// `.injectsFromGraph`, so a route parameter naming `AuthorizedNote` is what makes the request scope hand
/// `NoteAuthorizer` back beside the controller — one hop, through the argument below.
@RequestBinding(NoteAuthorizer.self)
@propertyWrapper
package struct AuthorizedNote {
    package var wrappedValue: Note
    package init(wrappedValue: Note) { self.wrappedValue = wrappedValue }
    package init(wrappedValue: Note, _ name: String) { self.wrappedValue = wrappedValue }
}

/// The worker: an ordinary `@Scoped(seed:)` binding with ordinary dependencies.
///
/// **What it demonstrates is the ordering, not the brevity.** `authorizedNote` takes a `Note` and cannot
/// skip the refusal, because the refusal is how a `Note` comes into existence here. A handler that fetched
/// and then checked would restate that ordering per route, and a new route omitting the check would
/// compile and serve.
@Scoped(seed: HTTPRequest.self)
package struct NoteAuthorizer: ScopedRequestBound {
    package typealias Value = Note

    @Inject var backend: any NoteBackend

    /// `name` is the attribute's argument — the *action*, not a placeholder. This is why the wrapper
    /// declares no `.path` obligation: that would mean "my name is a `{name}` in the template", and this
    /// name is `"read"`. The path key it reads is its own business, named here.
    package func bind(
        name: String,
        request: HTTPRequest,
        pathParameters: [String: Substring],
        body: [UInt8]?
    ) async throws -> Note {
        guard let id = pathParameters["id"].map(String.init) else { throw NoteNotFound() }
        // `secret-` stands in for a policy decision; what matters is that it happens *here*, between the
        // request and the handler's parameter.
        guard !id.hasPrefix("secret-") else { throw NoteForbidden(action: name, id: id) }
        return Note(value: await backend.note(id))
    }
}

/// Refused by the worker, mapped by the route's `@ErrorResponse`. A plain error type: the binding throws
/// and the route's error tiers answer, exactly as they would for a handler throw.
package struct NoteForbidden: Error, Sendable {
    package let action: String
    package let id: String
}

/// The route named no `{id}` — unreachable through the declared route, and thrown rather than
/// force-unwrapped so a future route that forgets the placeholder fails as a 404 rather than a crash.
package struct NoteNotFound: Error, Sendable {}
