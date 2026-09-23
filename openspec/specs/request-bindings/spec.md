# Request bindings

## Purpose

How a typed route's handler parameters are filled from the request. Every parameter carries a binding
attribute; WireMVC ships four (`@Path`, `@Query`, `@Header`, `@JSONBody`), each a property wrapper
conforming to `RequestBound` and declared with `@RequestBinding`, and WireMVCRouteGen emits one `bind`
call per parameter inside the route's terminal. This spec covers the built-ins, the `RequestBound`
contract, how a binding is recognised and named, the collected request body, and the
`WireMVCBindingError` statuses. Streaming bodies and graph-aware bindings are specified separately.

Rationale: [WireMVCDesign](../../../Documentation/Notes/WireMVCDesign.md), [ExtensibleBindingsAndResponses](../../../Documentation/Notes/ExtensibleBindingsAndResponses.md).
Documentation: [RequestBindings](../../../Sources/WireMVC/WireMVC.docc/RequestBindings.md).

## Requirements

### Requirement: The four built-in bindings declare their obligations with `@RequestBinding`
`Path<T>`, `Query<T>`, `Header<T>` and `JSONBody<T>` SHALL be unconstrained `@propertyWrapper` structs
declared `@RequestBinding(.path)`, `@RequestBinding`, `@RequestBinding` and `@RequestBinding(.body)`
respectively. `Path`, `Query` and `Header` SHALL conform to `RequestBound` where
`T: LosslessStringConvertible`, and `JSONBody` where `T: Decodable`. `Path`, `Query` and `Header` SHALL
offer `init(wrappedValue:_ name:)`; `JSONBody` SHALL offer only `init(wrappedValue:)`.

#### Scenario: the scan reads WireMVC's own declarations
- **WHEN** `scanRequestBindings` is run over `Sources/WireMVC/RequestBinding.swift`
- **THEN** it finds exactly four bindings: `Path` with `.path`, `JSONBody` with `.body`, and `Query` and `Header` with no obligation

Pinned by: `Tests/WireMVCCodegenTests/BindingObligationsTests.swift` (`theBuiltInsAreAnnotated`, `builtInsNeedNoSpecialCase`).

### Requirement: `RequestBound` is a static `bind` with a defaulted coding-aware overload
`RequestBound` SHALL have an associated type `Value` and one requirement,
`static func bind(name: String, request: HTTPRequest, pathParameters: [String: Substring], body: [UInt8]?) async throws -> Value`.
An extension SHALL supply `bind(name:request:pathParameters:body:coding:)` forwarding to it, and the
generated terminal SHALL call that coding-aware form as `<Wrapper><<Type>>.bind(…, coding: wireMVCAppCoding)`.
`JSONBody` SHALL override the coding-aware form to decode with the given `WireMVCCoding`.

#### Scenario: every parameter is bound through the coding-aware call
- **WHEN** a route declares `@Path scope: String` and `@JSONBody filter: Filter`
- **THEN** the terminal contains `let scope = try await Path<String>.bind(name: "scope", request: request, pathParameters: pathParameters, body: requestBody, coding: wireMVCAppCoding)` and the matching `JSONBody<Filter>.bind(…)` line

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`allParameterBindingShapes`).

### Requirement: A binding is recognised by its declaration, and an unrecognised parameter is an error
WireMVCRouteGen SHALL treat an attribute on a handler parameter as a binding exactly when a type of that
name carrying `@RequestBinding` is found in the parsed sources. A parameter of a typed route with no such
attribute SHALL be reported as `unannotatedParameter`, an error at the parameter, and the route SHALL
not be emitted.

#### Scenario: a parameter with no binding
- **WHEN** a `@Get("/x") @JSONResponse` route declares `func f(id: String) -> Int`
- **THEN** exactly one diagnostic is reported: `handler parameter 'id' needs a binding annotation — one of @Path, @Query, @JSONBody, @Header`

#### Scenario: a misspelled binding
- **WHEN** a route declares `@Pth id: String` and no `Pth` declaration carries `@RequestBinding`
- **THEN** the same "needs a binding annotation" error is reported rather than a binding call being emitted

