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
/// keyed variant subject. A variant subject is either a `@Scoped(seed:)` controller (every one is keyed —
/// "key-all") or an app-`@Singleton` `@TestScopable` controller (rebuilt per request seedlessly). swift-wire
/// emits a `Wire.bootstrap<Variant>_<Subject>Contributor` facade for each; the seed-scoped path threads the
/// doubles through `_wireEnterScope(request, doubles)`, the seedless path through `_wireEnterScope(doubles)`.
/// A request under a keyed suite always supplies doubles (else an explicit 500). The `RouteBlockGenerator`
/// selects the seed vs seedless dispatch from the controller's own `scopedSeedType`.
func keyedScopeEntry(for controller: ControllerDeclaration, key: DiscoveredTestingKey) -> KeyedScopeEntry? {
    guard controller.scopedSeedType != nil || controller.isTestScopable else { return nil }
    return KeyedScopeEntry(
        harnessEnumName: key.harnessEnumName,
        doublesStoreName: harnessDoublesStoreName(subject: controller.name),
        keyReference: key.keyReference,
        subject: controller.name
    )
}

/// The keyed test harness's module-scope statics (H2.2b): the per-key namespace enum holding the doubles
/// ``TestBindStore``, plus the typed `withBindValues` the test calls. Emitted into the test module beside the
/// `.wiremvc(_:)` factory, referencing the `_<Key>Doubles` type WireGen emits in the same module. The store
/// correlates each request's doubles (by the `X-WireMVC-Test-Binds` header); the variant witness reads it per
/// request.
func renderKeyedHarnessStatics(
    key: DiscoveredTestingKey,
    subjects: [String],
    clientSubjects: Set<String>
) -> String {
    // One store per routed subject: each subject's `_wireEnterScope` takes its own doubles type, so a single
    // key-wide store could not type-check against all of them.
    var lines: [String] = ["enum \(key.harnessEnumName) {"]
    for subject in subjects {
        let doublesType = subjectDoublesTypeName(variantName: key.variantName, subject: subject)
        lines.append("    static let \(harnessDoublesStoreName(subject: subject)) = TestBindStore<\(doublesType)>()")
    }
    lines.append("}")

    // The call-site alias and the `withClient(supplying:)` overload, per subject. wire-mvc cannot derive
    // *which* slots a controller reaches — that is the graph fact swift-wire owns and why it emits the struct —
    // so the parameter list is the generated memberwise init rather than something spelled here. Overloading on
    // the doubles *type* keeps one verb at every call site:
    // `withClient(supplying: NotesControllerDoubles(noteBackend:))` resolves to the notes store, and supplying a
    // slot that controller doesn't reach is a compile error. `@discardableResult` mirrors the core.
    //
    // The body receives that controller's typed client, so the doubles a test supplies and the routes it can
    // call arrive together and name the same controller. It is the same verb as the no-doubles
    // `withClient(for:)` because it is the same operation — obtain a client — differing only in whether a
    // binding rides along. A controller with no typed route (every route `@RawRoute`, or none annotated) has no
    // typed client to hand over, so its body takes the untyped one.
    for subject in subjects {
        let doublesType = subjectDoublesTypeName(variantName: key.variantName, subject: subject)
        let clientType = clientSubjects.contains(subject) ? controllerClientTypeName(subject) : nil
        let bodyParameter = clientType.map { "(\($0)) async throws -> R" } ?? "(TestClient) async throws -> R"
        let bodyCall =
            clientType.map { "try await body(\($0)(client: wireMVCClient))" } ?? "try await body(wireMVCClient)"
        lines.append(
            """

            typealias \(subjectDoublesAliasName(subject: subject)) = \(doublesType)

            @discardableResult
            func withClient<R>(
                supplying doubles: \(doublesType),
                _ body: \(bodyParameter)
            ) async throws -> R {
                try await WireMVCTesting.withClient(
                    supplying: doubles,
                    in: \(key.harnessEnumName).\(harnessDoublesStoreName(subject: subject))
                ) { wireMVCClient in
                    \(bodyCall)
                }
            }
            """
        )
    }
    return Parser.parse(source: lines.joined(separator: "\n")).formatted().description
}

/// The `withClient` family — a client carrying **no** doubles. One overload per controller with a typed
/// client (`withClient(for: NotesControllerClient.self) { notes in … }`), plus an untyped one for the paths no
/// controller declares: the `@NotFound` fallback, the Bootstrap's introspection mount, and any request a test
/// wants to malform deliberately.
///
/// The overload keys on the **client** type rather than the controller: a controller may be generic
/// (`HelloController<G: Greeter>`), which cannot be spelled as a bare metatype, while its generated client
/// never is.
///
/// Emitted for every test consumer, keyed or not. In a keyless suite it is how a test reaches a client at all;
/// in a keyed one it is how a test drives a route *without* supplying doubles — which the harness answers with
/// its explicit 500, the behaviour `missingDoublesIsExplicit500` pins.
func renderClientAccessors(controllersWithClients: [String]) -> String {
    var blocks: [String] = [
        """
        /// A client for requests that name no controller — the `@NotFound` fallback, `/wiring`, or a
        /// deliberately malformed request. Carries no doubles.
        @discardableResult
        func withClient<R>(_ body: (TestClient) async throws -> R) async throws -> R {
            try await WireMVCTesting.withClient(body)
        }
        """
    ]
    for controller in controllersWithClients {
        blocks.append(
            """
            /// `\(controller)`'s routes, with no doubles supplied.
            @discardableResult
            func withClient<R>(
                for _: \(controllerClientTypeName(controller)).Type,
                _ body: (\(controllerClientTypeName(controller))) async throws -> R
            ) async throws -> R {
                try await WireMVCTesting.withClient { wireMVCClient in
                    try await body(\(controllerClientTypeName(controller))(client: wireMVCClient))
                }
            }
            """
        )
    }
    return Parser.parse(source: blocks.joined(separator: "\n\n")).formatted().description
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
    // The mode is orthogonal to the key: the key picks which variant graph is bootstrapped, the mode picks
    // the transport it is reached over. Same single build path as the keyless factory — only the bootstrap
    // call and the variant-proxy registrations differ.
    let raw = """
        extension SuiteTrait where Self == WireMVCSuiteTrait {
        \(suiteFactory(
            signatureParameters: "_ key: TestingKey, _ mode: WireMVCTestMode<WireMVCTestServerType>",
            bootstrap: bootstrap,
            notFoundRegistration: notFoundRegistration,
            factoryKeys: factoryKeys,
            bootstrapCall: "Wire.\(variantBootstrapMethodName(variantName: key.variantName))()",
            extraRegistrations: variantRegistrations
        ))
        }
        """
    return Parser.parse(source: raw).formatted().description
}

/// The keyed factory's local holding a subject's built variant proxy, which its routes are registered from.
private func variantProxyLocalName(subject: String) -> String { "wireMVCVariantProxy_" + subject }
