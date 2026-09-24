# Responses and response modes

## Purpose

How a typed route's return value becomes an HTTP response, and how a `@RawRoute` handler writes its
own. A response mode is a pair of a terminal (`buffered`, `streaming` or `bodiless`) and a codec,
declared with `@ResponseMode` on the macro declaration of the annotation that names it; the built-in
`@JSONResponse`, `@HTMLResponse` and `@ResponseStatus` are instances of that seam, and a mode declared
outside WireMVC is read the same way. This capability covers the declaration scan, the codegen rules
and diagnostics for response annotations and labelled response tuples, the `WireMVCOutcome` and
`WireMVCStreamingOutcome` values, the generated terminals, `Content-Type` and `Content-Length`
handling, and `@RawRoute` parameter binding.

Rationale: [ExtensibleBindingsAndResponses](../../../Documentation/Notes/ExtensibleBindingsAndResponses.md), [StreamingResponseTier](../../../Documentation/Notes/StreamingResponseTier.md), [WireMVCDesign](../../../Documentation/Notes/WireMVCDesign.md), [DecompositionTransformers](../../../Proposals/DecompositionTransformers.md).
Documentation: [ResponsesAndHeaders](../../../Sources/WireMVC/WireMVC.docc/ResponsesAndHeaders.md).

## Requirements

### Requirement: A response mode is declared by `@ResponseMode` on a macro declaration
`@ResponseMode(_ terminal: WireMVCResponseTerminal, codec: String? = nil, client:
WireMVCResponseClientBody = .decoded)` SHALL be an attached peer macro placed on another macro's
declaration. `scanResponseModes(in:)` SHALL walk every parsed file, nested declarations included, and
record a `DeclaredResponseMode` keyed by the annotated macro's bare name, reading the unlabelled
argument's trailing member name as the terminal, the `codec:` string literal's value as the codec
spelling, and `client:`'s trailing member name as the client body. A macro without `@ResponseMode`, or
one whose terminal is not `buffered`, `streaming` or `bodiless`, SHALL yield no entry.

#### Scenario: a mode declared in another file
- **WHEN** one file declares `@ResponseMode(.buffered, codec: "YAMLCodec") public macro YAMLResponse()` and another file's route uses `@YAMLResponse`
- **THEN** the scan returns `YAMLResponse` with terminal `.buffered` and codec `YAMLCodec`, without the quotes

#### Scenario: a qualified terminal
- **WHEN** a declaration is written `@ResponseMode(WireMVCResponseTerminal.streaming, codec: "P", client: WireMVCResponseClientBody.text)`
- **THEN** the scan records terminal `.streaming`, codec `P` and client body `.text`

#### Scenario: an unknown terminal
- **WHEN** a declaration is written `@ResponseMode(.trailered, codec: "C")`
- **THEN** the scan records nothing for it

Pinned by: `Tests/WireMVCCodegenTests/ResponseModeScanTests.swift` (`acrossFiles`, `readsEachField`, `overloadsAgree`, `codecIsUnquoted`, `qualifiedTerminal`, `unannotatedMacroIgnored`, `unknownTerminalIgnored`).

### Requirement: The built-in modes are ordinary `@ResponseMode` declarations
WireMVC SHALL declare `@JSONResponse()` and `@JSONResponse(status:)` with
`@ResponseMode(.buffered, codec: "WireMVCJSONCodec")`, `@HTMLResponse()` and `@HTMLResponse(status:)`
with `@ResponseMode(.streaming, codec: "WireMVCHTMLProducer", client: .text)`, and
`@ResponseStatus(_ status:)` with `@ResponseMode(.bodiless)`, each backed by
`RouteMarkerMacro`, which expands to nothing. `WireMVCJSONCodec<Value>` SHALL conform to
`WireMVCResponseEncoding` where `Value: Encodable`, returning the encoder's bytes with content type
`application/json`, and to `WireMVCResponseDecoding` where `Value: Decodable`.

#### Scenario: a JSON route uses the declared codec
- **WHEN** `@Get("/{id}") @JSONResponse func get(@Path id: String) async throws -> Todo` is generated
- **THEN** the `building` closure returns `WireMVCResponse.encoded(try WireMVCJSONCodec.encodeResponseBody(try await self._wireSubject.get(id: id), coding: wireMVCAppCoding), status: .ok)`

