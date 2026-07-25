import SwiftSyntax

// Discovery of the `TestingKey` a keyed test harness declares (H2.2b), and the derived names the generated
// keyed factory + dispatch bind to. A `TestingKey` static carries `@BindType(Slot.self, Mock.self)` markers
// (and, in the cascade case, `@Scopable(X.self)`); this reads them the way `RouteContributorGeneration`'s
// `FactoryKeyFinder`/`ControllerFinder` read their attributes, and reconstructs the same `(enclosingType,
// member)` reference — and the same `_<Key>Doubles` / variant-proxy / facade names — swift-wire's WireGen
// derives from it. The two sides must agree on those names blind, so both restate the identical rules.
//
// Scope is the single-`TestingKey` common case: the first key found drives the harness. A `@BindType`'s
// keyed slot form (`@BindType(Repo.primary, Mock.self)`) is out of scope here — the harness matches a scoped
// controller's injected slot by type — and is skipped.

/// One `@BindType(Slot.self, Mock.self)` substitution on a `TestingKey` — the doubles field it contributes.
public struct TestingBindSubstitution: Sendable, Equatable {
    /// The slot type as written, stripped of a leading `any ` (`"NoteBackend"`) — matched against a scoped
    /// controller's injected member type to decide whether that controller is a variant subject.
    public let slotType: String
    /// The concrete mock type the slot binds to (`"MockNoteBackend"`) — the doubles field's type and the
    /// generated `withBindValues` parameter's type.
    public let mockType: String
    /// The `_<Key>Doubles` field name for this slot — WireGen's `identifierName(forType:)` of the stripped
    /// slot type (first character lowercased): `NoteBackend` → `noteBackend`.
    public var fieldName: String { lowerCamelFirst(slotType.split(separator: ".").last.map(String.init) ?? slotType) }
}

/// A discovered `TestingKey` and the names the keyed harness derives from it. Constructed only by
/// ``discoverTestingKey(in:)``.
public struct DiscoveredTestingKey: Sendable, Equatable {
    /// The canonical reference text — `"NoteTestBinds.mockBackend"` for a `static let mockBackend` on
    /// `NoteTestBinds`. The variant/doubles names derive from it.
    public let keyReference: String
    /// The `@BindType` substitutions, in source order.
    public let substitutions: [TestingBindSubstitution]
    /// The `@Scopable(X.self)` type names, in source order — surfaced for completeness; the single-key
    /// direct-injection harness matches subjects by their injected slot, not by these.
    public let scopables: [String]

    /// The variant name — the key reference with `.` → `_` (`"NoteTestBinds_mockBackend"`). Prefixes the
    /// doubles struct, the variant proxy type, and the facade method, matching WireGen.
    public var variantName: String { keyReference.split(separator: ".").map(String.init).joined(separator: "_") }

    /// The `_<Key>Doubles` struct type name — `_` + dot-joined-with-`_` reference + `Doubles`
    /// (`"_NoteTestBinds_mockBackendDoubles"`). Matches WireGen's `doublesStructTypeName(forKeyReference:)`.
    public var doublesTypeName: String { "_" + variantName + "Doubles" }

    /// The generated per-key harness namespace enum — holds the doubles ``TestBindStore`` and, per subject,
    /// a ``WireMVCVariantProxyBox``. `_`-prefixed to stay out of user code's namespace.
    public var harnessEnumName: String { "_WireMVCKeyed_" + variantName }
}

/// What a variant subject's scoped route dispatch needs to emit its keyed branch — the per-key harness
/// namespace, the doubles store + variant-proxy box members on it, the subject type for the scope-entry
/// tuple annotation, and the key reference for the missing-doubles 500 message. Built per matching
/// controller by ``renderControllerExtensions`` and threaded into ``RouteBlockGenerator``.
public struct KeyedScopeEntry: Sendable, Equatable {
    public let harnessEnumName: String
    public let doublesStoreName: String
    public let doublesTypeName: String
    public let variantProxyBoxName: String
    public let subjectType: String
    public let keyReference: String

    public init(
        harnessEnumName: String,
        doublesStoreName: String,
        doublesTypeName: String,
        variantProxyBoxName: String,
        subjectType: String,
        keyReference: String
    ) {
        self.harnessEnumName = harnessEnumName
        self.doublesStoreName = doublesStoreName
        self.doublesTypeName = doublesTypeName
        self.variantProxyBoxName = variantProxyBoxName
        self.subjectType = subjectType
        self.keyReference = keyReference
    }
}

/// The doubles ``TestBindStore`` member name inside the generated per-key harness enum.
public let harnessDoublesStoreName = "doubles"

/// The variant contributor-proxy type name for a subject under a key — `_<Variant>_WireRouteContributor_<Subject>`
/// (`"_NoteTestBinds_mockBackend_WireRouteContributor_NotesController"`). Mirrors WireGen's
/// `variantContributorProxy` renaming (`_<VariantName>` + the production proxy type name).
public func variantProxyTypeName(variantName: String, subject: String) -> String {
    "_\(variantName)_WireRouteContributor_\(subject)"
}

/// The `Wire.bootstrap<Variant>_<Subject>Contributor` facade method name — the non-async/throwing static
/// that builds the variant proxy from the graph (`"bootstrapNoteTestBinds_mockBackend_NotesControllerContributor"`).
/// Mirrors WireGen's `buildVariantContributorFacades`.
public func variantFacadeMethodName(variantName: String, subject: String) -> String {
    "bootstrap\(variantName)_\(subject)Contributor"
}

