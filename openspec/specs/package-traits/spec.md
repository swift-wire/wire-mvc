# Package traits and products

## Purpose

The shape of the wire-mvc package as a consumer resolves it: the products it vends, the three
package traits that gate its optional integrations, and the guarantee that with every trait off the
package resolves no concrete HTTP server. The runnable fixtures live in a separate package that
enables the traits, so the framework's own manifest can stay trait-gated. What each gated module does
once enabled is specified in the sibling specifications linked below.

Rationale: [TestingArchitecture](../../../Documentation/Notes/TestingArchitecture.md), [WireMVCDesign](../../../Documentation/Notes/WireMVCDesign.md).
Documentation: [PackageTraits](../../../Sources/WireMVC/WireMVC.docc/PackageTraits.md), [AddingWireMVCToAPackage](../../../Sources/WireMVC/WireMVC.docc/AddingWireMVCToAPackage.md), [CONTRIBUTING](../../../CONTRIBUTING.md).

## Requirements

### Requirement: Three traits are declared and none is enabled by default
The root `Package.swift` SHALL declare exactly three traits, `ServerTransport`, `NIOHTTPServer` and
`Elementary`, each with `.trait(name:)` and none listed as a default trait.

#### Scenario: a consumer names no traits
- **WHEN** a package depends on wire-mvc without a `traits:` argument
- **THEN** none of `ServerTransport`, `NIOHTTPServer` or `Elementary` is enabled, and `swift build` at the repository root builds every target

Pinned by: `Package.swift`, `.github/workflows/build.yml` (`BuildAndRun`, step `Build`).

### Requirement: With every trait off the graph resolves no concrete server
Every product dependency on the `swift-http-server` package SHALL be conditional on the
`NIOHTTPServer` trait, so that with default traits SwiftPM prunes `swift-http-server` from resolution.
The only such dependency SHALL be `WireMVCTesting`'s `.product(name: "NIOHTTPServer", package:
"swift-http-server", condition: .when(traits: ["NIOHTTPServer"]))`.

#### Scenario: the CI resolution guard
- **WHEN** CI runs `swift package resolve` at the repository root with no traits enabled
- **THEN** `Package.resolved` contains no `"identity" : "swift-http-server"` line, and the step fails with `swift-http-server is back in the core graph — a swift-http-server product dependency is not trait-gated` if it does

Pinned by: `.github/workflows/build.yml` (`BuildAndRun`, step `Verify the core graph resolves no concrete server`).

### Requirement: The committed root lockfile is the default-trait resolution
The committed root `Package.resolved` SHALL contain no pin for `swift-http-server`, `elementary` or
`swift-openapi-runtime`, the three packages reached only through a trait-gated product dependency.

#### Scenario: reading the lockfile
- **WHEN** the committed root `Package.resolved` is read
- **THEN** it pins `swift-wire`, `swift-http-api-proposal` and `swift-log` among others, and has no `swift-http-server`, `elementary` or `swift-openapi-runtime` entry

Pinned by: `Package.resolved`, `.github/workflows/build.yml` (`BuildAndRun`, step `Verify the core graph resolves no concrete server`, which re-resolves and checks `swift-http-server` only). The `elementary` and `swift-openapi-runtime` absence is pinned by nothing yet.

### Requirement: Each trait gates one module's contents and one dependency
The `ServerTransport` trait SHALL gate the `OpenAPIRuntime` product dependency of
`WireMVCServerTransport` and the `#if ServerTransport` body of its source. The `NIOHTTPServer` trait
SHALL gate the `NIOHTTPServer` and `Logging` product dependencies of `WireMVCTesting` and the `#if
NIOHTTPServer` bodies of `NIOHTTPServerTestServer.swift` and `SwiftHttpServerMode.swift`. The
`Elementary` trait SHALL gate the `Elementary` product dependency of `WireMVCElementary` and the `#if
Elementary` body of `WireMVCHTMLProducer.swift`. No other target SHALL reference a trait.

#### Scenario: the ServerTransport trait build
- **WHEN** CI runs `swift test --traits ServerTransport` at the repository root
- **THEN** the log contains `Suite "WireMVCServerTransport" passed`

#### Scenario: the fixtures enable the other two
- **WHEN** the Fixtures package builds with `NIOHTTPServer` and `Elementary` enabled on its wire-mvc dependency
- **THEN** its suites use `.swiftHttpServer` and its targets serve `@HTMLResponse` routes