#### Scenario: an HTML route uses the declared producer
- **WHEN** `@Get("/home") @HTMLResponse func home() async throws -> some HTML` is generated
- **THEN** the witness calls `wireMVCStreamingTerminal(` with `producer: WireMVCHTMLProducer(try await self._wireSubject.home())`

Pinned by: `Tests/WireMVCCodegenTests/WireMVCBuiltIns.swift` (the modes are scanned from `Sources/WireMVC/Macros.swift`), `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`plainJSONRouteWithPathBinding`), `Tests/WireMVCCodegenTests/HTMLResponseGenerationTests.swift` (`plainRoute`, `jsonUnchanged`).

### Requirement: A mode declared outside WireMVC is generated like a built-in
A macro declared in a consuming module with `@ResponseMode` and backed by
`#externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")`, which `WireMVCMacrosPlugin`
provides, SHALL be recognised as a response annotation. Its route SHALL be registered in the witness
and SHALL appear in the typed client, emitting `<codec>.encodeResponseBody(…)` for a `.buffered` mode,
`producer: <codec>(…)` for a `.streaming` mode, and `.status(<status>)` for a `.bodiless` mode whose
status is read from either an unlabelled first argument or a `status:` argument.

#### Scenario: one mode of each terminal
- **WHEN** a module declares `@CSVResponse` (buffered, `CSVCodec`), `@EventStream` (streaming, `SSEProducer`, `.text`), `@NoContent(_:)` and `@Accepted(status:)` (both bodiless) and uses each on a route
- **THEN** there are no diagnostics, the witness contains `try CSVCodec.encodeResponseBody(try await self._wireSubject.ledger()`, `producer: SSEProducer(try await self._wireSubject.events())`, `return .status(.noContent` and `return .status(.accepted`, and the client contains `try CSVCodec<Ledger>.decodeResponseBody(`

#### Scenario: over the wire
- **WHEN** the fixture's `@CSVResponse` route `GET /pages/ledger` is requested
- **THEN** the response is `200` with `Content-Type: text/csv; charset=utf-8` and the typed client's `ledger()` decodes a `Ledger` through `CSVCodec`

Pinned by: `Tests/WireMVCCodegenTests/ResponseModeScanTests.swift` (`everyModeReachesTheWitness`, `everyModeReachesTheClient`, `eachTerminalEmitsItsOwnShape`), `Fixtures/Tests/WireMVCBootstrapExampleTests/UserDeclaredResponseModeTests.swift` (`servesTheCodecsBytesAndContentType`, `theTypedClientDecodesThroughTheMode`, `aUserModeCarriesAnAnnotatedStatus`, `theBuiltInModesStillBehaveAsBefore`).

### Requirement: A route carries at most one response annotation
WireMVCRouteGen SHALL report `multipleResponseAnnotations` and emit no registration for a route that
carries more than one annotation with a discovered `@ResponseMode`.

#### Scenario: two annotations
- **WHEN** a route `home` carries both `@HTMLResponse` and `@JSONResponse`
- **THEN** the diagnostic is "route 'home' carries more than one response annotation (@HTMLResponse, @JSONResponse) — a route states its response mode exactly once"

Pinned by: `Tests/WireMVCCodegenTests/HTMLResponseGenerationTests.swift` (`duplicateAnnotations`).

### Requirement: A route with no response annotation and no self-describing return is diagnosed
WireMVCRouteGen SHALL report `missingResponseAnnotation` for a typed route that has no response
annotation and whose return type is not a bodiless `(status:headers:)` tuple.

#### Scenario: an unannotated Void route
- **WHEN** a route `ping` is declared `@Get("/ping") func ping() async throws` with no response annotation
- **THEN** the diagnostic is "route 'ping' needs exactly one response annotation — @JSONResponse or @HTMLResponse (returns a body), @ResponseStatus (Void), or any mode declared with @ResponseMode"

Pinned by: nothing yet.

### Requirement: A body-carrying mode requires a returned value
WireMVCRouteGen SHALL report `responseModeOnVoid` for a `.buffered` or `.streaming` mode on a route
whose return shape has no body.

#### Scenario: `@HTMLResponse` on a Void handler
- **WHEN** `@Get("/ping") @HTMLResponse func ping() async throws {}` is generated
- **THEN** the diagnostic is "@HTMLResponse on 'ping' requires a returned value; use @ResponseStatus for a Void handler"

