# Extensible and streaming request bindings

## Purpose

The seam through which a binding declared outside WireMVC is recognised, and the two tiers that read the
request body without collecting it first. A binding states on its own declaration, with
`@RequestBinding(…)`, the obligations the code generator cannot infer (`.body`, `.path`, `.readerBody`,
`.bodyStream`) and, for a lent stream, the stream type. WireMVCRouteGen reads those declarations from
every parsed source, emits the matching terminal, and refuses the combinations a single request reader
cannot honour. This spec also covers the runtime pieces the streaming tiers call:
`RequestBodyReading`, `LentBodyStream` and `WireMVCRequest.streamBody`.

Rationale: [ExtensibleBindingsAndResponses](../../../Documentation/Notes/ExtensibleBindingsAndResponses.md), [DecompositionTransformers](../../../Proposals/DecompositionTransformers.md).
Documentation: [RequestBindings](../../../Sources/WireMVC/WireMVC.docc/RequestBindings.md).

## Requirements

### Requirement: `@RequestBinding` states a binding's obligations and stream type
The `WireMVC` module SHALL declare `@RequestBinding(_ obligations: WireMVCBindingObligation..., stream:
String? = nil)` as an attached peer macro implemented by `RouteMarkerMacro`, and
`WireMVCBindingObligation` SHALL be a `Sendable` enum with exactly the cases `body`, `path`, `readerBody`
and `bodyStream`.

#### Scenario: each obligation is read
- **WHEN** the sources declare `@RequestBinding(.body) FormBody`, `@RequestBinding(.path) Slug`, `@RequestBinding(.body, .path) Odd` and a bare `@RequestBinding Plain`
- **THEN** the scan records `FormBody` as `.body`, `Slug` as `.path`, `Odd` as both and `Plain` as none

#### Scenario: a qualified obligation
- **WHEN** a binding is declared `@RequestBinding(WireMVCBindingObligation.body)`
- **THEN** it is recorded as `.body`, the same as the shorthand

Pinned by: `Tests/WireMVCCodegenTests/BindingObligationsTests.swift` (`readsEachObligation`). The qualified `WireMVCBindingObligation.body` spelling is pinned by nothing yet.

### Requirement: A binding is found by its declaration anywhere in the parsed sources
`scanRequestBindings(in:)` SHALL record every struct, enum, class or actor carrying `@RequestBinding`, at
any nesting depth, keyed by its bare type name, and SHALL NOT read the attribute from an extension. A
use site in one file SHALL be matched to a declaration in another.

#### Scenario: a declaration in a dependency's file
- **WHEN** one file declares `@RequestBinding(.body) public struct FormBody` and another uses `@FormBody input: Login`
- **THEN** the route binds `FormBody<Login>.bind(` with no error diagnostic

#### Scenario: nested, class and actor declarations
- **WHEN** `@RequestBinding(.body)` is on a struct inside `enum Bindings` and on a `final class`, and a bare `@RequestBinding` is on an `actor`
- **THEN** all three are recorded

#### Scenario: an attribute on an extension
- **WHEN** `@RequestBinding(.body)` is written on `extension FormBody {}`
- **THEN** `FormBody` is not recorded as a binding

#### Scenario: a user body binding over HTTP
- **WHEN** the fixture's `@RequestBinding(.body) TextBody` route `POST /pages/ledger` receives body `wed`
- **THEN** the handler receives `"wed"` and the route answers `201`

Pinned by: `Tests/WireMVCCodegenTests/BindingObligationsTests.swift` (`acrossFiles`, `recognised`, `nestedDeclaration`, `nonStructDeclarations`, `attributeOnExtensionIsNotSeen`), `Fixtures/Tests/WireMVCBootstrapExampleTests/UserDeclaredResponseModeTests.swift` (`aUserModeCarriesAnAnnotatedStatus`).

### Requirement: A `.readerBody` binding is handed the reader through `RequestBodyReading`
`RequestBodyReading` SHALL declare an associated type `Value` and
`static func bindReader<Reader: AsyncReader & ~Copyable>(name:request:pathParameters:reader: consuming
Reader, coding:) async throws -> Value` where `Reader.ReadElement == UInt8` and `Reader.FinalElement ==
HTTPFields?`. For a `.readerBody` parameter the terminal SHALL emit
`try await <Wrapper><<Type>>.bindReader(name: …, request: request, pathParameters: pathParameters, reader:
reader, coding: …)`, SHALL call its terminal with `lendingBodyFrom: reader` and a `building` closure
taking `reader`, and SHALL NOT use the collecting terminal overload (`collectingBodyFrom:`).

#### Scenario: the emitted bind
- **WHEN** `@RequestBinding(.readerBody) struct Upload` is used as `@Upload file: Receipt` on a `@JSONResponse` route
- **THEN** the source contains `Upload<Receipt>.bindReader(` and `reader: reader`, and the register closure names its `reader`

