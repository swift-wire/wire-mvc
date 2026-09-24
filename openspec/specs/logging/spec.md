# Logging

## Purpose

Request-scoped logging for a WireMVC application. The core declares the logging contract, the keys
and the correlation-id rule, and provides none of its bindings. Two interchangeable targets supply
them: `WireMVCLogging` mints a request logger from the app logger and a per-request correlation id,
and `WireMVCTaskLocalLogging` adopts the logger the runtime bound as a swift-log task-local. Both make
a request-scoped type's bare `@Inject var logger: Logger` resolve to the per-request logger, and both
fold contributed metadata onto it.

Documentation: [Logging](../../../Sources/WireMVC/WireMVC.docc/Logging.md), [TheCompositionRoot](../../../Sources/WireMVC/WireMVC.docc/TheCompositionRoot.md).

## Requirements

### Requirement: The core declares the logging keys and provides no logging binding
`WireMVC` SHALL declare `WireMVCApplication.logger` as a `BindingKey<Logger>`, `WireMVCRequest.id` as a
`BindingKey<String>`, and `WireMVCLogMetadata.stringEntries` as a `MappedKey<String, String>`, in
`Sources/WireMVC/LoggingKeys.swift`. The `WireMVC` target SHALL provide no binding for any of the three.

#### Scenario: both logging targets name the same keys
- **WHEN** `WireMVCLogging` and `WireMVCTaskLocalLogging` each declare `@Provides(WireMVCApplication.logger)`
- **THEN** both reference the one key declared in `WireMVC`, and a target depending on neither has no `WireMVCApplication.logger` binding