Pinned by: `.github/workflows/build.yml` (`BuildAndRun`, steps `Build`, `Test ServerTransport adapter (trait)` and `Build fixtures`).

### Requirement: The products are declared unconditionally
The root `Package.swift` SHALL declare the library products `WireMVC`, `WireMVCRouter`,
`WireMVCMiddleware`, `WireMVCServerTransport`, `WireMVCLogging`, `WireMVCTaskLocalLogging`,
`WireMVCElementary`, `WireMVCMacrosPlugin` (over the `WireMVCMacros` target) and `WireMVCTesting`; the
plugin products `WireMVCBuildPlugin` and `WireMVCRouteGenPlugin`; and the executable product
`WireMVCRouteGen`. No product declaration SHALL depend on a trait, so a trait-gated product exists with
the trait off and vends an empty module.

#### Scenario: a trait-gated product with the trait off
- **WHEN** a target depends on the `WireMVCServerTransport` product and the `ServerTransport` trait is off
- **THEN** the product resolves and the module it links declares nothing

Pinned by: `Package.swift`, `.github/workflows/build.yml` (`BuildAndRun`, step `Build`).

### Requirement: The default-trait libraries cross-compile for static Linux
The products `WireMVC`, `WireMVCRouter`, `WireMVCMiddleware`, `WireMVCLogging` and
`WireMVCTaskLocalLogging` SHALL each build in release configuration with `--swift-sdk
aarch64-swift-linux-musl`, built product by product.

#### Scenario: the cross-compile job
- **WHEN** CI installs the Swift 6.4.0 static Linux SDK and runs `swift build -c release --swift-sdk aarch64-swift-linux-musl --product "$product"` for each of the five
- **THEN** each build succeeds

Pinned by: `.github/workflows/build.yml` (`StaticLinuxSDK`, step `Cross-compile the shipping products for ARM64 Linux`).

### Requirement: The fixtures are a separate package that enables the traits
`Fixtures/Package.swift` SHALL declare a package named `wire-mvc-fixtures` that depends on the
framework as `.package(path: "..", traits: ["NIOHTTPServer", "Elementary"])` and holds the runnable
example executables and the integration test targets. The root `Package.swift` SHALL declare no
target that depends on `swift-http-server` unconditionally.

#### Scenario: the fixtures lockfile
- **WHEN** the Fixtures package resolves
- **THEN** its `Package.resolved` pins `swift-http-server` and `elementary`, which the root lockfile does not

#### Scenario: the fixtures build and run in CI
- **WHEN** CI runs `swift build`, `swift test` and `swift run WireMVCExample` in `Fixtures`
- **THEN** each succeeds

Pinned by: `Fixtures/Package.swift`, `Fixtures/Package.resolved`, `.github/workflows/build.yml` (`BuildAndRun`, steps `Build fixtures`, `Test fixtures` and `Run end-to-end example`).

### Requirement: The package requires tools version 6.4 and macOS 26
The root `Package.swift` SHALL declare `swift-tools-version: 6.4` and `platforms: [.macOS(.v26)]`, and
`.swift-version` SHALL name `6.4.0`, the toolchain CI installs.

#### Scenario: the CI toolchain
- **WHEN** a CI job runs `swift-wire/setup-swift@v1`
- **THEN** it installs the toolchain `.swift-version` names and the package builds on it

Pinned by: `Package.swift`, `.swift-version`, `.github/workflows/build.yml` (`BuildAndRun`).

### Requirement: The DocC catalog is built through a plugin dependency and gated on its own diagnostics
The root `Package.swift` SHALL depend on `swift-docc-plugin` from `1.4.0`, and the documentation build
SHALL run `swift package generate-documentation --target WireMVC --diagnostics-file <path>` followed by
`python3 Scripts/docc-gate.py <path>`, which fails on diagnostics in files of this repository.

#### Scenario: the documentation gate
- **WHEN** CI runs the `Documentation` job
- **THEN** a DocC diagnostic located in this repository's sources fails the job, and one located in a dependency's doc comments does not

Pinned by: `.github/workflows/build.yml` (`Documentation`), `Scripts/docc-gate.py`.

## Related specifications

- [server-transport-bridge](../server-transport-bridge/spec.md)
- [elementary-html](../elementary-html/spec.md)
- [testing-harness](../testing-harness/spec.md)
- [logging](../logging/spec.md)
- [build-plugins-and-routegen-cli](../build-plugins-and-routegen-cli/spec.md)
- [route-builder-contract](../route-builder-contract/spec.md)
