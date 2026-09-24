# Build plugins and WireMVCRouteGen command line

## Purpose

How a consumer's route witnesses and program entry are generated at build time. `WireMVCBuildPlugin`
runs swift-wire's WireGen and then this package's `WireMVCRouteGen` into one module;
`WireMVCRouteGenPlugin` runs only the route half so another adapter's plugin can own the graph. This
spec covers what each plugin schedules, the `WireMVCRouteGen` command line, what `_WireRoutes.swift`
contains, how diagnostics are reported, and how the propagated imports are normalised. The swift-wire
plugin and WireGen command line are specified in swift-wire and linked below.

Documentation: [AddingWireMVCToAPackage](../../../Sources/WireMVC/WireMVC.docc/AddingWireMVCToAPackage.md), [PackageTraits](../../../Sources/WireMVC/WireMVC.docc/PackageTraits.md), [README](../../../README.md), [CONTRIBUTING](../../../CONTRIBUTING.md).

## Requirements

### Requirement: `WireMVCBuildPlugin` schedules WireGen and then WireMVCRouteGen
For a target with at least one Swift source, `WireMVCBuildPlugin` SHALL return two build commands in
order: `WireGen <target>` writing `_WireGraph.swift` and `_WireKeyChecks.swift`, then `WireMVCRouteGen
<target>` writing `_WireRoutes.swift`, all three under the plugin work directory. Both commands SHALL
declare the same input files. The plugin target SHALL depend on the `WireGen` product of swift-wire and
on `WireMVCRouteGen`.

#### Scenario: an executable applying the plugin
- **WHEN** `WireMVCBootstrapExample` lists `plugins: [.plugin(name: "WireMVCBuildPlugin", package: "wire-mvc")]`
- **THEN** the module compiles with a generated `_WireGraph` and a generated `_WireRoutes.swift` carrying its `@main`

Pinned by: `Fixtures/Package.swift` (`WireMVCBootstrapExample`), `.github/workflows/build.yml` (`BuildAndRun`, step `Build fixtures`).

### Requirement: `WireMVCRouteGenPlugin` schedules the route half only
`WireMVCRouteGenPlugin` SHALL return exactly one build command, `WireMVCRouteGen <target>` writing
`_WireRoutes.swift`, with the same dependency scan and the same arguments `WireMVCBuildPlugin` gives
WireMVCRouteGen. It SHALL NOT run WireGen. Both plugins SHALL be published as `.plugin` products
named `WireMVCBuildPlugin` and `WireMVCRouteGenPlugin`.

#### Scenario: composing with another adapter
- **WHEN** a target lists `WireBuildPlugin` from swift-wire and `WireMVCRouteGenPlugin` from wire-mvc
- **THEN** the graph is emitted once by `WireBuildPlugin` and the route witnesses by `WireMVCRouteGenPlugin`

Pinned by: nothing yet in this repository. The composing scenario is exercised by wire-open-api's [Fixtures/Package.swift](https://github.com/swift-wire/wire-open-api/blob/main/Fixtures/Package.swift) (target `WireOpenAPIBootstrapExample`) and its [build workflow](https://github.com/swift-wire/wire-open-api/blob/main/.github/workflows/build.yml) (job `Fixtures`, step `Serve an OpenAPI operation and a @Get route from one router`, the `mvc` probe of `GET /status/tasks`).

### Requirement: A target with no Swift sources gets no commands
Both plugins SHALL return an empty command list when the target has no source module or its source
module has no `.swift` files.

#### Scenario: a resources-only target
- **WHEN** either plugin is applied to a target whose source module lists no `.swift` file
- **THEN** no build command is scheduled

Pinned by: nothing yet.

### Requirement: The sources of every Wire-aware direct dependency are re-parsed
Both plugins SHALL walk the target's direct dependencies, both `.target` and `.product`, and for
each dependency's source module that itself depends on a target or product named `Wire` or `WireMVC`
SHALL add that module's Swift sources to the tool inputs, once per module name. A dependency that
depends on neither SHALL be skipped.

#### Scenario: a test target re-composing the app
- **WHEN** `WireMVCBootstrapExampleTests` depends on `WireMVCBootstrapExample` (which depends on `Wire`) and directly on the `WireMVC` product
- **THEN** the app's controllers and WireMVC's adapter directives are re-parsed into the test module, and its generated suite factory serves the app's routes

Pinned by: `Fixtures/Package.swift` (`WireMVCBootstrapExampleTests`), `.github/workflows/build.yml` (`BuildAndRun`, step `Test fixtures`).