Pinned by: `Fixtures/Sources/WireMVCExample/WhoAmIController.swift` and `Fixtures/Sources/WireMVCTaskLocalExample/Controller.swift` (built by the `Build fixtures` step of the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: The request id is logged under `request-id`
`WireMVCLogMetadata.requestID` SHALL be the string `"request-id"`.

#### Scenario: reading the id back off the logger
- **WHEN** `WhoAmIController` reads `logger[metadataKey: WireMVCLogMetadata.requestID]` under `WireMVCLogging`
- **THEN** the value equals the request's injected `WireMVCRequest.id`

Pinned by: `Fixtures/Sources/WireMVCExample/main.swift` (the `WireMVCLogging` check, run by the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: `WireMVCLogMetadata.applying` folds entries as string metadata
`WireMVCLogMetadata.applying(_ entries: [String: String], to logger: Logger) -> Logger` SHALL return a
copy of `logger` with `result[metadataKey: key] = .string(value)` set for every entry.

#### Scenario: an app-side field on the logger
- **WHEN** `TenantLogFields.tenant` contributes `"public"` to `WireMVCLogMetadata.stringEntries` at key `"tenant"`
- **THEN** the request logger `WhoAmIController` injects carries `tenant` metadata equal to `"public"`

Pinned by: `Fixtures/Sources/WireMVCExample/TenantLogMetadata.swift` and `Fixtures/Sources/WireMVCExample/main.swift` (the `WireMVCLogMetadata.stringEntries` check, run by the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: A supplied `X-Request-Id` is the correlation id
`WireMVCRequest.correlationID(from request: HTTPRequest) -> String` SHALL return the value of the
request's `x-request-id` header field when that field is present and non-empty.

#### Scenario: the caller supplies an id
- **WHEN** a request carries `X-Request-Id: abc-123` and a `traceparent` field
- **THEN** `correlationID(from:)` returns `"abc-123"`

Pinned by: nothing yet.

### Requirement: Without `X-Request-Id` the `traceparent` trace-id is the correlation id
When no non-empty `x-request-id` field is present and a `traceparent` field is, `correlationID(from:)`
SHALL split its value on `-` and return the second field when there are at least two fields and the
second is non-empty.

#### Scenario: a W3C trace context
- **WHEN** a request carries `traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01` and no `X-Request-Id`
- **THEN** `correlationID(from:)` returns `"4bf92f3577b34da6a3ce929d0e0e4736"`

Pinned by: nothing yet.

### Requirement: Otherwise the correlation id is a fresh UUID
When neither rule above yields an id, `correlationID(from:)` SHALL return `UUID().uuidString`, fresh on
each call.

#### Scenario: two bare requests
- **WHEN** `WireMVCExample` sends two `GET /whoami` requests with neither header, under `WireMVCLogging`
- **THEN** each injected `WireMVCRequest.id` is non-empty and the two differ

Pinned by: `Fixtures/Sources/WireMVCExample/main.swift` (the `WireMVCLogging` check, run by the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: `WireMVCLogging` provides a labelled app logger
`WireMVCLogging` SHALL provide `WireMVCApplication.logger` through the public top-level producer
`wireMVCApplicationLogger()`, which returns `Logger(label: "WireMVC")`.

#### Scenario: the default app logger
- **WHEN** an app depends on `WireMVCLogging` and declares no replacement
- **THEN** `@Inject(WireMVCApplication.logger)` resolves to a logger labelled `WireMVC`

Pinned by: nothing yet.

### Requirement: `WireMVCLogging` provides the request id and logs it
`WireMVCLogging` SHALL declare `@Scoped(seed: HTTPRequest.self) public enum WireMVCRequestLogging`
whose `requestID(request:)` is both `@Provides(WireMVCRequest.id)` and `@Contributes(to:
WireMVCLogMetadata.stringEntries, atKey: WireMVCLogMetadata.requestID)`, and returns
`WireMVCRequest.correlationID(from: request)`.

#### Scenario: the injected id and the logged id agree
- **WHEN** `WhoAmIController` injects `@Inject(WireMVCRequest.id) var requestID: String` and the unkeyed `Logger` on two requests
- **THEN** on each request `logger[metadataKey: "request-id"]` equals `requestID`

Pinned by: `Fixtures/Sources/WireMVCExample/main.swift` (the `WireMVCLogging` check, run by the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: `WireMVCLogging`'s request logger is the app logger with the contributed fields
`WireMVCRequestLogging.requestLogger(base:fields:)` SHALL be the unkeyed `@Provides` `Logger` in the
`HTTPRequest` scope, taking `@Bind(WireMVCApplication.logger) base: Logger` and
`@Bind(WireMVCLogMetadata.stringEntries) fields: [String: String]` and returning
`WireMVCLogMetadata.applying(fields, to: base)`.

#### Scenario: the library's field and the app's field together
- **WHEN** `WireMVCLogging` contributes `request-id` and the app's `TenantLogFields` contributes `tenant`
- **THEN** the logger `WhoAmIController` injects carries both entries

Pinned by: `Fixtures/Sources/WireMVCExample/main.swift` (the `WireMVCLogging` and `WireMVCLogMetadata.stringEntries` checks, run by the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: `WireMVCTaskLocalLogging`'s app logger is a snapshot of `Logger.current`
`WireMVCTaskLocalLogging` SHALL provide `WireMVCApplication.logger` through the public top-level
producer `wireMVCTaskLocalApplicationLogger()`, which returns `Logger.current` as read when the graph
constructs the binding.

#### Scenario: a logger bound around the bootstrap
- **WHEN** `WireMVCTaskLocalExample` builds the graph inside `withLogger(probeLogger(marker: "bootstrap"))`
- **THEN** the app-scoped binding holds the `bootstrap` logger, which the request logger does not show

Pinned by: nothing yet. `Fixtures/Sources/WireMVCTaskLocalExample/main.swift` asserts it when run, but CI builds that executable in the `Build fixtures` step and does not run it.

### Requirement: `WireMVCTaskLocalLogging`'s request logger is `Logger.current` during the request
`WireMVCTaskLocalLogging` SHALL declare `@Scoped(seed: HTTPRequest.self) public enum
WireMVCTaskLocalRequestLogging` whose unkeyed `@Provides` `requestLogger(fields:)` takes
`@Bind(WireMVCLogMetadata.stringEntries) fields: [String: String]` and returns
`WireMVCLogMetadata.applying(fields, to: .current)`, reading the task-local when the request scope
constructs it.

#### Scenario: a logger bound around serving
- **WHEN** `WireMVCTaskLocalExample` serves inside `withLogger(probeLogger(marker: "serve", runtimeID: "runtime-42"))` and `GET /probe` reads the injected logger
- **THEN** its `probe-marker` metadata is `serve`, not `bootstrap`, and its `runtime.request.id` metadata is `runtime-42`

Pinned by: nothing yet. `Fixtures/Sources/WireMVCTaskLocalExample/main.swift` asserts it when run, but CI builds that executable in the `Build fixtures` step and does not run it.

### Requirement: `WireMVCTaskLocalLogging` provides no request id and adds none to the logger
`WireMVCTaskLocalLogging` SHALL NOT provide `WireMVCRequest.id` and SHALL NOT contribute to
`WireMVCLogMetadata.stringEntries`, so the request logger carries only the task-local logger's
metadata and whatever the app contributes.

#### Scenario: an inbound `X-Request-Id` under the task-local target
- **WHEN** the app provides `WireMVCRequest.id` from `Logger.current[metadataKey: "runtime.request.id"]` and a client sends `GET /probe` with `X-Request-Id: abc-123`
- **THEN** the injected id is `runtime-42`, and the logger's metadata keys are exactly `probe-marker` and `runtime.request.id`

Pinned by: nothing yet. `Fixtures/Sources/WireMVCTaskLocalExample/main.swift` asserts it when run, but CI builds that executable in the `Build fixtures` step and does not run it.

### Requirement: The two targets provide the same two bindings
`WireMVCLogging` and `WireMVCTaskLocalLogging` SHALL each provide `WireMVCApplication.logger` at app
scope and an unkeyed `Logger` in the `HTTPRequest` scope, so a target depending on both products
declares each of those bindings twice.

#### Scenario: an app takes both
- **WHEN** one executable target depends on both the `WireMVCLogging` and the `WireMVCTaskLocalLogging` products
- **THEN** its graph has two providers for `WireMVCApplication.logger` and two for the request-scoped `Logger`

Pinned by: nothing yet.

### Requirement: Every logging binding is a public producer an app can supersede
Every producer in `WireMVCLogging` and `WireMVCTaskLocalLogging` SHALL be `public`, so an app can
declare `@Provides(<same key>) @Replaces` to supersede it, and a replacement of
`WireMVCRequestLogging.requestID(request:)` carries its contribution.

#### Scenario: replacing the app logger
- **WHEN** an app declares `@Provides(WireMVCApplication.logger) @Replaces func appLogger() -> Logger { Logger(label: "my-app") }`
- **THEN** the request logger's base is the `my-app` logger

Pinned by: nothing yet.

### Requirement: swift-log 1.14 is the floor
The root `Package.swift` SHALL depend on `https://github.com/apple/swift-log.git` `from: "1.14.0"`,
the release that provides `withLogger` and `Logger.current`.

#### Scenario: the task-local target compiles
- **WHEN** the package resolves swift-log at its floor
- **THEN** `WireMVCTaskLocalLogging`'s references to `Logger.current` compile

Pinned by: `Package.swift`, `.github/workflows/build.yml` (`BuildAndRun`, step `Build`).

## Related specifications

- [request-scope](../request-scope/spec.md)
- [composition-root](../composition-root/spec.md)
- [package-traits](../package-traits/spec.md)
- [middleware](../middleware/spec.md)
- [swift-wire seeded-scopes](https://github.com/swift-wire/swift-wire/blob/main/openspec/specs/seeded-scopes/spec.md)
