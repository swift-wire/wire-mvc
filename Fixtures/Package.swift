// swift-tools-version: 6.4
import PackageDescription

// wire-mvc's runnable fixtures — the two example executables and the integration suites that drive them
// over real HTTP. They live in their own package, alongside the framework rather than inside it, for one
// reason: they serve on `NIOHTTPServer`, and anything in wire-mvc's own manifest that names
// `swift-http-server` unconditionally puts the whole NIO stack into the `Package.resolved` of *every*
// downstream consumer — SwiftPM prunes a package dependency only when its every product dependency is
// behind an off-by-default trait, never by target reachability. wire-mvc gates its one NIO reference on the
// `NIOHTTPServer` trait; these fixtures enable it.
//
// The alternative was `#if NIOHTTPServer` around a dozen fixture files, which would leave wire-mvc's default
// build with everything interesting switched off. Moving them keeps both packages unconditional.
//
// Run from this directory: `swift build`, `swift run WireMVCExample`, `swift test`.
let proposalSettings: [SwiftSetting] = [
    .strictMemorySafety(),
    .enableExperimentalFeature("SuppressedAssociatedTypesWithDefaults"),
    .enableExperimentalFeature("LifetimeDependence"),
    .enableExperimentalFeature("Lifetimes"),
    .enableUpcomingFeature("LifetimeDependence"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "wire-mvc-fixtures",
    platforms: [.macOS(.v26)],
    dependencies: [
        // The framework under test, with the NIO test support switched on — that trait is what gives
        // `WireMVCTesting` the `NIOHTTPServer: WireMVCTestServer` conformance and the `.swiftHttpServer`
        // suite mode, and it is the only thing that pulls `swift-http-server` into this graph.
        .package(path: "..", traits: ["NIOHTTPServer"]),
        .package(url: "https://github.com/tachyonics/swift-wire.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-http-api-proposal.git", .upToNextMinor(from: "0.2.0")),
        .package(
            url: "https://github.com/apple/swift-async-algorithms.git",
            exact: "1.1.5",
            traits: ["UnstableAsyncStreaming"]
        ),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.6.0"),
        .package(url: "https://github.com/swift-server/swift-http-server.git", branch: "main"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.13.2"),
    ],
    targets: [
        // The full-matrix self-checker: hand-written assembly (no `@WireMVCBootstrap`), serving every
        // route shape on `NIOHTTPServer` and driving each over real HTTP. Runs to completion and exits
        // non-zero on any mismatch, so CI runs it as a program rather than a test.
        .executableTarget(
            name: "WireMVCExample",
            dependencies: [
                .product(name: "WireMVC", package: "wire-mvc"),
                .product(name: "WireMVCRouter", package: "wire-mvc"),
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "HTTPAPIs", package: "swift-http-api-proposal"),
                .product(name: "AsyncStreaming", package: "swift-async-algorithms"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "BasicContainers", package: "swift-collections"),
                .product(name: "NIOHTTPServer", package: "swift-http-server"),
                .product(name: "Logging", package: "swift-log"),
                // The generated `_WireGraph: WireMVCComposable` conformance references `any Service`.
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            swiftSettings: proposalSettings,
            plugins: [.plugin(name: "WireMVCBuildPlugin", package: "wire-mvc")]
        ),
        // The WireMVC-native composition root — a thin `@Singleton @WireMVCBootstrap` app whose `@main` is
        // *generated*. Its correctness is the compile gate plus the codegen golden test; CI additionally
        // boots it and probes it, since a generated `@main` that serves indefinitely can't run to
        // completion. No `WireMVCTesting` dependency: without it the plugin generates the `@main` (a program
        // consumer) and NOT the `.wiremvc(_:)` suite-trait factory, so the executable never links the test
        // client. The test targets below opt in by depending on `WireMVCTesting`.
        .executableTarget(
            name: "WireMVCBootstrapExample",
            dependencies: [
                .product(name: "WireMVC", package: "wire-mvc"),
                .product(name: "WireMVCRouter", package: "wire-mvc"),
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "HTTPAPIs", package: "swift-http-api-proposal"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "BasicContainers", package: "swift-collections"),  // UniqueArray (@NotFound body)
                .product(name: "NIOHTTPServer", package: "swift-http-server"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            swiftSettings: proposalSettings,
            plugins: [.plugin(name: "WireMVCBuildPlugin", package: "wire-mvc")]
        ),
        // Integration test on the REAL graph. Its own `WireMVCBuildPlugin` re-composes the app's graph (the
        // app carries `_WireExports.swift`) — inheriting `RealGreeter` unchanged. Depending on
        // `WireMVCTesting` makes the plugin emit the `.wiremvc(_:)` suite-trait factory (not a `@main`,
        // which can't live in a test bundle); the suite runs `.swiftHttpServer` — a harness-owned server on
        // an ephemeral loopback port — and drives `GET /hello/Alice` over real HTTP.
        .testTarget(
            name: "WireMVCBootstrapExampleTests",
            dependencies: [
                "WireMVCBootstrapExample",
                .product(name: "WireMVCTesting", package: "wire-mvc"),
                // A direct dependency so the plugin re-parses WireMVC's adapter directives
                // (`wireMVCControllerAlias` / `wireMVCBootstrapAlias` / `wireMVCComposition`) when
                // re-composing the app's graph — without it WireGen wouldn't synthesise the route-contributor
                // proxies, the global-middleware proxy, or the `WireMVCComposable` conformance.
                .product(name: "WireMVC", package: "wire-mvc"),
                .product(name: "WireMVCRouter", package: "wire-mvc"),
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "HTTPAPIs", package: "swift-http-api-proposal"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "BasicContainers", package: "swift-collections"),
                .product(name: "NIOHTTPServer", package: "swift-http-server"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            swiftSettings: proposalSettings,
            plugins: [.plugin(name: "WireMVCBuildPlugin", package: "wire-mvc")]
        ),
        // The FAKE-graph test: same re-composition, but its `@Replaces FakeGreeter` supersedes the app's
        // `RealGreeter`. `GET /hello/Alice` returns the fake's `FAKE:Alice` — proving `@Replaces` swapped the
        // app's real binding for the test double. A separate target because `@Replaces` is target-wide, so
        // the real-graph integration suite and this fake-graph suite can't share one.
        //
        // Also the `.inProcess` gate, and the clearest demonstration of what the mode API buys: this target
        // names NO concrete server. The generated factory is generic over whatever server its
        // `WireMVCTestMode` carries, so a socket-free suite depends on neither `NIOHTTPServer` nor the NIO
        // trait's test support — unlike its two live siblings.
        .testTarget(
            name: "WireMVCBootstrapExampleReplaceTests",
            dependencies: [
                "WireMVCBootstrapExample",
                .product(name: "WireMVCTesting", package: "wire-mvc"),
                // Direct dependency so the plugin re-parses WireMVC's adapter directives — see the sibling
                // integration test target.
                .product(name: "WireMVC", package: "wire-mvc"),
                .product(name: "WireMVCRouter", package: "wire-mvc"),
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "HTTPAPIs", package: "swift-http-api-proposal"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "BasicContainers", package: "swift-collections"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            swiftSettings: proposalSettings,
            plugins: [.plugin(name: "WireMVCBuildPlugin", package: "wire-mvc")]
        ),
        // H2.2b — the keyed test harness. Re-composes the app's graph and declares a `TestingKey` whose
        // `@BindType` binds the app's request-scoped `NoteBackend` to a mock. The generated keyed
        // `.wiremvc(NoteTestBinds.mockBackend, .swiftHttpServer)` factory threads a `withBindValues`-supplied
        // mock into request scope through the variant contributor proxy, so `GET /notes/{id}` observes the
        // mock over real HTTP.
        .testTarget(
            name: "WireMVCBootstrapExampleBindTests",
            dependencies: [
                "WireMVCBootstrapExample",
                .product(name: "WireMVCTesting", package: "wire-mvc"),
                .product(name: "WireMVC", package: "wire-mvc"),
                .product(name: "WireMVCRouter", package: "wire-mvc"),
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "HTTPAPIs", package: "swift-http-api-proposal"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "BasicContainers", package: "swift-collections"),
                .product(name: "NIOHTTPServer", package: "swift-http-server"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            swiftSettings: proposalSettings,
            plugins: [.plugin(name: "WireMVCBuildPlugin", package: "wire-mvc")]
        ),
    ]
)