### Requirement: WireGen receives `--testing-variants` only for a test target
`WireMVCBuildPlugin` SHALL pass WireGen the arguments `<graph> <keychecks> [--testing-variants]
--module <consumer> <consumer sources>` followed by one `--module <name> <sources>` group per
re-parsed `.target` dependency and one `--external-module <name> <sources>` group per re-parsed
`.product` dependency. `--testing-variants` SHALL be present when and only when
`sourceModule.kind == .test`.

#### Scenario: a test target declaring a `TestingKey`
- **WHEN** `WireMVCBootstrapExampleBindTests` declares a `TestingKey` with `@BindType` markers
- **THEN** WireGen is invoked with `--testing-variants` and the variant graph compiles into the test module

Pinned by: `Fixtures/Package.swift` (`WireMVCBootstrapExampleBindTests`), `.github/workflows/build.yml` (`BuildAndRun`, step `Test fixtures`).

### Requirement: WireMVCRouteGen receives `--test-entry` when the target links `WireMVCTesting`
Both plugins SHALL pass WireMVCRouteGen the arguments `<routes> [--test-entry] [--import <dep>]...
--module <consumer> <consumer sources>` followed by one `--module <name> <sources>` group per
re-parsed dependency. `--test-entry` SHALL be present when and only when the target depends,
directly or transitively, on a target named `WireMVCTesting`. Each re-parsed dependency module SHALL
be passed once as `--import <module>`.

#### Scenario: the program consumer
- **WHEN** `WireMVCBootstrapExample` has no dependency on `WireMVCTesting`
- **THEN** WireMVCRouteGen runs without `--test-entry` and `_WireRoutes.swift` carries the `@main`

#### Scenario: the test consumer
- **WHEN** `WireMVCBootstrapExampleTests` depends on the `WireMVCTesting` product
- **THEN** WireMVCRouteGen runs with `--test-entry` and `--import WireMVCBootstrapExample`, and `_WireRoutes.swift` carries the `.wiremvc(_:)` suite factory instead of a `@main`

Pinned by: `Fixtures/Package.swift` (`WireMVCBootstrapExample`, `WireMVCBootstrapExampleTests`), `.github/workflows/build.yml` (`BuildAndRun`, steps `Test fixtures` and `Run @WireMVCBootstrap example (boot, probe, stop)`).

### Requirement: The command line is `<out> [--test-entry] [--import M]... [--module M] files...`
`WireMVCRouteGen` SHALL take the output path as its first argument. Among the remaining arguments,
`--test-entry` SHALL set the test-entry flag, `--import <Module>` SHALL append an extra import,
`--module <Name>` SHALL attribute every following source path to that module until the next
`--module`, and any other argument SHALL be a source path. The first `--module` SHALL name the
consumer module. The argument after `--import` or `--module` SHALL be taken as the name whatever
its spelling, including one that begins with `--`. With no arguments at all, the tool SHALL print a
`usage:` line to standard error and exit `1`; an output path with no source paths SHALL produce the
header-and-imports-only file. With `--import` or `--module` as the last argument (no name following
it), or a source path that cannot be read, the tool SHALL write an `error:` line to standard error
and exit `1`.

#### Scenario: paths without attribution
- **WHEN** source paths are passed with no preceding `--module`
- **THEN** they are parsed and generated over, and carry no module attribution

#### Scenario: no arguments
- **WHEN** the tool is run with no arguments
- **THEN** it prints `usage: WireMVCRouteGen <output-path> [--test-entry] [--import <Module>]... <source-files...>` and exits `1`

#### Scenario: a trailing `--import`
- **WHEN** the last argument is `--import`
- **THEN** the tool prints `error: --import requires a module name` and exits `1`