#### Scenario: a type conforming to `RequestBound` without the attribute
- **WHEN** the sources declare `public struct NotABinding<V>: RequestBound {}` with no `@RequestBinding`
- **THEN** the scan does not record `NotABinding` as a binding

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`unannotatedParameterIsDiagnosed`), `Tests/WireMVCCodegenTests/BindingObligationsTests.swift` (`unknownIsStillDiagnosed`, `unannotatedIsNotABinding`, `recognised`).

### Requirement: The wire name is the attribute's string literal, else the parameter's label
WireMVCRouteGen SHALL pass as `name:` the binding attribute's first string-literal argument when it has
one, otherwise the parameter's external label, or its internal name when the external label is `_`.

#### Scenario: an override and an inferred name side by side
- **WHEN** a route declares `@Query("q") query: String` and `@Query limit: Int?`
- **THEN** the terminal binds `name: "q"` for `query` and `name: "limit"` for `limit`

#### Scenario: a path name override
- **WHEN** a route on `/users/{user_id}` declares `@Path("user_id") id: String`
- **THEN** the terminal binds `Path<String>.bind(name: "user_id", …)` and the handler is called with `id: id`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`allParameterBindingShapes`). The `@Path` override scenario is pinned by nothing yet.

### Requirement: `@Path`, `@Query` and `@Header` convert through `LosslessStringConvertible`
`Path`, `Query` and `Header` SHALL produce their value with `T(String(raw))`. An absent value SHALL throw
`missingPathParameter`, `missingQueryParameter` or `missingHeader` with the binding name, and a value the
initialiser rejects SHALL throw `pathParameterTypeMismatch`, `queryParameterTypeMismatch` or
`headerTypeMismatch` with the name and the raw text.

#### Scenario: a path segment that is not an `Int`
- **WHEN** a client requests `GET /pages/list/abc` on a route whose `{count}` is bound `@Path count: Int`
- **THEN** the response status is `400` and no page body is streamed

#### Scenario: a query value converts
- **WHEN** `GET /users?limit=3&cursor=c1` reaches a route binding `@Query limit: Int = 10`
- **THEN** the handler receives `limit == 3`

Pinned by: `Fixtures/Tests/WireMVCBootstrapExampleTests/HTMLResponseOverTheWireTests.swift` (`aBindingFailureStillMaps`), `Fixtures/Sources/WireMVCExample/main.swift` (the `GET /users?limit=3&cursor=c1` check, run by the `Run end-to-end example` step of the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: An optional or defaulted parameter binds through `bindOptional`
For a parameter whose type ends in `?`, the terminal SHALL call `bindOptional` on the wrapper
specialised to the non-optional type. For a parameter with a default value, it SHALL call
`bindOptional(…) ?? <default>`. `bindOptional` SHALL return `nil` when `bind` throws
`missingPathParameter`, `missingQueryParameter` or `missingHeader`, and SHALL rethrow every other error.

#### Scenario: the emitted forms
- **WHEN** a route declares `@Query limit: Int?` and `@Header("X-Trace") trace: String = "none"`
- **THEN** the terminal contains `Query<Int>.bindOptional(name: "limit", …)` and `Header<String>.bindOptional(name: "X-Trace", …) ?? "none"`

#### Scenario: absent values over HTTP
- **WHEN** `GET /users` reaches `list(@Query limit: Int = 10, @Query cursor: String?, @Header("x-trace") trace: String?)` with no query and no `x-trace`
- **THEN** the handler receives `limit == 10`, `cursor == nil` and `trace == nil`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`allParameterBindingShapes`), `Fixtures/Sources/WireMVCExample/main.swift` (the `GET /users` checks, run by the `Run end-to-end example` step of the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: `WireMVCBindingError` carries its status and every bound route maps it
`WireMVCBindingError.status` SHALL be `.badRequest` (400) for `missingPathParameter`,
`pathParameterTypeMismatch`, `missingQueryParameter`, `queryParameterTypeMismatch`, `missingHeader` and
`headerTypeMismatch`; `.unsupportedMediaType` (415) for `unsupportedMediaType`; and
`.unprocessableContent` (422) for `malformedBody`. The `errorMapping` of every route that has at least
one binding SHALL include `(wireMVCError as? WireMVCBindingError).map { WireMVCOutcome.status($0.status) }`.

#### Scenario: the built-in mapping is emitted
- **WHEN** WireMVCRouteGen renders a route with any binding
- **THEN** its `errorMapping` chains the `WireMVCBindingError` status mapping ahead of `WireMVCOutcome.status(.internalServerError)`

#### Scenario: a route with no bindings
- **WHEN** a route takes no parameters
- **THEN** its `errorMapping` does not mention `WireMVCBindingError`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`allParameterBindingShapes`, `noBindsRouteGainsCatchForErrorResponse`).