Pinned by: `Tests/WireMVCCodegenTests/HTMLResponseGenerationTests.swift` (`htmlOnVoid`).

### Requirement: A bodiless mode requires a Void handler and a status
For a `.bodiless` mode WireMVCRouteGen SHALL read the status from a `status:` argument or, failing
that, an unlabelled first argument, and SHALL report `bodilessModeNeedsStatus` when neither is present.
It SHALL report `responseStatusOnValue` when the route's return shape carries a body. A valid route
SHALL return `.status(<status>)` from `building`.

#### Scenario: a bodiless mode with no status
- **WHEN** `@ResponseMode(.bodiless) macro Done()` is declared and a route `remove` carries `@Done`
- **THEN** the diagnostic is "@Done on 'remove' names no status — a bodiless mode carries nothing but one, so it must say which. Write it as @Done(.noContent) or @Done(status: .noContent)"

#### Scenario: `@ResponseStatus` on a value
- **WHEN** a route `get` carries `@ResponseStatus(.ok)` and returns `Thing`
- **THEN** the diagnostic is "@ResponseStatus on 'get' requires a Void handler; use @JSONResponse to encode the returned value"

Pinned by: `Tests/WireMVCCodegenTests/ResponseModeScanTests.swift` (`bodilessWithoutStatusIsDiagnosed`, `eachTerminalEmitsItsOwnShape`), `Tests/WireMVCCodegenTests/ResponseHeaderGenerationTests.swift` (`responseStatusRouteCarriesStaticHeaders`). The `responseStatusOnValue` scenario is pinned by nothing yet.

### Requirement: A body-carrying mode must name a codec
WireMVCRouteGen SHALL report `responseModeMissingCodec` for a `.buffered` or `.streaming` mode whose
`@ResponseMode` declaration has no `codec:`.

#### Scenario: a buffered mode without a codec
- **WHEN** `@ResponseMode(.buffered) macro Plain()` is declared and a route `data` carries `@Plain`
- **THEN** the diagnostic is "@Plain on 'data' declares no codec — its @ResponseMode must name one, since a mode that encodes a body has to say what encodes it"

Pinned by: nothing yet.

### Requirement: The annotated status defaults to `.ok`
For a `.buffered` or `.streaming` mode the status SHALL be the annotation's `status:` argument, or
`.ok` when the annotation is written bare, unless the response tuple returns a status.

#### Scenario: an annotated status
- **WHEN** a route carries `@HTMLResponse(status: .notFound)`
- **THEN** the emitted outcome contains `status: .notFound`

#### Scenario: a headers-only tuple keeps the annotation's status
- **WHEN** `@Post("/") @JSONResponse(status: .created) func make() async throws -> (headers: HTTPFields, body: Thing)` is generated
- **THEN** the outcome uses `status: .created` and `returned: wireMVCReturn.headers`

Pinned by: `Tests/WireMVCCodegenTests/HTMLResponseGenerationTests.swift` (`annotatedStatus`), `Tests/WireMVCCodegenTests/ResponseHeaderGenerationTests.swift` (`headersOnlyTupleKeepsTheAnnotatedStatus`).

### Requirement: A labelled response tuple names status, headers and body
WireMVCRouteGen SHALL read a return type as a response tuple only when at least one element label is
`status`, `headers` or `body`, and SHALL then accept exactly the label lists `(headers:body:)`,
`(status:body:)`, `(status:headers:body:)` and `(status:headers:)`, binding the return to
`wireMVCReturn` and projecting `wireMVCReturn.status`, `wireMVCReturn.headers` and
`wireMVCReturn.body`. Any other label list containing one of those labels SHALL be reported as
`responseTupleInvalidLabels`. A tuple with none of those labels SHALL be encoded as the body.

#### Scenario: the full tuple
- **WHEN** a `@JSONResponse` route returns `(status: HTTPResponse.Status, headers: HTTPFields, body: Thing)`
- **THEN** the witness binds `let wireMVCReturn = try await self._wireSubject.get(id: id)`, encodes `wireMVCReturn.body`, and passes `status: wireMVCReturn.status`

#### Scenario: a misspelled label
- **WHEN** a route `get` returns `(status: HTTPResponse.Status, header: HTTPFields)`
- **THEN** the diagnostic is "the response tuple returned by 'get' is labelled (status, header), which is not a response shape — write one of (headers:body:), (status:body:), (status:headers:body:), or (status:headers:) for a bodiless response. Returning a payload that is genuinely a tuple? Leave its elements unlabelled and it stays the body."