Pinned by: nothing yet. The effect of the flags on generation is pinned by `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`generateEmitsTestServerEntryUnderTestEntryGate`, `keyedFactoryAssertsTheKeyItWasBuiltFor`, `noKeyIdentityAssertionWithoutModuleAttribution`, `aDependencysTestingKeyIsNotServed`).

### Requirement: Diagnostics print compiler-style and an error writes nothing
WireMVCRouteGen SHALL print every diagnostic to standard error as
`<file>:<line>:<column>: <label>: <message>`, where `<label>` is `warning` for a
`WireMVCDiagnostic` whose `severity` is `.warning` and `error` otherwise, and `<message>` is the
diagnostic's `message`. If any diagnostic is an error the tool SHALL exit `1` without writing the
output file. Only `bindingMissingSendConformance` and `routeOmittedFromClient` SHALL be warnings.

#### Scenario: an unannotated handler parameter
- **WHEN** `Bad.swift` declares `@Get("/x") @JSONResponse func f(id: String) -> Int` on line 5 of a `@Controller`
- **THEN** one diagnostic is produced, located at line 5, whose message is `handler parameter 'id' needs a binding annotation — one of @Path, @Query, @JSONBody, @Header`

#### Scenario: a warning alone
- **WHEN** the only diagnostic is a `bindingMissingSendConformance` warning
- **THEN** the line is labelled `warning`, the tool writes the output file and exits `0`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`fileLevelDiagnosticCarriesLocation`, `unannotatedParameterIsDiagnosed`). The exit code and the withheld output are pinned by nothing yet.

### Requirement: Propagated imports collapse to one internal import per module
`normalizedImports` SHALL fold every collected import declaration into one line per module path and
import-kind specifier, dropping the `public` or `package` modifier and any `@_exported`, keeping the
union of the other attributes sorted ahead of `import`, and SHALL emit the result sorted and
deduplicated. Given an `#if` block, `normalizedImports` SHALL rewrite the imports inside it in place
with the same rule and emit the block as it stands.

#### Scenario: one module at several access levels
- **WHEN** the collected imports include `public import Logging`, `package import Configuration`, `@_exported public import Domain` and `import Domain`
- **THEN** the generated file contains `import Domain`, `import Logging` and `import Configuration` once each and no `public import`, `package import` or `@_exported`

#### Scenario: a kind specifier
- **WHEN** both `import Foundation` and `import struct Foundation.Data` are collected
- **THEN** both lines are emitted, as distinct imports

Pinned by: `Tests/WireMVCCodegenTests/ImportNormalizationTests.swift` (`collapsesAccessLevels`, `dropsAccessModifier`, `dropsExported`, `unionsAttributes`, `keepsKindSpecifier`, `normalizesInsideIfConfig`, `sortsAndDeduplicates`, `generatedFileNormalizes`).

### Requirement: Only top-level `import` declarations are propagated
WireMVCRouteGen SHALL collect, from each parsed source, only the statements at file scope that are
`import` declarations. An import inside a top-level `#if` block SHALL NOT be collected, so it does
not reach `_WireRoutes.swift`; the `#if` handling in `normalizedImports` is reached only when the
function is called directly.

#### Scenario: a platform-guarded import
- **WHEN** a consumer source contains `#if canImport(FoundationEssentials)`, `import FoundationEssentials`, `#else`, `import Foundation`, `#endif` at file scope and no other import of those modules
- **THEN** `_WireRoutes.swift` contains neither `import FoundationEssentials` nor `import Foundation`

Pinned by: nothing yet.

### Requirement: `_WireRoutes.swift` has a fixed layout
The generated source SHALL begin with the line `// Generated by WireMVCRouteGen — do not edit.`,
followed by the normalised imports (always including `import WireMVC`), then the route-contributor
extensions sorted by name: one `extension _WireRouteContributor_<Controller>: RouteContributor` per
`@Controller` under the name `<Controller>`, and, under a keyed harness, one `extension
_<Variant>_WireRouteContributor_<Controller>: RouteContributor` per keyed subject under the name
`<Controller>Variant`. Then any typed clients sorted by controller name, then the bootstrap sources.
An input with no `@Controller` and no `@WireMVCBootstrap` SHALL produce the header and imports only.

#### Scenario: two controllers in one file
- **WHEN** `Controllers.swift` imports `Domain` and declares `Beta` before `Alpha`
- **THEN** the output starts with the header, contains `import Domain` and `import WireMVC`, and `extension _WireRouteContributor_Alpha` precedes `extension _WireRouteContributor_Beta`

#### Scenario: no controllers
- **WHEN** the only consumer source is `struct NotAController {}`
- **THEN** the output contains `import WireMVC` and no `extension`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`generatesSortedExtensionsWithImports`, `fileWithNoControllersEmitsHeaderOnly`). The variant extension's presence is pinned by `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`keyedHarnessEmitsDoublesAwareDispatchAndFactory`); its position in the sorted list is pinned by nothing yet.