/// The per-subject ``WireMVCVariantProxyBox`` static's name inside the harness enum.
public func variantProxyBoxName(subject: String) -> String {
    "variantProxy_" + subject
}

/// Lower-camel a type's simple name by lowercasing only its first character — WireGen's `identifierName`
/// rule for a plain identifier (`HTTPClient` → `hTTPClient`, `NoteBackend` → `noteBackend`).
func lowerCamelFirst(_ name: String) -> String {
    guard let first = name.first else { return name }
    return first.lowercased() + name.dropFirst()
}

/// Find the harness's `TestingKey` across the parsed sources — the first `static let`/module-scope `let`
/// initialised with `TestingKey()` (or annotated `: TestingKey`), with its `@BindType`/`@Scopable` markers.
/// `nil` when there is none (the keyless path). Single-key scope: a second key is ignored (a follow-up).
public func discoverTestingKey(in sourceFiles: [SourceFileSyntax]) -> DiscoveredTestingKey? {
    for tree in sourceFiles {
        let finder = TestingKeyFinder()
        finder.walk(tree)
        if let key = finder.key { return key }
    }
    return nil
}

/// Walks a parsed file for a `TestingKey` static and reads its `@BindType`/`@Scopable` markers, tracking the
/// enclosing type names so the key reference reconstructs as `Enclosing.member`.
private final class TestingKeyFinder: SyntaxVisitor {
    private(set) var key: DiscoveredTestingKey?
    private var enclosing: [String] = []

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { push(node.name.text); return .visitChildren }
    override func visitPost(_ node: EnumDeclSyntax) { pop() }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { push(node.name.text); return .visitChildren }
    override func visitPost(_ node: StructDeclSyntax) { pop() }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { push(node.name.text); return .visitChildren }
    override func visitPost(_ node: ClassDeclSyntax) { pop() }

    private func push(_ name: String) { enclosing.append(name) }
    private func pop() { if !enclosing.isEmpty { enclosing.removeLast() } }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard key == nil,
            node.bindings.count == 1,
            let binding = node.bindings.first,
            let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
            namesTestingKey(annotation: binding.typeAnnotation?.type, initializer: binding.initializer?.value)
        else { return .visitChildren }

        let reference = (enclosing + [pattern.identifier.text]).joined(separator: ".")
        let substitutions = node.attributes.compactMap { element -> TestingBindSubstitution? in
            guard case let .attribute(attribute) = element,
                attribute.attributeName.trimmedDescription == "BindType"
            else { return nil }
            return bindSubstitution(from: attribute)
        }
        let scopables = node.attributes.compactMap { element -> String? in
            guard case let .attribute(attribute) = element,
                attribute.attributeName.trimmedDescription == "Scopable"
            else { return nil }
            return metatypeBase(ofFirstArgumentOf: attribute)
        }
        key = DiscoveredTestingKey(keyReference: reference, substitutions: substitutions, scopables: scopables)
        return .visitChildren
    }

    /// Read one `@BindType(Slot.self, Mock.self)` into a substitution — the type form only (a keyed-slot
    /// `@BindType(Repo.primary, Mock.self)` is out of the single-key harness's subject-by-type matching, so
    /// it is skipped). `nil` for a malformed attribute the macro would already have rejected.
    private func bindSubstitution(from attribute: AttributeSyntax) -> TestingBindSubstitution? {
        guard case let .argumentList(args) = attribute.arguments, args.count == 2,
            let slot = metatypeBase(of: args.first!.expression),
            let mock = metatypeBase(of: args.last!.expression)
        else { return nil }
        return TestingBindSubstitution(slotType: strippingAny(slot), mockType: mock)
    }

    private func metatypeBase(ofFirstArgumentOf attribute: AttributeSyntax) -> String? {
        guard case let .argumentList(args) = attribute.arguments, let first = args.first else { return nil }
        return metatypeBase(of: first.expression)
    }

    /// The base type of a `.self` metatype expression — `Repo` for `Repo.self` — or `nil` when it isn't one.
    private func metatypeBase(of expression: ExprSyntax) -> String? {
        guard let memberAccess = expression.as(MemberAccessExprSyntax.self),
            memberAccess.declName.baseName.text == "self",
            let base = memberAccess.base
        else { return nil }
        return base.trimmedDescription
    }

    /// Whether a declaration's annotation or initialiser names `TestingKey`.
    private func namesTestingKey(annotation: TypeSyntax?, initializer: ExprSyntax?) -> Bool {
        if let identifier = annotation?.as(IdentifierTypeSyntax.self), identifier.name.text == "TestingKey" {
            return true
        }
        if let call = initializer?.as(FunctionCallExprSyntax.self),
            let reference = call.calledExpression.as(DeclReferenceExprSyntax.self),
            reference.baseName.text == "TestingKey"
        {
            return true
        }
        return false
    }
}

/// Strip a leading `any ` from a type expression (`any NoteBackend` → `NoteBackend`), matching WireGen's
/// `strippedSlotType`, so an existential slot's doubles field and subject match line up.
func strippingAny(_ type: String) -> String {
    var base = type
    while base.hasPrefix("any ") { base = String(base.dropFirst("any ".count)) }
    return base
}