#### Scenario: an unlabelled tuple
- **WHEN** a `@JSONResponse` route returns `(Int, String)`
- **THEN** the witness encodes `try await self._wireSubject.pair()` directly and binds no `wireMVCReturn`

Pinned by: `Tests/WireMVCCodegenTests/ResponseHeaderGenerationTests.swift` (`fullResponseTupleProjectsEveryElement`, `invalidResponseTupleLabelsAreDiagnosed`, `unlabelledTupleStaysABody`), `Tests/WireMVCCodegenTests/HTMLResponseGenerationTests.swift` (`responseTuple`).

### Requirement: A bodiless `(status:headers:)` tuple takes no response annotation
A route returning `(status:headers:)` SHALL be generated with no response annotation as
`return .status(wireMVCReturn.status, headerFields: …)`. Writing any response annotation on it SHALL
be reported as `responseAnnotationOnSelfDescribingReturn`.

#### Scenario: a computed redirect
- **WHEN** `@Get("/moved") func moved() async throws -> (status: HTTPResponse.Status, headers: HTTPFields)` is generated
- **THEN** the witness contains `return .status(wireMVCReturn.status, headerFields: WireMVCResponseHeaders.resolved(returned: wireMVCReturn.headers))` and there are no diagnostics

#### Scenario: an annotation on the self-describing return
- **WHEN** the same route also carries `@ResponseStatus(.found)`
- **THEN** the diagnostic is "@ResponseStatus on 'moved' declares nothing the return type does not already say — a (status:headers:) tuple carries no body and computes its own status, so the annotation would be read by nobody and could only go out of date. Remove it. (A route that returns a body still needs @JSONResponse: that names the codec.)"

Pinned by: `Tests/WireMVCCodegenTests/ResponseHeaderGenerationTests.swift` (`bodilessTupleEmitsAStatusOutcomeWithNoAnnotation`, `annotatingASelfDescribingReturnIsDiagnosed`, `clientStillGeneratesForABodilessTuple`), `Fixtures/Tests/WireMVCBootstrapExampleTests/WithTestServerTests.swift` (`bodilessTupleRedirectsToTheComputedLocation`).

### Requirement: A returned status makes an explicit `status:` argument an error
When the response tuple includes `status`, WireMVCRouteGen SHALL report `deadResponseStatusArgument`
if the route's mode annotation carries a `status:` argument, and SHALL accept the bare annotation.

#### Scenario: an annotated status beside a returned one
- **WHEN** a route `make` carries `@JSONResponse(status: .created)` and returns `(status: HTTPResponse.Status, body: Thing)`
- **THEN** the diagnostic is "the status on @JSONResponse(status:) for 'make' is never used — the response tuple returns a status, and a returned status wins. Drop the argument and keep the bare @JSONResponse, which is what names the response mode."

#### Scenario: the bare annotation
- **WHEN** the same route carries bare `@JSONResponse`
- **THEN** there are no diagnostics and the outcome uses `status: wireMVCReturn.status`

Pinned by: `Tests/WireMVCCodegenTests/ResponseHeaderGenerationTests.swift` (`annotatedStatusBesideAReturnedStatusIsDiagnosed`, `bareJSONResponseBesideAReturnedStatusIsAccepted`), `Tests/WireMVCCodegenTests/HTMLResponseGenerationTests.swift` (`deadStatusArgument`).

### Requirement: `WireMVCOutcome` is a status, header fields and an optional body
`WireMVCOutcome` SHALL be a `Sendable` struct with `status: HTTPResponse.Status`, `headerFields:
HTTPFields` and `body: [UInt8]?`. `WireMVCOutcome.status(_:headerFields:)` SHALL build a bodiless
outcome and `WireMVCOutcome.body(_:_:headerFields:)` an outcome with the given bytes, neither seeding
any field.

#### Scenario: a bodiless outcome with a challenge
- **WHEN** `WireMVCOutcome.status(.unauthorized, headerFields: [.wwwAuthenticate: #"Bearer realm="api""#])` is sent
- **THEN** the head is `401` with that `WWW-Authenticate` and the body is empty

#### Scenario: raw bytes
- **WHEN** `WireMVCOutcome.body(Array("plain".utf8), .internalServerError)` is built
- **THEN** its `headerFields` is empty

