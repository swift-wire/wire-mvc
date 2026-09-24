# Graph-aware bindings

## Purpose

A request binding whose value is resolved by a request-scoped graph binding rather than decoded by a
static method. The binding is two declarations: a property wrapper carrying
`@RequestBinding(Worker.self, …)`, and a `@Scoped(seed:)` worker conforming to `ScopedRequestBound` whose
instance `bind` produces the handler's value. swift-wire reads the same attribute through the
`.injectsFromGraph` capability and yields the worker on the controller's scope entry; WireMVCRouteGen
binds the parameter off that entry, and refuses the pairings where no such entry exists. The typed
client omits such a route, as specified in [testing-harness](../testing-harness/spec.md).

Rationale: [ScopeAwareMiddlewareAndBindings](../../../Documentation/Notes/ScopeAwareMiddlewareAndBindings.md).
Documentation: [RequestBindings](../../../Sources/WireMVC/WireMVC.docc/RequestBindings.md).

## Requirements

### Requirement: `@RequestBinding(Worker.self, …)` names the worker that does the binding
The `WireMVC` module SHALL declare `@RequestBinding<Transform>(_ transform: Transform.Type, _ obligations:
WireMVCBindingObligation..., stream: String? = nil)` as an attached peer macro implemented by
`RouteMarkerMacro`. `scanRequestBindings(in:)` SHALL read an unlabelled argument spelled `X.self` as the
binding's worker `X`, and SHALL resolve the worker's seed from `X`'s own `@Scoped(seed: S.self)`
declaration in any parsed file, recording `S` without `.self`.

#### Scenario: a wrapper and worker in the fixture app
- **WHEN** `AuthorizedNoteBinding.swift` declares `@RequestBinding(NoteAuthorizer.self) struct AuthorizedNote` and `@Scoped(seed: HTTPRequest.self) struct NoteAuthorizer: ScopedRequestBound`, and `NotesController` declares `authorizedNote(@AuthorizedNote("read") note: Note)`
- **THEN** the fixtures package builds, with the route bound through `NoteAuthorizer`

#### Scenario: the worker declared beside the wrapper, read through the scan
- **WHEN** `generateRouteContributors` is given `@RequestBinding(DocumentAuthorizer.self) struct AuthorizedDocument` and `@Scoped(seed: HTTPRequest.self) struct DocumentAuthorizer` alongside a scoped controller using it
- **THEN** no scoped-binding error is reported

Pinned by: `Fixtures/Sources/WireMVCBootstrapExample/AuthorizedNoteBinding.swift` and `Fixtures/Sources/WireMVCBootstrapExample/NotesController.swift` (built by the `Build fixtures` step of the `BuildAndRun` job in `.github/workflows/build.yml`), `Tests/WireMVCCodegenTests/GraphAwareBindingTests.swift` (`theOmittedRouteIsNotAlsoNaggedAboutRequestSendable`).

### Requirement: `@RequestBinding` declares the `.injectsFromGraph` capability
The package SHALL declare `wireMVCRequestBindingAlias` as a `WireAdapterAnnotationV1` for annotation
`RequestBinding` with capability `.injectsFromGraph`, so that a route parameter naming the wrapper makes
the controller's scope entry yield the worker.

#### Scenario: the worker arrives on the scope entry
- **WHEN** the scoped `NotesController` route takes `@AuthorizedNote("read") note: Note`
- **THEN** the generated witness reads `wireMVCScopeEntry.noteAuthorizer` and the fixtures package compiles

