import Foundation
import PackagePlugin

/// `WireMVCBuildPlugin` — the adapter-owned build-tool plugin for a WireMVC graph consumer (Phase A).
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
        // every Wire-aware library this target *directly* depends on — a library opts in with a
        // `_WireExports.swift` marker — so its controllers + bindings compose into this consumer. Both
        // tools read the same source set: WireGen for the graph + proxy structs, WireMVCRouteGen for the
        // witnesses (a controller may live in a shared library while its proxy is emitted here).
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
                let dependencySources = dependencyModule.sourceFiles(withSuffix: "swift").map(\.url)
                let isWireAware = dependencySources.contains { $0.lastPathComponent == "_WireExports.swift" }
                guard isWireAware else { continue }
                seenModules.insert(dependencyModule.moduleName)
                dependencyGroups.append((dependencyModule.moduleName, dependencySources, isExternal))
            }
        }

        let allInputFiles = swiftSources + dependencyGroups.flatMap(\.sources)

        // WireGen: graph + key checks + contributor-proxy structs. Sources grouped by module — the
        // consumer first (`--module`), then each Wire-aware dependency (`--module` / `--external-module`).
        var wireGenArguments =
            [graphURL.path, keyChecksURL.path, "--module", sourceModule.moduleName]
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
        let testEntry = dependsOnWireMVCTesting(target)
        let routeGenArguments =
            [routesURL.path]
            + (testEntry ? ["--test-entry"] : [])
            + dependencyGroups.flatMap { ["--import", $0.module] }
            + allInputFiles.map(\.path)

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
