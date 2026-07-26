import SwiftParser
import SwiftSyntax

// The keyed test harness's generated module-scope artifacts (H2.2b): the per-key doubles `TestBindStore`, the
// typed `withBindValues`, and the `.wiremvc(_:)` suite-trait factory. The factory bootstraps the key's
// **variant app graph** (`Wire.bootstrap<Variant>()` — production minus the mocked/lifted bindings and the
// scoped-subject proxies, so a mocked eager `@Singleton`'s `init` never runs under the keyed suite), then
// hand-registers each subject's routes from its variant proxy's `RouteContributor` witness (the variant
// graph's `routeContributors` carries only the surviving non-scoped controllers). Split from
// `BootstrapGeneration` (the keyless entry) and `RouteContributorGeneration` (the witness threading) so the
// keyed surface lives in one place. Emitted only for a test consumer whose composed sources declare a
// `TestingKey` with at least one matching `@Scoped(seed:)` subject.
//
// Per-request doubles ride the `X-WireMVC-Test-Binds` header → `TestBindStore` (correlated per request); the
// variant proxy is the registered instance, so the variant witness enters request scope directly with no
// production branch and no `@TaskLocal`. A keyless `.wiremvc()` suite serves the production graph; the two
// serve separate graphs, so they can't cross.

/// The keyed scope-entry descriptor for `controller` under `key`, or `nil` when the controller is not a
/// keyed variant subject. Under a `TestingKey`, **every** `@Scoped(seed:)` controller is a subject: swift-wire
/// emits a `Wire.bootstrap<Variant>_<Subject>Contributor` facade accepting the key's `_<Key>Doubles` for each
/// seed-scoped subject — one that uses a `@BindType`d slot (directly or through a `@Scopable`-lifted singleton,
/// or through a request-scoped intermediate) threads the mock, and one that uses none takes the doubles and
/// ignores them. So there is no selection heuristic to match on: the keyed dispatch is uniform, and a request
/// under a keyed suite always supplies doubles (else an explicit 500). `@Scopable` still marks the app
/// singletons swift-wire's cascade lifts into the scope; wire-mvc no longer reads it to select subjects.
func keyedScopeEntry(for controller: ControllerDeclaration, key: DiscoveredTestingKey) -> KeyedScopeEntry? {
    guard controller.scopedSeedType != nil else { return nil }
    return KeyedScopeEntry(
        harnessEnumName: key.harnessEnumName,
        doublesStoreName: harnessDoublesStoreName,
        keyReference: key.keyReference
    )
}

/// The keyed test harness's module-scope statics (H2.2b): the per-key namespace enum holding the doubles
/// ``TestBindStore``, plus the typed `withBindValues` the test calls. Emitted into the test module beside the
/// `.wiremvc(_:)` factory, referencing the `_<Key>Doubles` type WireGen emits in the same module. The store
/// correlates each request's doubles (by the `X-WireMVC-Test-Binds` header); the variant witness reads it per
/// request.
func renderKeyedHarnessStatics(key: DiscoveredTestingKey) -> String {
    var lines: [String] = ["enum \(key.harnessEnumName) {"]
    lines.append("    static let \(harnessDoublesStoreName) = TestBindStore<\(key.doublesTypeName)>()")
    lines.append("}")

    // The typed `withBindValues` — one parameter per `@BindType` slot, building the concrete `_<Key>Doubles`
    // and handing it to the H1 core with this key's store. `@discardableResult` mirrors the core.
    let parameters = key.substitutions.map { "\($0.fieldName): \($0.mockType)" }.joined(separator: ", ")
    let doublesArgs = key.substitutions.map { "\($0.fieldName): \($0.fieldName)" }.joined(separator: ", ")
    lines.append(
        """

        @discardableResult
        func withBindValues<R>(\(parameters), _ body: () async throws -> R) async throws -> R {
            try await WireMVCTesting.withBindValues(
                \(key.doublesTypeName)(\(doublesArgs)),
                in: \(key.harnessEnumName).\(harnessDoublesStoreName),
                body
            )
        }
        """
    )
    return Parser.parse(source: lines.joined(separator: "\n")).formatted().description
}

/// The generated keyed suite-trait factory `.wiremvc(_ key: TestingKey)` for a keyed test harness (H2.2b) —
/// emitted alongside the keyless `.wiremvc()`. It bootstraps the key's **variant app graph**
/// (`Wire.bootstrap<Variant>()`, so a mocked eager `@Singleton`'s `init` never runs here), registers the
/// surviving non-scoped controllers via `WireMVC.apply`, then hand-registers each subject's routes from its
/// variant proxy's `RouteContributor` witness (built from the variant graph via the
/// `Wire.bootstrap<Variant>_<Subject>Contributor` facade) — the variant graph's `routeContributors` no longer
/// carries the scoped-subject proxies. Per-request doubles ride the header → `TestBindStore`; the variant
/// witness reads them per request, so there's no `@TaskLocal` and no production branch. The keyless
/// `.wiremvc()` serves the production graph, so the two never cross. The `TestingKey` argument documents which
/// variant the suite selects; the single-key harness binds one variant, so the value itself isn't dispatched on.
func renderBootstrapKeyedTestEntry(
    bootstrap: ControllerDeclaration,
    notFoundRegistration: String,
    factoryKeys: Set<String>,
    key: DiscoveredTestingKey,
    subjects: [String]
) -> String {
    // Build each variant proxy from the variant graph and register its routes — before `finalize()`, so they
    // join the router. `WireMVC.apply` already registered the surviving non-scoped controllers.
    let variantRegistrations = subjects.map { subject in
        let facade = variantFacadeMethodName(variantName: key.variantName, subject: subject)
        let local = variantProxyLocalName(subject: subject)
        return """
            let \(local) = Wire.\(facade)(wireGraph: graph)
            try \(local).registerWireRoutes(on: &builder)
            """
    }
    .joined(separator: "\n")
    let buildLines = bootstrapBuildLines(
        bootstrap: bootstrap,
        notFoundRegistration: notFoundRegistration,
        factoryKeys: factoryKeys,
        bootstrapCall: "Wire.\(variantBootstrapMethodName(variantName: key.variantName))()",
        extraRegistrations: variantRegistrations
    )
    let raw = """
        extension SuiteTrait where Self == WireMVCSuiteTrait {
            static func wiremvc(_ key: TestingKey) -> WireMVCSuiteTrait {
                WireMVCSuiteTrait { runTests in
                    \(buildLines)
                    try await WireMVCTesting.serveForSuite(on: server, handler: wireMVCServed, services: services, runTests: runTests)
                }
            }
        }
        """
    return Parser.parse(source: raw).formatted().description
}

/// The keyed factory's local holding a subject's built variant proxy, which its routes are registered from.
private func variantProxyLocalName(subject: String) -> String { "wireMVCVariantProxy_" + subject }