Pinned by: `Tests/WireMVCResponsesTests/ResponsesTests.swift` (`statusCarriesHeaderFields`, `rawBodySeedsNoContentType`, `legacyFactorySpellingsStillConstruct`).

### Requirement: `Content-Type` is seeded only when absent
`WireMVCOutcome.json(_:status:headerFields:coding:)` and `WireMVCResponse.json` SHALL set
`Content-Type: application/json` unless `headerFields` already has a `Content-Type`.
`WireMVCResponse.encoded(_:status:headerFields:)` SHALL set the codec's returned content type unless
`headerFields` already has one. The buffered emission SHALL go through `WireMVCResponse.encoded` for
every `.buffered` mode.

#### Scenario: the JSON default
- **WHEN** `WireMVCOutcome.json(Payload(name: "wire"))` is sent
- **THEN** the head carries `Content-Type: application/json` and status `200`

#### Scenario: an explicit content type wins
- **WHEN** `WireMVCOutcome.json` is given `headerFields: [.contentType: "application/problem+json"]`
- **THEN** the outcome has exactly one `Content-Type`, `application/problem+json`

Pinned by: `Tests/WireMVCResponsesTests/ResponsesTests.swift` (`jsonSeedsContentType`, `explicitContentTypeOverridesTheDefault`, `jsonCarriesCallerFieldsBesideTheDefault`), `Fixtures/Tests/WireMVCBootstrapExampleTests/UserDeclaredResponseModeTests.swift` (`servesTheCodecsBytesAndContentType`), `Fixtures/Tests/WireMVCBootstrapExampleTests/WithTestServerTests.swift` (`routeConstantsShipWithoutMiddleware`). A route header overriding a codec's content type through `WireMVCResponse.encoded` is pinned by nothing yet.

### Requirement: `stateLengthIfAbsent` states `Content-Length` where the status permits
`HTTPResponse.stateLengthIfAbsent(_ length: Int)` SHALL set `Content-Length` to `length` unless the
field is already present or the status is informational (`1xx`), `204` or `304`.
`WireMVCOutcome.send(on:)` SHALL call it with the body's byte count, or `0` when there is no body, on
the response it builds, without modifying the outcome.

#### Scenario: a body states its byte length
- **WHEN** `WireMVCOutcome.body(Array("héllo→".utf8), .ok)` is sent
- **THEN** the head carries `Content-Length: 9`

#### Scenario: a bodiless 404
- **WHEN** `WireMVCOutcome.status(.notFound)` is sent
- **THEN** the head carries `Content-Length: 0`

#### Scenario: statuses that forbid a length
- **WHEN** `WireMVCOutcome.status` is sent with `.continue`, `.noContent` or `.notModified`
- **THEN** the head carries no `Content-Length`

#### Scenario: an explicit length
- **WHEN** an outcome with `headerFields: [.contentLength: "99"]` and a five-byte body is sent
- **THEN** the head carries `Content-Length: 99`

Pinned by: `Tests/WireMVCResponsesTests/ResponsesTests.swift` (`bodyStatesItsLength`, `lengthCountsBytesNotCharacters`, `jsonStatesItsLengthBesideItsType`, `bodilessResponseStatesZero`, `statusesThatForbidALengthGetNone`, `explicitLengthIsNotOverwritten`, `sendingDoesNotMutateTheOutcome`), `Fixtures/Tests/StreamingTierTests/TierTests.swift` (`bufferedUnchanged`).

### Requirement: A buffered outcome reaches the sender's own `sendAndFinish`
`WireMVCOutcome.send(on:)` SHALL send an outcome with a body through
`sendAndFinish(_:buffer:trailer: nil)`, spelled with three arguments, and a bodiless outcome through
the one-argument `sendAndFinish(_:)`, so that both reach the conformer's own witness rather than
`send` followed by `finish`.

#### Scenario: a sender that distinguishes the paths
- **WHEN** `WireMVCOutcome.body(Array("plain".utf8), .ok)` is sent on a sender recording which entry point was used
- **THEN** the fused `sendAndFinish` witness was reached and `send` was not called

Pinned by: `Tests/WireMVCResponsesTests/ResponsesTests.swift` (`bufferedOutcomeReachesTheSendersOwnWitness`, `bodilessOutcomeReachesTheSendersOwnWitness`).