#### Scenario: the lending overload on a buffered route
- **WHEN** the same `@Upload file: Receipt` route is `@JSONResponse`
- **THEN** the source contains `lendingBodyFrom: reader,` and `building: { reader in`, and no `collectingBodyFrom:`

#### Scenario: a streamed digest over HTTP
- **WHEN** `POST /pages/digest` carries a 4000-byte body to the fixture's `@DigestBody` route
- **THEN** the response is `200` with `byteCount == 4000` and the checksum of every byte

#### Scenario: an empty body
- **WHEN** `POST /pages/digest` carries no body
- **THEN** the response is `200` with `byteCount == 0`

Pinned by: `Tests/WireMVCCodegenTests/BindingObligationsTests.swift` (`handsOverTheReader`), `Fixtures/Tests/WireMVCBootstrapExampleTests/StreamingRequestTests.swift` (`reducesTheBody`, `multiChunkBody`, `emptyBody`). The lending overload on a buffered route is pinned by nothing yet.

### Requirement: A `.readerBody` binding combines with a streaming response through the lending terminal
On a route whose response mode uses the streaming terminal, a `.readerBody` binding SHALL be emitted
against `wireMVCStreamingTerminal(…, lendingBodyFrom: reader, …)`, which hands the reader to `building`
as a consuming parameter, so an error the binding throws is mapped before the response head is sent.

#### Scenario: a reader binding under `@HTMLResponse`
- **WHEN** `@Upload a: Receipt` (a `.readerBody` binding) is on an `@HTMLResponse` route
- **THEN** the source contains `lendingBodyFrom: reader,` and no `collectingBodyFrom:`

#### Scenario: an oversized body on a streamed page
- **WHEN** `POST /pages/digest/page` carries 64 KiB to a binding that throws `DigestError.tooLarge` past 4096 bytes, mapped by `@ErrorResponse(DigestError.self, .contentTooLarge)`
- **THEN** the response status is `413`

#### Scenario: beside an ordinary bind
- **WHEN** `POST /pages/digest/report/page` binds `@Path` and `@DigestBody` on a streamed page
- **THEN** the page contains both the path value and the digest

Pinned by: `Tests/WireMVCCodegenTests/BindingObligationsTests.swift` (`reducedBodyOnStreamingResponseAllowed`), `Fixtures/Tests/WireMVCBootstrapExampleTests/StreamingRequestTests.swift` (`reducedBodyOnStreamingResponse`, `oversizedBodyMapsOnStreamingResponse`, `reducedBodyBesideOtherBinds`, `oversizedBodyMapsOnScopedStreamingResponse`).

### Requirement: At most one binding on a route may stream the body
WireMVCRouteGen SHALL count the parameters whose binding declares `.readerBody` or `.bodyStream` and,
when there is more than one, SHALL report `multipleReaderBodyBindings` as an error at the second one and
not emit the route.

#### Scenario: two reader bindings
- **WHEN** a route named `receive` declares `@Upload a: Receipt, @Upload b: Receipt` with `Upload` declared `.readerBody`
- **THEN** the error is `route 'receive' has 2 bindings that stream the request body — a body can be streamed once, because reading it consumes the reader. Collect it instead (a @RequestBinding(.body) binding hands every parameter the same bytes), or stream it into one binding that produces what the others needed`

#### Scenario: a lent stream beside a reader binding
- **WHEN** a route declares a `.bodyStream` parameter and a `.readerBody` parameter
- **THEN** the same `multipleReaderBodyBindings` error is reported

Pinned by: `Tests/WireMVCCodegenTests/BindingObligationsTests.swift` (`twoStreamsRefused`, `lentBesideReducingRefused`).

### Requirement: A streamed body cannot share a route with a collected one
When a route has one streaming binding and any `.body` binding, WireMVCRouteGen SHALL report
`readerBodyWithCollectedBody` as an error at the function name and not emit the route.

#### Scenario: a reader binding beside `@JSONBody`
- **WHEN** a route named `receive` declares `@Upload a: Receipt, @JSONBody b: Receipt`
- **THEN** the error is `route 'receive' both streams and collects its request body — the reader cannot do both, since collecting consumes it. Use one or the other`

Pinned by: `Tests/WireMVCCodegenTests/BindingObligationsTests.swift` (`streamBesideCollectRefused`, `lentBesideCollectRefused`).

### Requirement: A `.bodyStream` binding's stream is constructed from its declared `stream:` type
For a `.bodyStream` parameter the terminal SHALL emit `let <name> = <Stream>(request: request, reader:
reader)`, where `<Stream>` is the `stream:` string on the binding's declaration spelled with no type
argument, SHALL pass the value to the handler by value, and SHALL call its terminal with
`lendingBodyFrom: reader` rather than the collecting overload (`collectingBodyFrom:`).