### Requirement: A bootstrap root yields the global-middleware extension and exactly one entry
When the input declares a `@WireMVCBootstrap` root, WireMVCRouteGen SHALL add `import Wire`, emit
`extension _WireGlobalMiddleware_<Bootstrap>` carrying
`wrapGlobalMiddleware<Handler: HTTPServerRequestHandler>(_ inner: Handler)`, and emit one program
entry: without `--test-entry`, `@main struct _WireMVCBootstrapEntry` with `static func main() async
throws`; with `--test-entry`, `extension SuiteTrait where Self == WireMVCSuiteTrait` carrying
`static func wiremvc<WireMVCTestServerType: HTTPServer>(_ mode: WireMVCTestMode<WireMVCTestServerType>, …)`
plus `import WireMVCTesting` and `import Testing`. The two entries SHALL never both be emitted.

#### Scenario: the program entry
- **WHEN** `App.swift` declares `@Singleton @WireMVCBootstrap struct AppBootstrap` and the tool runs without `--test-entry`
- **THEN** the output contains `struct _WireMVCBootstrapEntry {`, `let bootstrap = graph.appBootstrap`, `import Wire`, and neither `import WireMVCTesting` nor `import Testing`

#### Scenario: the test entry
- **WHEN** the same root is generated with `--test-entry` and `--import WireMVCBootstrapExample`
- **THEN** the output contains no `@main`, contains `extension SuiteTrait where Self == WireMVCSuiteTrait {`, `static func wiremvc<WireMVCTestServerType: HTTPServer>(`, `import WireMVCTesting`, `import Testing` and `import WireMVCBootstrapExample`

#### Scenario: no global middleware
- **WHEN** the root carries no `@Middleware`
- **THEN** `wrapGlobalMiddleware` is still emitted and returns `inner` unchanged

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`bootstrapEntryGeneratesMain`, `generateEmitsBootstrapEntryAndWireImport`, `generateEmitsTestServerEntryUnderTestEntryGate`, `globalMiddlewareProxyWrapsRouterWithFactories`, `globalMiddlewareProxyIdentityWhenEmpty`).

### Requirement: `--import` modules are imported only when something generated needs them
The modules named by `--import` SHALL become `import <Module>` lines only when the output contains
at least one controller extension or a bootstrap entry.

#### Scenario: a re-composed app module
- **WHEN** the tool runs with `--import WireMVCBootstrapExample` over sources declaring a bootstrap root
- **THEN** the output contains `import WireMVCBootstrapExample`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`generateEmitsTestServerEntryUnderTestEntryGate`). The omission when nothing is generated is pinned by nothing yet.

### Requirement: The typed client is emitted only under `--test-entry`
WireMVCRouteGen SHALL emit a controller's typed client into `_WireRoutes.swift` only when
`--test-entry` is set. The client's route-omission diagnostics SHALL be collected whether or not the
client is emitted.

#### Scenario: a program consumer
- **WHEN** the tool runs without `--test-entry`
- **THEN** no typed client appears in the output

Pinned by: `Tests/WireMVCCodegenTests/ControllerClientGenerationTests.swift` (`theClientIsOnlyEmittedForATestConsumer`). Collecting the route-omission diagnostics without `--test-entry` is pinned by nothing yet.

### Requirement: `import WireTesting` is added only when a `TestingKey` is found
Under `--test-entry`, when a `TestingKey` is found in the consumer's sources, WireMVCRouteGen SHALL
add `import WireTesting`, whether or not a keyed harness is then emitted. A keyless test consumer
SHALL NOT import `WireTesting`.

#### Scenario: keyless and keyed
- **WHEN** the same bootstrap root is generated once without and once with a `TestingKey` in the consumer's sources
- **THEN** only the keyed output contains `import WireTesting`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`keyedHarnessImportsWireTestingAndKeylessDoesNot`).

### Requirement: The keyed harness needs a bootstrap root and a keyed subject
Under `--test-entry` with a `TestingKey` found, WireMVCRouteGen SHALL emit the keyed harness (the
`_WireMVCKeyed_<Variant>` statics and the keyed `.wiremvc(_ key:, _ mode:)` factory) beside the
keyless entry only when the input also declares a `@WireMVCBootstrap` root and at least one
`@Controller` that is `@Scoped(seed:)` or `@TestScopable`. Without both, no keyed harness SHALL be
emitted and no diagnostic SHALL be raised.