### Requirement: `@JSONBody` rejects a contradictory `Content-Type` and a malformed body
`JSONBody.bind` SHALL throw `unsupportedMediaType` when the request has a `Content-Type` that does not
begin with `application/json`, SHALL attempt the decode when the request has no `Content-Type`, and SHALL
throw `malformedBody` when the body is `nil` or the decoder throws.

#### Scenario: a text body
- **WHEN** `POST /users` is sent with `Content-Type: text/plain` and body `nope`
- **THEN** the response status is `415`

#### Scenario: malformed JSON
- **WHEN** `POST /users` is sent with `Content-Type: application/json` and body `{bad`
- **THEN** the response status is `422`

#### Scenario: no `Content-Type`
- **WHEN** a `@JSONBody` route receives a well-formed JSON body with no `Content-Type` header
- **THEN** the body is decoded and the handler runs

Pinned by: `Fixtures/Sources/WireMVCExample/main.swift` (the `POST wrong Content-Type` and `POST malformed JSON` checks, run by the `Run end-to-end example` step of the `BuildAndRun` job in `.github/workflows/build.yml`). The missing-`Content-Type` scenario is pinned by nothing yet.

### Requirement: A `.path` binding needs a matching placeholder, which a catch-all provides
For a parameter whose binding declares the `.path` obligation, WireMVCRouteGen SHALL require the joined
route path to contain `{<name>}` or `{<name>*}`, and otherwise SHALL report `pathPlaceholderMissing` as an
error at the parameter. A binding without `.path` SHALL NOT be checked against the template.

#### Scenario: no placeholder
- **WHEN** `@Controller("/users")` declares `@Get @JSONResponse func f(@Path id: String) -> Int`
- **THEN** the diagnostic is `@Path 'id' has no matching '{id}' placeholder in the route path "/users"`

#### Scenario: a catch-all placeholder
- **WHEN** `@Controller("/files")` declares `@Get("/{path*}") @JSONResponse func serve(@Path path: String)`
- **THEN** no error is reported

#### Scenario: a binding declared outside WireMVC with `.path`
- **WHEN** `@RequestBinding(.path) struct Slug` is used as `@Slug name: String` on `@Get("/{id}")`
- **THEN** the diagnostics include `no matching '{name}' placeholder`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`pathPlaceholderMismatchIsDiagnosed`), `Tests/WireMVCCodegenTests/BindingObligationsTests.swift` (`catchAllTemplateIsNotDiagnosed`, `userPathBindingMissingPlaceholder`, `userPathBindingWithPlaceholder`, `noObligationNoPlaceholderCheck`).

### Requirement: Binding runs inside the terminal's `building` closure, after scope entry
WireMVCRouteGen SHALL emit every `bind` call inside the terminal's `building` closure, so a binding
failure reaches that route's `errorMapping`. On a `@Scoped(seed:)` controller the binds SHALL follow
`let wireMVCScopeEntry = try await self._wireEnterScope(request)`.

#### Scenario: a scoped controller with a mapped error
- **WHEN** a `@Scoped(seed: HTTPRequest.self)` controller carries `@ErrorResponse(Unauthenticated.self, .unauthorized)`
- **THEN** `building: {` precedes the scope-entry line in the rendered witness

#### Scenario: a scoped controller binds over HTTP
- **WHEN** `POST /scoped-pages/digest` reaches a scoped controller's route with a body binding
- **THEN** the response is `200` and carries both the scope-entered controller's injected value and the bound value

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`scopedControllerScopeEntryInsideDoWhenMapped`), `Tests/WireMVCCodegenTests/GraphAwareBindingTests.swift` (`theBindComesAfterTheScopeEntryThatProducesIt`), `Fixtures/Tests/WireMVCBootstrapExampleTests/StreamingRequestTests.swift` (`streamedResponseOnScopedController`).