#### Scenario: a multipart stream
- **WHEN** `@RequestBinding(.bodyStream, stream: "MultipartParts") struct Upload` is used as `@Upload parts: consuming S`
- **THEN** the source contains `let parts = MultipartParts(request: request, reader: reader)` and `receive(parts: parts)`, and contains no `MultipartParts<`

#### Scenario: the lending overload for a lent stream
- **WHEN** the same route is generated
- **THEN** the source contains `lendingBodyFrom: reader,` and no `collectingBodyFrom:`

Pinned by: `Tests/WireMVCCodegenTests/BindingObligationsTests.swift` (`consumingStream`). The lending overload for a lent stream is pinned by nothing yet.

### Requirement: A `.bodyStream` binding must name its stream type
When a parameter's binding declares `.bodyStream` with no `stream:` argument, WireMVCRouteGen SHALL report
`bodyStreamNeedsStreamType` as an error at the parameter.

#### Scenario: no `stream:`
- **WHEN** `@RequestBinding(.bodyStream) struct Upload` is used on a route
- **THEN** the error is `binding 'Upload' is declared @RequestBinding(.bodyStream) but names no stream type — add stream: "YourStream", naming the type whose init takes (request:reader:). It cannot be a factory on the binding itself: a property wrapper is generic over the parameter's type, so a static method on it has no way to resolve that generic parameter`

Pinned by: `Tests/WireMVCCodegenTests/BindingObligationsTests.swift` (`missingStreamType`).

### Requirement: A lent stream parameter must be `consuming`
When a `.bodyStream` parameter's type is not attributed `consuming`, WireMVCRouteGen SHALL report
`bodyStreamNeedsOwnership` as an error at the parameter, for `inout` and for no ownership alike.

#### Scenario: an `inout` stream
- **WHEN** `receive` declares `@Upload parts: inout S`
- **THEN** the error is `parameter 'parts' on 'receive' lends a request body stream, so it must be 'consuming' — the stream is used up once, through its 'withParts'-style entry point. 'inout' cannot work: calling a consuming method on an inout binding requires reinitialising it, and there is nothing to put back`

#### Scenario: no ownership
- **WHEN** `receive` declares `@Upload parts: S`
- **THEN** the same `must be 'consuming'` error is reported

Pinned by: `Tests/WireMVCCodegenTests/BindingObligationsTests.swift` (`inoutStreamRefused`, `missingOwnership`).

### Requirement: A lent stream cannot combine with a streaming response
When a route's one streaming binding declares `.bodyStream` and its response mode uses the streaming
terminal, WireMVCRouteGen SHALL report `bodyStreamOnStreamingResponse` as an error at the function name.
The duplex form is tracked by https://github.com/swift-wire/wire-mvc/issues/173.

#### Scenario: a lent stream under `@HTMLResponse`
- **WHEN** a route named `receive` declares `@Upload parts: consuming S` and `@HTMLResponse`
- **THEN** the error begins `route 'receive' lends its request body stream to the handler on a streaming-response route — a duplex route, which is not supported yet.` and names `@RawRoute` and `@RequestBinding(.readerBody)` as what works today

Pinned by: `Tests/WireMVCCodegenTests/BindingObligationsTests.swift` (`lentStreamOnStreamingResponseRefused`).

### Requirement: A lent stream is validated after construction and before the handler
`LentBodyStream` SHALL be a protocol suppressing `Copyable` and `Escapable` with one requirement,
`borrowing func validateRequest() throws`, defaulted to do nothing. For every `.bodyStream` parameter the
terminal SHALL emit `try <name>.validateRequest()` immediately after constructing the stream and before
the handler call. No other binding SHALL be given a validation step.

#### Scenario: the order of the three statements
- **WHEN** a route lends `@Upload parts: consuming S`
- **THEN** `let parts = MultipartParts(request: request, reader: reader)` precedes `try parts.validateRequest()`, which precedes `receive(parts: parts)`

#### Scenario: ordinary bindings
- **WHEN** a route declares only `@Path id: String` and `@JSONBody meta: Meta`
- **THEN** the source contains no `validateRequest()`

Pinned by: `Tests/WireMVCCodegenTests/BindingObligationsTests.swift` (`lentStreamValidated`, `ordinaryBindingNotValidated`).

### Requirement: `WireMVCRequest.streamBody` walks the body chunk by chunk under a cap
`WireMVCRequest.streamBody(_:into:maximumSize:consume:)` SHALL consume the reader, call `consume` with
the `inout` state and each `Span<UInt8>` of every chunk, including the bytes of the chunk that carries the
final element, and return when a non-`nil` final element is read. `maximumSize` SHALL default to
`100_000_000`, and a running total above it SHALL throw `WireMVCBindingError.malformedBody`.

