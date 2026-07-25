import SwiftParser
import SwiftSyntax

// The keyed test harness's generated module-scope artifacts (H2.2b): the per-key statics (a doubles
// `TestBindStore` + a `WireMVCVariantProxyBox` per variant subject), the typed `withBindValues`, and the
// `.wiremvc(_:)` suite-trait factory that parks each subject's H2.2a variant proxy before serving. Split from
// `BootstrapGeneration` (the keyless entry) and `RouteContributorGeneration` (the witness threading) so the
// keyed surface lives in one place. Emitted only for a test consumer whose composed sources declare a
// `TestingKey` with at least one matching `@Scoped(seed:)` subject.

/// The keyed scope-entry descriptor for `controller` under `key`, or `nil` when the controller is not a
/// variant subject: it must be `@Scoped(seed:)` AND inject a slot the key's `@BindType` substitutes (matched
/// by type, stripped of `any `). This is the single-key direct-injection rule — a subject reached only
/// through a `@Scopable`-lifted singleton is a follow-up. Deterministic (set membership, no ordering).
func keyedScopeEntry(for controller: ControllerDeclaration, key: DiscoveredTestingKey) -> KeyedScopeEntry? {
    guard controller.scopedSeedType != nil else { return nil }
    let slots = Set(key.substitutions.map(\.slotType))
    let injected = Set(controller.injectedTypes.map(strippingAny))
    guard !slots.isDisjoint(with: injected) else { return nil }
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
/// ``TestBindStore`` and one ``WireMVCVariantProxyBox`` per variant subject, plus the typed `withBindValues`
/// the test calls. `subjects` are the matching `@Scoped(seed:)` controller names (a variant proxy each).
/// Emitted into the test module beside the `.wiremvc(_:)` factory, referencing the `_<Key>Doubles` and
/// variant-proxy types WireGen emits in the same module.
func renderKeyedHarnessStatics(key: DiscoveredTestingKey, subjects: [String]) -> String {
    var lines: [String] = ["enum \(key.harnessEnumName) {"]
    lines.append("    static let \(harnessDoublesStoreName) = TestBindStore<\(key.doublesTypeName)>()")
    for subject in subjects {
        let boxType = variantProxyTypeName(variantName: key.variantName, subject: subject)
        lines.append("    static let \(variantProxyBoxName(subject: subject)) = WireMVCVariantProxyBox<\(boxType)>()")
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
/// emitted alongside the keyless `.wiremvc()`. It inlines the same build as the keyless entry, then parks each
/// variant subject's H2.2a proxy (built from the graph via its `Wire.bootstrap<Variant>_<Subject>Contributor`
/// facade) in the per-key box before serving, so each scoped route's keyed dispatch can enter request scope
/// with the correlated doubles. The `TestingKey` argument documents which variant the suite selects; the
/// single-key harness binds one variant, so the value itself isn't dispatched on.
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
    let parkProxies = subjects.map { subject in
        let facade = variantFacadeMethodName(variantName: key.variantName, subject: subject)
        return "\(key.harnessEnumName).\(variantProxyBoxName(subject: subject)).set(Wire.\(facade)(wireGraph: graph))"
    }
    .joined(separator: "\n")
    let raw = """
        extension SuiteTrait where Self == WireMVCSuiteTrait {
            static func wiremvc(_ key: TestingKey) -> WireMVCSuiteTrait {
                WireMVCSuiteTrait { runTests in
                    \(buildLines)
                    \(parkProxies)
                    try await WireMVCTesting.serveForSuite(on: server, handler: wireMVCServed, services: services, runTests: runTests)
                }
            }
        }
        """
    return Parser.parse(source: raw).formatted().description
}