### Requirement: Every typed route ends in a generated terminal with three overloads
Each typed route SHALL call `wireMVCBufferedTerminal` (for `.buffered` and `.bodiless` modes and
bodiless tuples) or `wireMVCStreamingTerminal` (for `.streaming` modes) with `responseSender:`,
`responseHeaders:`, `building:` and `errorMapping:`. Each terminal SHALL have three overloads: a plain
one whose `building` takes no argument, a `collectingBodyFrom:` one that collects the request body and
passes it to `building` as `[UInt8]`, and a `lendingBodyFrom:` one that passes the reader to
`building` as a consuming parameter. The generator SHALL choose `collectingBodyFrom: reader` for a
collected body, `lendingBodyFrom: reader` for a reader-body binding, and the plain overload otherwise.

#### Scenario: a streaming route with a JSON body
- **WHEN** `@Post("/preview") @HTMLResponse func preview(@JSONBody input: Draft) async throws -> some HTML` is generated
- **THEN** the witness passes `collectingBodyFrom: reader`, opens `building: { requestBody in`, and emits no inline `WireMVCRequest.collectBody(`

#### Scenario: a reader-body binding on a streaming route
- **WHEN** a streaming route binds a `@RequestBinding(.readerBody)` parameter
- **THEN** the witness passes `lendingBodyFrom: reader,`

