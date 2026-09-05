// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Foundation
import PackagePlugin

/// `WireMVCBuildPlugin` — the adapter-owned build-tool plugin for a WireMVC graph consumer.
/// It runs **two** tools into the consumer module, the two halves of a route contributor:
///   • `WireGen` (swift-wire's codegen executable) — the graph, the key checks, and the contributor
///     proxies' *structural* declarations (`_WireGraph.swift` / `_WireKeyChecks.swift`);
///   • `WireMVCRouteGen` (this package) — the route-contributor *witnesses* as extensions on those
///     proxies (`_WireRoutes.swift`).
/// The two agree only on the `_wireSubject` / `_wireFactory_<key>` field names. This supersedes applying
/// swift-wire's `WireBuildPlugin` directly: a WireMVC consumer applies THIS plugin, so the domain route
/// codegen (WireMVCRouteGen) runs alongside the graph codegen, both emitting into the same module.
///
///     .executableTarget(
///         name: "App",
///         dependencies: [.product(name: "WireMVC", package: "wire-mvc"), ...],
///         plugins: [.plugin(name: "WireMVCBuildPlugin", package: "wire-mvc")]
///     )
@main
struct WireMVCBuildPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let sourceModule = target.sourceModule else { return [] }
        let swiftSources = sourceModule.sourceFiles(withSuffix: "swift").map(\.url)
        guard !swiftSources.isEmpty else { return [] }

        let wireGen = try context.tool(named: "WireGen")  // swift-wire (external package)
        let routeGen = try context.tool(named: "WireMVCRouteGen")  // this package (the adapter)

        let graphURL = context.pluginWorkDirectoryURL.appendingPathComponent("_WireGraph.swift")
        let keyChecksURL = context.pluginWorkDirectoryURL.appendingPathComponent("_WireKeyChecks.swift")
        let routesURL = context.pluginWorkDirectoryURL.appendingPathComponent("_WireRoutes.swift")

        // Cross-module composition (same rule as swift-wire's WireBuildPlugin): re-parse the sources of
        // every Wire-aware library this target *directly* depends on — a library is Wire-aware when it
        // depends on the `Wire` product itself (see `dependsOnWireModules`; swift-wire retired the
        // hand-declared `_WireExports.swift` marker this replaced is retired) — so its controllers + bindings compose into
        // this consumer. Both tools read the same source set: WireGen for the graph + proxy structs,
        // WireMVCRouteGen for the witnesses (a controller may live in a shared library while its proxy is
        // emitted here).
        var dependencyGroups: [(module: String, sources: [URL], isExternal: Bool)] = []
        var seenModules: Set<String> = []
        for dependency in target.dependencies {
            let dependencyTargets: [Target]
            let isExternal: Bool
            switch dependency {
            case .target(let dependencyTarget):
                dependencyTargets = [dependencyTarget]
                isExternal = false
            case .product(let dependencyProduct):
                dependencyTargets = dependencyProduct.targets
                isExternal = true
            @unknown default:
                dependencyTargets = []
                isExternal = false
            }
            for dependencyTarget in dependencyTargets {
                guard let dependencyModule = dependencyTarget.sourceModule,
                    !seenModules.contains(dependencyModule.moduleName)
                else { continue }
                guard dependsOnWireModules(dependencyModule) else { continue }
                let dependencySources = dependencyModule.sourceFiles(withSuffix: "swift").map(\.url)
                seenModules.insert(dependencyModule.moduleName)
                dependencyGroups.append((dependencyModule.moduleName, dependencySources, isExternal))
            }
        }

        let allInputFiles = swiftSources + dependencyGroups.flatMap(\.sources)

        // Test-graph variants (`TestingKey` + `@BindType`) are emitted only for a **test** target. A variant
        // rewrites the key's slots to read from test-supplied doubles, so emitting one for a production
        // target would compile the variant graph — and every mock type it names — into the shipping binary.
        // Without this flag WireGen refuses any `TestingKey` it finds, which is what keeps one out of
        // production sources.
        //
        // Gated on the target's own kind, not on `testEntry` below: `testEntry` asks "does this target link
        // WireMVCTesting", which an *executable* can also answer yes to, and that is exactly the case the
        // gate exists to catch. The two signals agree for a real test target, and this matches the signal
        // swift-wire's own WireBuildPlugin uses, so a consumer sees the same rule whichever plugin it applies.
        let testingVariants = sourceModule.kind == .test ? ["--testing-variants"] : []

        // WireGen: graph + key checks + contributor-proxy structs. Sources grouped by module — the
        // consumer first (`--module`), then each Wire-aware dependency (`--module` / `--external-module`).
        var wireGenArguments =
            [graphURL.path, keyChecksURL.path] + testingVariants
            + ["--module", sourceModule.moduleName]
            + swiftSources.map(\.path)
        for group in dependencyGroups {
            let flag = group.isExternal ? "--external-module" : "--module"
            wireGenArguments += [flag, group.module] + group.sources.map(\.path)
        }

        // WireMVCRouteGen: the witness extensions. It scans every source for `@Controller` types, so it
        // takes the same flat source set (consumer + Wire-aware dependencies). A test consumer — one that
        // depends on the `WireMVCTesting` product — gets `--test-entry`, so a `@WireMVCBootstrap` root emits
        // the `.wiremvc()` suite-trait factory (and links the test client) instead of the `@main`; a program
        // consumer omits it and stays a plain executable. Each re-parsed Wire-aware dependency module is
        // passed as `--import`, so the emitted extensions (running in this consumer) can name that module's
        // `package`/`public` controllers, response types, and factories — needed when a test target
        // re-composes the app's graph.
        //
        // The generated live suite mode calls `serveForSuite`, which needs the app server's
        // `WireMVCTestServer` conformance in scope. That conformance is retroactive, so — as for any
        // retroactive conformance in Swift — the test target imports the module supplying it
        // (`WireMVCTestingNIOHTTPServer` for `NIOHTTPServer`) in one of its own sources. Conformance lookup
        // is module-wide, not file-scoped, so the import need not be in the generated file and the plugin
        // has nothing to discover.
        //
        // Sources are passed in `--module`-attributed groups (the same shape WireGen takes) so the keyed
        // harness can reconstruct the served `TestingKey`'s `#fileID` — `Module/File.swift` — and assert that
        // a suite passes the key this target actually serves. `--import` stays orthogonal: it names modules
        // the *generated* code must import, which is not the same set.
        let testEntry = dependsOnWireMVCTesting(target)
        var routeGenArguments =
            [routesURL.path]
            + (testEntry ? ["--test-entry"] : [])
            + dependencyGroups.flatMap { ["--import", $0.module] }
            + ["--module", sourceModule.moduleName] + swiftSources.map(\.path)
        for group in dependencyGroups {
            routeGenArguments += ["--module", group.module] + group.sources.map(\.path)
        }

        return [
            .buildCommand(
                displayName: "WireGen \(target.name)",
                executable: wireGen.url,
                arguments: wireGenArguments,
                inputFiles: allInputFiles,
                outputFiles: [graphURL, keyChecksURL]
            ),
            .buildCommand(
                displayName: "WireMVCRouteGen \(target.name)",
                executable: routeGen.url,
                arguments: routeGenArguments,
                inputFiles: allInputFiles,
                outputFiles: [routesURL]
            ),
        ]
    }

    /// Whether `target` depends — directly or transitively — on the `WireMVCTesting` product, i.e. it is a
    /// test consumer that should receive the `.wiremvc()` suite-trait factory (and link the test client)
    /// rather than the `@main`. The app executable does not depend on it (nothing it depends on pulls it in), so it
    /// reads `false`; each own-consumer test target names it directly, reading `true`.
    private func dependsOnWireMVCTesting(_ target: Target) -> Bool {
        var seen: Set<String> = []
        func visit(_ dependencies: [TargetDependency]) -> Bool {
            for dependency in dependencies {
                let dependencyTargets: [Target]
                switch dependency {
                case .target(let dependencyTarget):
                    dependencyTargets = [dependencyTarget]
                case .product(let dependencyProduct):
                    dependencyTargets = dependencyProduct.targets
                @unknown default:
                    dependencyTargets = []
                }
                for dependencyTarget in dependencyTargets {
                    if dependencyTarget.name == "WireMVCTesting" { return true }
                    guard seen.insert(dependencyTarget.name).inserted else { continue }
                    if visit(dependencyTarget.dependencies) { return true }
                }
            }
            return false
        }
        return visit(target.dependencies)
    }
}

/// Whether `module` can declare Wire bindings or WireMVC controllers — the signal that replaced the
/// hand-declared `_WireExports.swift` marker swift-wire has since retired.
///
/// A target that declares any of them must import `Wire` (for `@Singleton` / `@Scoped` / `@Inject`) or
/// `WireMVC` (for `@Controller` / `@Middleware`), and an import requires a dependency the plugin can read
/// at plan time. So the predicate cannot under-fire. Over-firing is harmless: a scanned library that
/// declares nothing contributes nothing, and since swift-wire's reachability pruning anything it does
/// declare that this consumer never reaches is stripped before it can cost anything or fail to resolve.
///
/// Both dependency kinds are matched by name, because inside wire-mvc's own package `WireMVC` is a target
/// dependency while to every consumer it is a product.
private func dependsOnWireModules(_ module: SourceModuleTarget) -> Bool {
    module.dependencies.contains { dependency in
        switch dependency {
        case .target(let target): return wireModuleNames.contains(target.name)
        case .product(let product): return wireModuleNames.contains(product.name)
        @unknown default: return false
        }
    }
}

/// The modules a Wire-aware library imports, and therefore depends on.
private let wireModuleNames: Set<String> = ["Wire", "WireMVC"]