#### Scenario: a key, a root and a seed-scoped controller
- **WHEN** `App.swift` declares `@Singleton @WireMVCBootstrap struct AppBootstrap`, a `@Scoped(seed: HTTPRequest.self)` `NotesController`, and `enum Binds` holding `@BindType(NoteBackend.self, MockNoteBackend.self) static let mock = TestingKey()`, generated with `--test-entry`
- **THEN** the output contains `enum _WireMVCKeyed_Binds_mock {`, `extension _Binds_mock_WireRouteContributor_NotesController: RouteContributor` and `_ key: TestingKey, _ mode: WireMVCTestMode<WireMVCTestServerType>,`

#### Scenario: a key with only an app-scoped controller
- **WHEN** the same key and root are declared beside a `@Singleton` `@Controller` that is neither `@Scoped(seed:)` nor `@TestScopable`
- **THEN** the output contains `import WireTesting` and no `_WireMVCKeyed_` declaration

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`keyedHarnessEmitsDoublesAwareDispatchAndFactory`, `everyScopedControllerIsKeyedRegardlessOfInjection`, `mockConsumingFactoryFoldThreadsDoublesToCreate`). The omission without a root or a keyed subject is pinned by nothing yet.

### Requirement: A test target serves one `TestingKey`, from its own sources
Under `--test-entry`, WireMVCRouteGen SHALL serve the first `TestingKey` found in the sources
attributed to the consumer module, SHALL treat a source with no module attribution (every source,
when no `--module` is given) as the consumer's, and SHALL skip a `TestingKey` in a source attributed
to another module without a diagnostic. Every further `TestingKey` in the consumer's sources SHALL
be reported as a `multipleTestingKeys` error at its own declaration.

#### Scenario: a second key in the consumer
- **WHEN** the consumer's sources declare `OtherBinds.mock` and then `Binds.mock`, both `TestingKey`s
- **THEN** exactly one error is produced, against `Binds.mock`, whose message begins `the keyed test harness serves one TestingKey per target, and 'OtherBinds.mock' is already this target's key`

#### Scenario: a dependency's key
- **WHEN** `Lib.swift`, attributed to `SharedLib`, declares `LibBinds.mock` and `App.swift`, attributed to the consumer `MyTests`, declares `Binds.mock`
- **THEN** `Binds.mock` is served and no diagnostic is produced

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`aSecondTestingKeyIsRejected`, `aDependencysTestingKeyIsNotServed`, `withoutModuleAttributionEveryKeyIsStillEligible`). Which of the two keys the error is raised against is pinned by nothing yet.

### Requirement: `WireMVCRouteGen` is an executable product
The manifest SHALL publish `.executable(name: "WireMVCRouteGen", targets: ["WireMVCRouteGen"])` so
that a build plugin in another package can obtain it through `context.tool(named:
"WireMVCRouteGen")`, and the `WireMVCRouteGen` target SHALL depend only on `WireMVCCodegen`.

#### Scenario: another adapter's plugin
- **WHEN** a plugin in a package depending on wire-mvc calls `context.tool(named: "WireMVCRouteGen")`
- **THEN** it resolves to this package's route generator

Pinned by: nothing yet. No adapter plugin in the wire family calls `context.tool(named: "WireMVCRouteGen")` today; wire-open-api composes through `WireMVCRouteGenPlugin` instead.

### Requirement: The plugins are exercised only by the fixtures package
No target in the root `Package.swift` SHALL apply `WireMVCBuildPlugin` or `WireMVCRouteGenPlugin`;
every executable target in `Fixtures/Package.swift`, and every test target there except
`StreamingTierTests`, SHALL apply `WireMVCBuildPlugin`, and
CI SHALL build and test `Fixtures/` on every run so a plugin change is compiled and run.

#### Scenario: a type error in the plugin
- **WHEN** `swift build --target WireMVCBuildPlugin` is run at the repository root
- **THEN** the plugin is not type-checked, and the error surfaces only when `Fixtures/` builds

Pinned by: `.github/workflows/build.yml` (`BuildAndRun`, steps `Build fixtures` and `Test fixtures`), `Fixtures/Package.swift`.

## Related specifications

- [route-builder-contract](../route-builder-contract/spec.md)
- [composition-root](../composition-root/spec.md)
- [testing-harness](../testing-harness/spec.md)
- [package-traits](../package-traits/spec.md)
- [swift-wire build-plugin-and-wiregen-cli](https://github.com/swift-wire/swift-wire/blob/main/openspec/specs/build-plugin-and-wiregen-cli/spec.md)
- [wire-open-api build-plugins-and-gen-cli](https://github.com/swift-wire/wire-open-api/blob/main/openspec/specs/build-plugins-and-gen-cli/spec.md)