#### Scenario: a multi-chunk body
- **WHEN** a 4000-byte body is folded by `@DigestBody` through `streamBody`
- **THEN** the digest counts every byte exactly once, final chunk included

Pinned by: `Fixtures/Tests/WireMVCBootstrapExampleTests/StreamingRequestTests.swift` (`multiChunkBody`, `emptyBody`), `Tests/WireMVCServerTransportTests/AdapterTests.swift` (`acceptsRequestBodyLargerThanTheOldCollectCeiling`). The exact `maximumSize` default is pinned by nothing yet; the adapter test pins only that it exceeds 2 MiB. The `malformedBody` throw past the cap is pinned by nothing yet.

### Requirement: `streamBody` rethrows the binding's own error unwrapped
When the reader's `read` throws, `streamBody` SHALL rethrow through `EitherError.unwrap()`, so an error
thrown by the `consume` closure reaches the route's error mapping as its own type.

#### Scenario: a binding refuses mid-read
- **WHEN** `@DigestBody` throws `DigestError.tooLarge` from its `consume` closure after 4096 bytes of a 64 KiB body on `POST /pages/digest`, mapped by `@ErrorResponse(DigestError.self, .contentTooLarge)`
- **THEN** the response status is `413`

Pinned by: `Fixtures/Tests/WireMVCBootstrapExampleTests/StreamingRequestTests.swift` (`oversizedBodyIsRefusedMidStream`).

### Requirement: A binding that cannot be sent is warned about, not refused
WireMVCRouteGen SHALL report `bindingMissingSendConformance` as a warning for each discovered binding
whose declared obligations include `.body` or `.readerBody` and which no parsed inheritance clause
conforms to `RequestBodySendable`, and for each other binding not conforming to `RequestSendable`.
Bindings declaring `.bodyStream` and bindings that delegate to a worker SHALL be exempt. A warning SHALL
NOT make `WireMVCRouteGen` exit non-zero.

#### Scenario: a body binding without the conformance
- **WHEN** `@RequestBinding(.body) public struct FormBody<Value: Decodable & Sendable>: RequestBound {}` is declared with no `RequestBodySendable` conformance
- **THEN** the warning is `binding 'FormBody' is declared @RequestBinding but does not conform to RequestBodySendable, so the generated typed client cannot send it — add the conformance, or the client's call will fail to compile. (If it is declared in a module this build does not parse, ignore this.)`

#### Scenario: the conformance is added
- **WHEN** the sources also declare `extension FormBody: RequestBodySendable {}`
- **THEN** no `does not conform` warning is reported

#### Scenario: a lent stream
- **WHEN** `@RequestBinding(.bodyStream, stream: "MultipartParts") struct Upload` has no send conformance
- **THEN** no `does not conform to RequestSendable` warning is reported

Pinned by: `Tests/WireMVCCodegenTests/BindingObligationsTests.swift` (`missingSendConformanceIsWarned`, `conformingBindingIsQuiet`, `lentStreamNotWarnedAbout`), `Tests/WireMVCCodegenTests/GraphAwareBindingTests.swift` (`theOmittedRouteIsNotAlsoNaggedAboutRequestSendable`, `anOrdinaryBindingIsStillNaggedAboutRequestSendable`).

### Requirement: The send protocols declare their own `Value`
`RequestSendable` and `RequestBodySendable` SHALL each declare their own associated type `Value` rather
than refining `RequestBound`, so a binding implementing only `RequestBodyReading` can conform to
`RequestBodySendable`. `RequestBodySendable.sendBody` SHALL return `(bytes: [UInt8], contentType: String)`.

#### Scenario: a streaming binding is sendable
- **WHEN** the fixture declares `extension DigestBody: RequestBodySendable where Value == BodyDigest`
- **THEN** the fixtures package compiles with `DigestBody` conforming to `RequestBodyReading` and `RequestBodySendable` and not to `RequestBound`

Pinned by: `Fixtures/Sources/WireMVCBootstrapExample/DigestBodyBinding.swift` (built by the `Build fixtures` step of the `BuildAndRun` job in `.github/workflows/build.yml`).

## Related specifications

- [request-bindings](../request-bindings/spec.md)
- [graph-aware-bindings](../graph-aware-bindings/spec.md)
- [controllers-and-routes](../controllers-and-routes/spec.md)
- [responses-and-modes](../responses-and-modes/spec.md)
- [error-response-tiers](../error-response-tiers/spec.md)
- [route-builder-contract](../route-builder-contract/spec.md)
- [testing-harness](../testing-harness/spec.md)
- [build-plugins-and-routegen-cli](../build-plugins-and-routegen-cli/spec.md)
