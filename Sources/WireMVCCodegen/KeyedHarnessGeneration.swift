import SwiftParser
import SwiftSyntax

// The keyed test harness's generated module-scope artifacts (H2.2b): the per-key statics (a doubles
// `TestBindStore` + a `@TaskLocal` variant-proxy holder per subject), the typed `withBindValues`, and the
// `.wiremvc(_:)` suite-trait factory that binds each subject's H2.2a variant proxy around `serveForSuite`.
// Split from `BootstrapGeneration` (the keyless entry) and `RouteContributorGeneration` (the witness
// threading) so the keyed surface lives in one place. Emitted only for a test consumer whose composed sources
// declare a `TestingKey` with at least one matching `@Scoped(seed:)` subject.
//
// The variant proxy travels a `@TaskLocal` bound around the serve (a suite-level value that rides the serve
// task tree into every request handler and isolates across concurrently-served suites), not a process-global
// holder — so a keyless `.wiremvc()` suite and a keyed suite can run in parallel without crossing.

/// The keyed scope-entry descriptor for `controller` under `key`, or `nil` when the controller is not a
/// variant subject: it must be `@Scoped(seed:)` AND directly inject a type the key touches — either a
/// `@BindType`d slot (Phase 1) or a `@Scopable`'d app singleton that reaches the mock (the Phase-2 cascade:
/// the mock threads through the lifted singleton into the controller, including at the singleton's `init`).
/// Matched by type, stripped of `any `. This is the direct-injection rule over both sets; a subject reaching
/// the mock only through a request-scoped intermediate that is itself neither `@BindType`d nor `@Scopable`'d
/// needs a transitive `@Inject`-graph walk wire-mvc can't see (a swift-wire follow-up). Deterministic.
func keyedScopeEntry(for controller: ControllerDeclaration, key: DiscoveredTestingKey) -> KeyedScopeEntry? {
    guard controller.scopedSeedType != nil else { return nil }
    let touched = Set(key.substitutions.map(\.slotType)).union(key.scopables)
    let injected = Set(controller.injectedTypes.map(strippingAny))
    guard !touched.isDisjoint(with: injected) else { return nil }
    return KeyedScopeEntry(
        harnessEnumName: key.harnessEnumName,
        doublesStoreName: harnessDoublesStoreName,
        doublesTypeName: key.doublesTypeName,
        variantProxyBoxName: variantProxyBoxName(subject: controller.name),
        subjectType: controller.selfType,
        keyReference: key.keyReference
    )
}

/// The keyed test harness's module-scope statics (H2.2b): the per-key namespace enum holding the doubles
/// ``TestBindStore`` and one `@TaskLocal` variant-proxy holder per subject, plus the typed `withBindValues`
/// the test calls. `subjects` are the matching `@Scoped(seed:)` controller names (a variant proxy each).
/// Emitted into the test module beside the `.wiremvc(_:)` factory, referencing the `_<Key>Doubles` and
/// variant-proxy types WireGen emits in the same module. The proxy holder is a `@TaskLocal` the factory binds
/// around `serveForSuite`; the dispatch reads its current value, so an unbound serving reads `nil`.
func renderKeyedHarnessStatics(key: DiscoveredTestingKey, subjects: [String]) -> String {
    var lines: [String] = ["enum \(key.harnessEnumName) {"]
    lines.append("    static let \(harnessDoublesStoreName) = TestBindStore<\(key.doublesTypeName)>()")
    for subject in subjects {
        let proxyType = variantProxyTypeName(variantName: key.variantName, subject: subject)
        lines.append("    @TaskLocal static var \(variantProxyBoxName(subject: subject)): \(proxyType)?")
    }
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
/// emitted alongside the keyless `.wiremvc()`. It inlines the same build as the keyless entry, builds each
/// variant subject's H2.2a proxy (from the graph via its `Wire.bootstrap<Variant>_<Subject>Contributor`
/// facade), and binds it to the per-key `@TaskLocal` *around* `serveForSuite` — so the proxy rides the serve
/// task tree into every request handler, and each scoped route's keyed dispatch enters request scope with the
/// correlated doubles. Binding around the serve (not a process-global) is what isolates concurrently-served
/// suites. The `TestingKey` argument documents which variant the suite selects; the single-key harness binds
/// one variant, so the value itself isn't dispatched on.
func renderBootstrapKeyedTestEntry(
    bootstrap: ControllerDeclaration,
    notFoundRegistration: String,
    factoryKeys: Set<String>,
    key: DiscoveredTestingKey,
    subjects: [String]
) -> String {
    let buildLines = bootstrapBuildLines(
        bootstrap: bootstrap,
        notFoundRegistration: notFoundRegistration,
        factoryKeys: factoryKeys
    )
    let proxyBindings = subjects.map { subject in
        let facade = variantFacadeMethodName(variantName: key.variantName, subject: subject)
        return "let \(variantProxyLocalName(subject: subject)) = Wire.\(facade)(wireGraph: graph)"
    }
    .joined(separator: "\n")
    // Nest one `$variantProxy_<Subject>.withValue` per subject *around* the serve, innermost first — the
    // task-local rides the serve task tree into every request handler.
    var served =
        "try await WireMVCTesting.serveForSuite(on: server, handler: wireMVCServed, services: services, runTests: runTests)"
    for subject in subjects.reversed() {
        served = """
            try await \(key.harnessEnumName).$\(variantProxyBoxName(subject: subject)).withValue(\(variantProxyLocalName(subject: subject))) {
            \(served)
            }
            """
    }
    let raw = """
        extension SuiteTrait where Self == WireMVCSuiteTrait {
            static func wiremvc(_ key: TestingKey) -> WireMVCSuiteTrait {
                WireMVCSuiteTrait { runTests in
                    \(buildLines)
                    \(proxyBindings)
                    \(served)
                }
            }
        }
        """
    return Parser.parse(source: raw).formatted().description
}

/// The keyed factory's local holding a subject's built variant proxy, before it is bound to the task-local.
private func variantProxyLocalName(subject: String) -> String { "wireMVCVariantProxy_" + subject }