Pinned by: `Tests/WireMVCCodegenTests/HTMLResponseGenerationTests.swift` (`bodyBindingUsesTheCollectingOverload`, `noBodyNoCollectingOverload`, `jsonUnchanged`, `readerBodyCombinesWithStreamingResponse`), `Tests/WireMVCCodegenTests/BindingObligationsTests.swift` (`reducedBodyOnStreamingResponseAllowed`), `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`plainJSONRouteWithPathBinding`).

### Requirement: A failure before the head maps through `errorMapping`
The terminal SHALL run `building` (body collection, parameter binding, scope entry, the handler call
and the encode) inside one `do`/`catch`, and SHALL send the outcome `errorMapping` returns for a thrown
error as a buffered `WireMVCOutcome`, consuming the sender once after the result is known.

#### Scenario: a handler throws before a stream starts
- **WHEN** a streaming terminal's `building` throws and `errorMapping` returns `.status(.notFound)`
- **THEN** the sender records one head `404` with `Content-Length: 0` and a finish, and no chunks

#### Scenario: a binding failure on an HTML route
- **WHEN** `GET /pages/list/abc` is requested and `{count}` binds an `Int`
- **THEN** the response is `400` and no page is streamed

Pinned by: `Fixtures/Tests/StreamingTierTests/TierTests.swift` (`handlerFailureMapsNormally`), `Fixtures/Tests/WireMVCBootstrapExampleTests/HTMLResponseOverTheWireTests.swift` (`aBindingFailureStillMaps`, `aHandlerThrowMapsThroughErrorResponse`), `Tests/WireMVCCodegenTests/HTMLResponseGenerationTests.swift` (`bindingsInsideBuilding`, `decodeStaysMapped`).

### Requirement: A streaming outcome sends the head, then hands the writer to the producer
`WireMVCStreamingOutcome<Producer: WireMVCBodyProducer>` SHALL carry `status`, `headerFields`,
`producer` and `trailer: HTTPFields?`. Its `send(on:)` SHALL set `Content-Type` from
`producer.contentType` when the fields have none and the producer names one, call `sender.send` with
the head, and then call `producer.writeBody(into:terminatedBy: trailer)` with the returned writer. It
SHALL NOT set `Content-Length`.

#### Scenario: chunks after the head
- **WHEN** a producer writes `<html>`, `<body>`, `hi`, `</body></html>` through the streaming terminal
- **THEN** the sender records the head first, then four separate chunks, then a finish with no trailer

#### Scenario: the head precedes completion
- **WHEN** a producer writes one chunk and then waits on a gate
- **THEN** the head and the first chunk are recorded while the response is not yet finished

#### Scenario: a large page over the wire
- **WHEN** `GET /pages/list/400` is served
- **THEN** the response is `200` with no `Content-Length` and the whole page arrives

Pinned by: `Fixtures/Tests/StreamingTierTests/TierTests.swift` (`incrementalWrites`, `headPrecedesCompletion`, `trailers`), `Fixtures/Tests/WireMVCBootstrapExampleTests/HTMLResponseOverTheWireTests.swift` (`aLargePageIsNotLengthPrefixed`, `aSmallPageIsAlsoStreamed`), `Tests/WireMVCResponsesTests/ResponsesTests.swift` (`aSucceedingDrainReachesTheStreamedHead`). A route's own `Content-Type` beating the producer's at send time is pinned by nothing yet.

### Requirement: A failure after the head aborts the response
A throw from `writeBody` SHALL propagate out of the terminal without calling `errorMapping`, and the
writer SHALL be dropped without `finish`.

#### Scenario: a mid-body failure
- **WHEN** a producer writes `<html>` and `<p>ok</p>` and then throws `BoomError`
- **THEN** the terminal throws `BoomError`, the recorded head is `200`, both chunks were written, the response is aborted, and no finish is recorded

Pinned by: `Fixtures/Tests/StreamingTierTests/TierTests.swift` (`midBodyFailureAborts`).

### Requirement: `WireMVCBodyProducer` requires no `Sendable`
`WireMVCBodyProducer` SHALL require only `var contentType: String? { get }`, defaulted to `nil` by a
protocol extension, and `consuming func writeBody<W: CallerAsyncWriter & ~Copyable &
~Escapable>(into:terminatedBy:) async throws`, and SHALL NOT refine `Sendable`.

#### Scenario: a producer holding a class instance
- **WHEN** a producer stores a non-`Sendable` `NonSendableModel` and writes its rows
- **THEN** it compiles and streams `a` then `b` through the streaming terminal

Pinned by: `Fixtures/Tests/StreamingTierTests/TierTests.swift` (`nonSendableProducer`).

### Requirement: A bare `@RawRoute` binds its parameters by type
A route carrying `@RawRoute` or `@RawRoute()` SHALL call its handler with the register closure's
primitives, matching `HTTPRequest` to the request, `[String: Substring]` to the path parameters, and a
generic parameter constrained by `AsyncReader`, `HTTPResponseSender` or `RequestContext` to the reader,
sender or context. Any other parameter SHALL be reported as `unsupportedRawParameter`. A `@RawRoute`
needs no response annotation.

#### Scenario: a sender-only raw route
- **WHEN** `@Get("/events") @RawRoute func events<Sender: HTTPResponseSender & ~Copyable & SendableMetatype>(responseSender: consuming sending Sender)` is generated under `/users`
- **THEN** the witness registers `{ _, requestContext, _, _, responseSender in` and there are no diagnostics

#### Scenario: an uninferable parameter
- **WHEN** a bare `@RawRoute` handler takes `name: String`
- **THEN** the diagnostic is "@RawRoute parameter 'name' has a type ('String') that can't be inferred — a bare @RawRoute infers HTTPRequest, [String: Substring], the AsyncReader-constrained reader, and the HTTPResponseSender-constrained sender by type. For a transformed slot (a type a middleware produces, e.g. MultiPartSender<S>), name the roles explicitly: @RawRoute(.role, …), one role per parameter"

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`rawRoutePassthrough`). The `unsupportedRawParameter` scenario is pinned by nothing yet.

### Requirement: `@RawRoute(.role, …)` binds parameters positionally
`@RawRoute(_ roles: RawRouteRole...)` SHALL bind the handler's parameters in order to the listed
roles, drawn from `RawRouteRole`'s cases `request`, `requestContext`, `pathParameters`, `reader` and
`responseSender`. A role count that differs from the parameter count SHALL be reported as
`rawRouteRoleCountMismatch`.

#### Scenario: a transformed sender by role
- **WHEN** `@Post("/multipart") @RawRoute(.request, .responseSender) func upload(_ request: HTTPRequest, responseSender: consuming MultiPartSender<Sender>)` is generated
- **THEN** the witness calls `try await self._wireSubject.upload(request, responseSender: responseSender)`

#### Scenario: one role for two parameters
- **WHEN** a route `upload` carries `@RawRoute(.responseSender)` and takes two parameters
- **THEN** the diagnostic is "@RawRoute(role, …) on 'upload' lists 1 role(s) but the handler has 2 parameter(s) — give exactly one role per parameter, in order"

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`rawRouteExplicitResponseSenderRole`, `rawRouteExplicitRolesBindPositionally`, `rawRouteRoleCountMismatchIsDiagnosed`).

### Requirement: A raw route must take the response sender
WireMVCRouteGen SHALL report `rawRouteMissingSender` for a `@RawRoute` handler none of whose
parameters binds to the response sender.

#### Scenario: a request-only raw handler
- **WHEN** `@Get("/x") @RawRoute func f(_ request: HTTPRequest) async throws` is generated
- **THEN** the diagnostic is "@RawRoute handler 'f' must take the response sender (a parameter generic over HTTPResponseSender, or bound via @RawRoute(.responseSender)) to write its response"

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`rawRouteMissingSenderIsDiagnosed`).

### Requirement: An untransformed raw sender is wrapped in `ResponseHeaderApplyingSender`
A raw handler's sender parameter whose type is the handler's own `HTTPResponseSender`-constrained
generic parameter SHALL be passed as `ResponseHeaderApplyingSender(wrapping: responseSender, registry:
wireMVCResponseHeaderRegistry)`, whether roles are inferred or named. A sender parameter of any other
type, such as `MultiPartSender<Sender>`, SHALL be passed as `responseSender` unwrapped.

#### Scenario: named roles over an untransformed sender
- **WHEN** `@RawRoute(.reader, .responseSender) func exchange<Reader: AsyncReader & ~Copyable, Sender: HTTPResponseSender & ~Copyable>(reader: consuming Reader, responseSender: consuming Sender)` is generated
- **THEN** the witness calls `try await self._wireSubject.exchange(reader: reader, responseSender: ResponseHeaderApplyingSender(wrapping: responseSender, registry: wireMVCResponseHeaderRegistry))`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`rawRoutePassthrough`, `rawRouteExplicitRolesStillWrapAnUntransformedSender`, `rawRouteExplicitResponseSenderRole`), `Fixtures/Tests/WireMVCBootstrapExampleTests/WithTestServerTests.swift` (`globalContributionReachesARawRoute`).

### Requirement: `@ResponseHeader` is rejected on a raw route
WireMVCRouteGen SHALL report `responseHeaderOnRawRoute` for a `@RawRoute` handler that carries
`@ResponseHeader` or whose controller carries one.

#### Scenario: a constant header on a raw handler
- **WHEN** a route `stream` carries `@RawRoute` and `@ResponseHeader(.cacheControl, "no-store")`
- **THEN** the diagnostic is "@ResponseHeader does not apply to the @RawRoute handler 'stream' — a raw handler writes its own response head, so nothing here could set the field for it. Set it on the HTTPResponse the handler sends."

Pinned by: `Tests/WireMVCCodegenTests/ResponseHeaderGenerationTests.swift` (`responseHeaderOnARawRouteIsDiagnosed`). The controller-scope case is pinned by nothing yet.

### Requirement: A raw route states its length only through the three-argument `sendAndFinish`
`ResponseHeaderApplyingSender.sendAndFinish(_:buffer:trailer:)` SHALL call `stateLengthIfAbsent` with
the buffer's count when `trailer` is `nil`. `ResponseHeaderApplyingSender.send(_:)` SHALL forward the
head without stating a length, so a raw route that calls the two-argument `sendAndFinish(_:buffer:)`,
or streams through `send`, sends no `Content-Length`.

#### Scenario: the three-argument spelling
- **WHEN** a generic raw route calls `sendAndFinish(HTTPResponse(status: .ok), buffer: &buffer, trailer: nil)` with five bytes through the wrapper
- **THEN** the head carries `Content-Length: 5`

#### Scenario: the two-argument spelling
- **WHEN** the same route calls `sendAndFinish(HTTPResponse(status: .ok), buffer: &buffer)`
- **THEN** the head carries no `Content-Length` and the body is still sent

Pinned by: `Tests/WireMVCResponsesTests/ResponsesTests.swift` (`threeArgumentRawRouteStatesALength`, `twoArgumentRawRouteDoesNotYetStateALength`, `streamedRawRouteStatesNoLength`, `streamedRawRouteStillSendsItsHead`).

## Related specifications

- [response-headers](../response-headers/spec.md)
- [elementary-html](../elementary-html/spec.md)
- [controllers-and-routes](../controllers-and-routes/spec.md)
- [error-response-tiers](../error-response-tiers/spec.md)
- [middleware](../middleware/spec.md)
- [route-builder-contract](../route-builder-contract/spec.md)
- [testing-harness](../testing-harness/spec.md)