### Requirement: The body is collected once, and only when a binding declares `.body`
When any parameter's binding declares `.body`, the terminal SHALL be called with
`collectingBodyFrom: reader`, its `building` closure SHALL take `requestBody`, and every binding on the
route SHALL be passed `body: requestBody`. A route with no `.body` binding SHALL collect nothing, SHALL
pass `body: nil`, and SHALL name the register closure's reader parameter `_` unless a streaming binding
needs it.

#### Scenario: a route with a body binding
- **WHEN** a route declares `@JSONBody filter: Filter` beside `@Path` and `@Query` parameters
- **THEN** the terminal carries `collectingBodyFrom: reader` and `building: { requestBody in`, and every bind passes `body: requestBody`

#### Scenario: a route without one
- **WHEN** `@Get("/{id}") @JSONResponse func get(@Path id: String)` is rendered
- **THEN** the register closure's fourth parameter is `_` and the bind passes `body: nil`

#### Scenario: a user binding with `.body`
- **WHEN** `@RequestBinding(.body) struct FormBody` is used as `@FormBody input: Login`
- **THEN** the route carries `collectingBodyFrom: reader` and binds with `body: requestBody`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`allParameterBindingShapes`, `plainJSONRouteWithPathBinding`), `Tests/WireMVCCodegenTests/BindingObligationsTests.swift` (`collectsTheBody`, `noObligationNoCollection`, `userBodyBindingOnAStreamingRoute`).

### Requirement: `WireMVCRequest.collectBody` caps the body and reports any failure as `malformedBody`
`WireMVCRequest.collectBody(_:maximumSize:)` SHALL consume the reader into a `[UInt8]` with a default
`maximumSize` of `1_000_000`, and SHALL throw `WireMVCBindingError.malformedBody` when the collect throws
for any reason, including exceeding the maximum. The generated collecting terminals SHALL call it with
the default maximum.

#### Scenario: an oversized collected body
- **WHEN** a `@JSONBody` route receives a body longer than 1,000,000 bytes
- **THEN** the collect fails, `malformedBody` is thrown, and the route answers `422`

Pinned by: nothing yet.

### Requirement: `@Query` parses the query string itself and percent-decodes the value
`Query.bind` SHALL take the text after the first `?` of `request.path`, split it on `&`, split each pair on
its first `=`, and use the first pair whose undecoded key equals the binding name. A pair with no `=`
SHALL yield the empty string. The value SHALL be percent-decoded without Foundation: each `%XX` with two
hex digits becomes that byte, any other `%` passes through unchanged, and the bytes are decoded as UTF-8.

#### Scenario: an encoded value
- **WHEN** a route binding `@Query q: String` receives `?q=a%20b`
- **THEN** the handler receives `"a b"`

#### Scenario: a malformed escape
- **WHEN** it receives `?q=100%`
- **THEN** the handler receives `"100%"`

Pinned by: nothing yet.

### Requirement: `@Header` reads one field by name
`Header.bind` SHALL look the binding name up with `HTTPField.Name(name)` in `request.headerFields`, and
SHALL throw `missingHeader` when the name is not a valid field name or the field is absent.

#### Scenario: an optional header present
- **WHEN** `GET /users?limit=3&cursor=c1` is sent with `x-trace: abc` to a route binding `@Header("x-trace") trace: String?`
- **THEN** the handler receives `trace == "abc"`

Pinned by: `Fixtures/Sources/WireMVCExample/main.swift` (the `GET /users?limit=3&cursor=c1 (+x-trace)` check, run by the `Run end-to-end example` step of the `BuildAndRun` job in `.github/workflows/build.yml`).

## Related specifications

- [streaming-request-bindings](../streaming-request-bindings/spec.md)
- [graph-aware-bindings](../graph-aware-bindings/spec.md)
- [controllers-and-routes](../controllers-and-routes/spec.md)
- [request-scope](../request-scope/spec.md)
- [responses-and-modes](../responses-and-modes/spec.md)
- [error-response-tiers](../error-response-tiers/spec.md)
- [middleware](../middleware/spec.md)
- [route-builder-contract](../route-builder-contract/spec.md)
- [testing-harness](../testing-harness/spec.md)