Pinned by: `Fixtures/Sources/WireMVCBootstrapExample/NotesController.swift` (built by the `Build fixtures` step of the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: `ScopedRequestBound` is a `Sendable` instance-method binding
`ScopedRequestBound` SHALL refine `Sendable`, declare an associated type `Value`, and require the instance
method `func bind(name: String, request: HTTPRequest, pathParameters: [String: Substring], body:
[UInt8]?) async throws -> Value`. An extension SHALL supply `bind(name:request:pathParameters:body:coding:)`
forwarding to it, and `bindOptional(name:request:pathParameters:body:coding:)` returning `nil` when `bind`
throws `missingPathParameter`, `missingQueryParameter` or `missingHeader`.

#### Scenario: the fixture's worker
- **WHEN** `package struct NoteAuthorizer: ScopedRequestBound` declares `typealias Value = Note`, an `@Inject var backend: any NoteBackend` and the four-argument instance `bind`
- **THEN** it conforms without implementing the coding-aware overload

Pinned by: `Fixtures/Sources/WireMVCBootstrapExample/AuthorizedNoteBinding.swift` (built by the `Build fixtures` step of the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: The parameter is bound off the scope entry's worker field
For a parameter whose binding names a worker, the terminal SHALL emit `let <parameter> = try await
wireMVCScopeEntry.<field>.bind(name: …, request: request, pathParameters: pathParameters, body: …,
coding: …)`, where `<field>` is `scopeYieldFieldName(forType:)` of the worker's type. It SHALL NOT
spell `<Wrapper><<Type>>` and SHALL NOT read a field named after the wrapper. Ordinary bindings on the
same route SHALL keep the static form.

#### Scenario: a worker-backed parameter
- **WHEN** a scoped `Documents` controller declares `read(@AuthorizedDocument("read") document: Document)` and `AuthorizedDocument` names `DocumentAuthorizer`
- **THEN** the source contains `let document = try await wireMVCScopeEntry.documentAuthorizer.bind(name: "read", request: request, pathParameters: pathParameters, body: nil, ` and contains neither `AuthorizedDocument<Document>` nor `wireMVCScopeEntry.authorizedDocument`

#### Scenario: beside `@Path`
- **WHEN** the same route also declares `@Path id: String`
- **THEN** the source contains both `let id = try await Path<String>.bind(` and `let document = try await wireMVCScopeEntry.documentAuthorizer.bind(`

Pinned by: `Tests/WireMVCCodegenTests/GraphAwareBindingTests.swift` (`theBindingIsReadOffTheScopeEntryRatherThanConstructed`, `anOrdinaryBindingIsUnchanged`).

### Requirement: An optional worker-backed parameter uses the instance's `bindOptional`
For a worker-backed parameter whose type ends in `?`, the terminal SHALL call
`wireMVCScopeEntry.<field>.bindOptional(…)`, and for one with a default value it SHALL call
`bindOptional(…) ?? <default>`.

#### Scenario: an optional document
- **WHEN** the route declares `@AuthorizedDocument("read") document: Document?`
- **THEN** the source contains `wireMVCScopeEntry.documentAuthorizer.bindOptional(`

Pinned by: `Tests/WireMVCCodegenTests/GraphAwareBindingTests.swift` (`anOptionalParameterUsesTheInstancesOptionalForm`). The defaulted form is pinned by nothing yet.

### Requirement: The worker's bind runs after the scope entry that produces it
WireMVCRouteGen SHALL emit a worker-backed bind after `let wireMVCScopeEntry = try await
self._wireEnterScope(request)` in the same route.

#### Scenario: statement order
- **WHEN** the `Documents` witness is rendered
- **THEN** the scope-entry line ends before `wireMVCScopeEntry.documentAuthorizer.bind(` begins

Pinned by: `Tests/WireMVCCodegenTests/GraphAwareBindingTests.swift` (`theBindComesAfterTheScopeEntryThatProducesIt`).

### Requirement: A worker-backed binding on an unscoped controller is an error
When the worker's seed is known and the controller carries no `@Scoped(seed:)`, WireMVCRouteGen SHALL
report `scopedBindingOnUnscopedController` as an error at the parameter and not emit the route.

#### Scenario: a controller that enters no scope
- **WHEN** an unscoped `@Controller("/documents")` declares `read(@AuthorizedDocument("read") document: Document)` and `DocumentAuthorizer` is bound in `@Scoped(seed: HTTPRequest.self)`
- **THEN** the error is `'@AuthorizedDocument document' resolves through 'DocumentAuthorizer', which is bound in @Scoped(seed: HTTPRequest.self) — but this controller is not scoped, so its routes hold the controller directly and enter no scope, and there is nothing to construct 'DocumentAuthorizer' in. Mark the controller @Scoped(seed: HTTPRequest.self)`

Pinned by: `Tests/WireMVCCodegenTests/GraphAwareBindingTests.swift` (`aScopedBindingOnAnUnscopedControllerIsRefused`).

### Requirement: A worker bound in a sibling seed's scope is an error
When the worker's seed differs from the controller's `@Scoped(seed:)` type, WireMVCRouteGen SHALL report
`scopedBindingSeedMismatch` as an error at the parameter and not emit the route.

#### Scenario: a worker in another seeded scope
- **WHEN** a `@Scoped(seed: HTTPRequest.self)` controller uses `@AuthorizedDocument` and `DocumentAuthorizer` is bound in `@Scoped(seed: OtherSeed.self)`
- **THEN** the error is `'@AuthorizedDocument' resolves through 'DocumentAuthorizer', which is bound in @Scoped(seed: OtherSeed.self), but this controller is in @Scoped(seed: HTTPRequest.self) — sibling seeded scopes are isolated by design, so the controller's scope entry constructs only its own. Bind 'DocumentAuthorizer' in @Scoped(seed: HTTPRequest.self)`

Pinned by: `Tests/WireMVCCodegenTests/GraphAwareBindingTests.swift` (`aBindingFromASiblingSeedIsRefused`).

### Requirement: A worker-backed binding is exempt from the send-conformance warning
`bindingMissingSendConformance` SHALL NOT be reported for a binding that names a worker, while a binding
without a worker and without `RequestSendable` SHALL still be warned about in the same build.

#### Scenario: the graph-aware wrapper
- **WHEN** `@RequestBinding(DocumentAuthorizer.self) struct AuthorizedDocument` conforms to neither send protocol and a scoped route uses it
- **THEN** no diagnostic contains `does not conform to RequestSendable`

#### Scenario: the negative control
- **WHEN** a bare `@RequestBinding struct Ticket<Value>: RequestBound` is used and conforms to neither send protocol
- **THEN** a diagnostic contains `does not conform to RequestSendable`

Pinned by: `Tests/WireMVCCodegenTests/GraphAwareBindingTests.swift` (`theOmittedRouteIsNotAlsoNaggedAboutRequestSendable`, `anOrdinaryBindingIsStillNaggedAboutRequestSendable`).

## Related specifications

- [request-bindings](../request-bindings/spec.md)
- [streaming-request-bindings](../streaming-request-bindings/spec.md)
- [request-scope](../request-scope/spec.md)
- [controllers-and-routes](../controllers-and-routes/spec.md)
- [error-response-tiers](../error-response-tiers/spec.md)
- [middleware](../middleware/spec.md)
- [testing-harness](../testing-harness/spec.md)
- [swift-wire adapter-annotations](https://github.com/swift-wire/swift-wire/blob/main/openspec/specs/adapter-annotations/spec.md)
