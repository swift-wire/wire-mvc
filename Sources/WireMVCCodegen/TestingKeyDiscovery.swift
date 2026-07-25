import SwiftSyntax

// Discovery of the `TestingKey` a keyed test harness declares (H2.2b), and the derived names the generated
// keyed factory + dispatch bind to. A `TestingKey` static carries `@BindType` markers in two forms — the
// metatype form `@BindType(Slot.self, Mock.self)` and the keyed form `@BindType(Slot.primary, Mock.self)`,
// where `Slot.primary` is a `BindingKey<Slot>` (mirroring `@Provides(key)` / `@Replaces(key)`). This reads
// them and derives the same `_<Key>Doubles` field name swift-wire's WireGen does, so the generated
// `withBindValues(<field>:)` and doubles construction line up with WireGen's struct. The two sides must agree
// on those names blind, so both restate the identical `identifierName(forType:key:)` rule.
//
// The keyed form's field name needs the slot *type* (`identifierName` uses it), which the attribute doesn't
// carry — only the key reference. It is recovered from the `BindingKey<Slot>` declaration in the composed
// sources (``bindingKeySlotTypes(in:)``); a key whose declaration isn't found is skipped.
//
// Scope is the single-`TestingKey` common case: the first key found drives the harness.

/// One `@BindType` substitution on a `TestingKey` — the doubles field it contributes.
public struct TestingBindSubstitution: Sendable, Equatable {
    /// The `_<Key>Doubles` field name for this slot, matching WireGen's `identifierName(forType:key:)` — the
    /// by-type name (`noteBackend`) or the keyed name (`prefsBackendKeyedPrefsKeysPrimary`).
    public let fieldName: String
    /// The concrete mock type the slot binds to (`"MockNoteBackend"`) — the doubles field's type and the
    /// generated `withBindValues` parameter's type.
    public let mockType: String

    public init(fieldName: String, mockType: String) {
        self.fieldName = fieldName
        self.mockType = mockType
    }
}

/// A discovered `TestingKey` and the names the keyed harness derives from it. Constructed only by
/// ``discoverTestingKey(in:)``.
public struct DiscoveredTestingKey: Sendable, Equatable {
    /// The canonical reference text — `"NoteTestBinds.mockBackend"` for a `static let mockBackend` on
    /// `NoteTestBinds`. The variant/doubles names derive from it.
    public let keyReference: String
    /// The `@BindType` substitutions, in source order — the doubles struct's fields. (`@Scopable` markers on
    /// the key are read by swift-wire's cascade to lift app singletons into the scope; wire-mvc's keyed
    /// harness keys every `@Scoped(seed:)` controller regardless, so it does not read them.)
    public let substitutions: [TestingBindSubstitution]

    /// The variant name — the key reference with `.` → `_` (`"NoteTestBinds_mockBackend"`). Prefixes the
    /// doubles struct, the variant proxy type, and the facade method, matching WireGen.
    public var variantName: String { keyReference.split(separator: ".").map(String.init).joined(separator: "_") }

    /// The `_<Key>Doubles` struct type name — `_` + dot-joined-with-`_` reference + `Doubles`
    /// (`"_NoteTestBinds_mockBackendDoubles"`). Matches WireGen's `doublesStructTypeName(forKeyReference:)`.
    public var doublesTypeName: String { "_" + variantName + "Doubles" }

    /// The generated per-key harness namespace enum — holds the doubles ``TestBindStore`` and, per subject,
    /// a `@TaskLocal` variant-proxy holder. `_`-prefixed to stay out of user code's namespace.
    public var harnessEnumName: String { "_WireMVCKeyed_" + variantName }
}

/// What a variant subject's scoped route dispatch needs to emit its keyed branch — the per-key harness
/// namespace, the doubles store + `@TaskLocal` variant-proxy members on it, the subject type for the
/// scope-entry tuple annotation, and the key reference for the missing-doubles 500 message. Built per matching
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

/// The per-subject `@TaskLocal` variant-proxy holder's name inside the harness enum.
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
    // The keyed `@BindType(K.member, …)` form names the slot by its `BindingKey` reference, not its type, so
    // its doubles field needs the `BindingKey<Slot>` declaration's `Slot`. Collect those across every source
    // first (the key may be declared in the app, re-parsed into a test target).
    let bindingKeySlots = bindingKeySlotTypes(in: sourceFiles)
    for tree in sourceFiles {
        let finder = TestingKeyFinder(bindingKeySlots: bindingKeySlots)
        finder.walk(tree)
        if let key = finder.key { return key }
    }
    return nil
}

/// Walks a parsed file for a `TestingKey` static and reads its `@BindType` markers, tracking the enclosing
/// type names so the key reference reconstructs as `Enclosing.member`.
private final class TestingKeyFinder: SyntaxVisitor {
    private(set) var key: DiscoveredTestingKey?
    private var enclosing: [String] = []
    /// Key reference → slot type, for resolving the keyed `@BindType(K.member, …)` form's field name.
    private let bindingKeySlots: [String: String]

    init(bindingKeySlots: [String: String]) {
        self.bindingKeySlots = bindingKeySlots
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { pop() }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { pop() }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.name.text)
        return .visitChildren
    }
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
        key = DiscoveredTestingKey(keyReference: reference, substitutions: substitutions)
        return .visitChildren
    }

    /// Read one `@BindType(slot, Mock.self)` into a substitution. The first argument is the slot — a metatype
    /// (`Repo.self`, the by-type form) or a `BindingKey` reference (`Repo.primary`, the keyed form). The
    /// doubles field name matches WireGen's `identifierName(forType:key:)` either way. `nil` for a malformed
    /// attribute, or a keyed slot whose `BindingKey<Slot>` declaration isn't found in the composed sources.
    private func bindSubstitution(from attribute: AttributeSyntax) -> TestingBindSubstitution? {
        guard case let .argumentList(args) = attribute.arguments, args.count == 2,
            let mock = metatypeBase(of: args.last!.expression)
        else { return nil }
        let slotExpression = args.first!.expression
        if let slotType = metatypeBase(of: slotExpression) {
            // By-type: `@BindType(Repo.self, Mock.self)`.
            let field = wireGenIdentifierName(forType: strippingAny(slotType), key: nil)
            return TestingBindSubstitution(fieldName: field, mockType: mock)
        }
        // Keyed: `@BindType(Repo.primary, Mock.self)` — recover the slot type from `BindingKey<Slot>`.
        let keyReference = slotExpression.trimmedDescription
        guard let slotType = bindingKeySlots[keyReference] else { return nil }
        let field = wireGenIdentifierName(forType: strippingAny(slotType), key: keyReference)
        return TestingBindSubstitution(fieldName: field, mockType: mock)
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
/// `strippedSlotType`, so an existential slot's doubles field lines up.
func strippingAny(_ type: String) -> String {
    var base = type
    while base.hasPrefix("any ") { base = String(base.dropFirst("any ".count)) }
    return base
}

// MARK: - WireGen doubles-field naming (replicated to agree blind)

/// The `_<Key>Doubles` field name for a slot — a verbatim replica of WireGen's `identifierName(forType:key:)`
/// so the generated `withBindValues`/doubles construction matches WireGen's struct. By-type:
/// `lowerCamel(sanitize(type))` (`NoteBackend` → `noteBackend`). Keyed: that, plus a `Keyed` sentinel and the
/// upper-camel sanitised key (`(PrefsBackend, "PrefsKeys.primary")` → `prefsBackendKeyedPrefsKeysPrimary`).
func wireGenIdentifierName(forType type: String, key: String?) -> String {
    let typeName = lowerCamelFirst(sanitizeIdentifier(type))
    guard let key else { return typeName }
    return typeName + "Keyed" + upperCamelFirst(sanitizeKeyComponents(key))
}

/// Uppercase the first character only — WireGen's `upperCamelCased`.
func upperCamelFirst(_ name: String) -> String {
    guard let first = name.first else { return name }
    return first.uppercased() + name.dropFirst()
}

/// Sanitize a type expression into an identifier — WireGen's `sanitizeIdentifier`: `<` → `Of`, `,` → `And`
/// (both upper-casing the next segment), letters/digits/`_` kept, everything else dropped.
func sanitizeIdentifier(_ raw: String) -> String {
    var result = ""
    var capitalizeNext = false
    for char in raw {
        switch char {
        case "<":
            result += "Of"
            capitalizeNext = true
        case ",":
            result += "And"
            capitalizeNext = true
        case _ where char.isLetter || char.isNumber || char == "_":
            result += capitalizeNext ? char.uppercased() : String(char)
            capitalizeNext = false
        default:
            break
        }
    }
    return result
}

/// Sanitize a key reference into an identifier fragment — WireGen's `sanitizeKeyComponents`: dots are segment
/// separators (drop the dot, upper-case the next letter), other non-identifier characters dropped.
/// `"PrefsKeys.primary"` → `"PrefsKeysPrimary"`.
func sanitizeKeyComponents(_ raw: String) -> String {
    var result = ""
    var capitalizeNext = false
    for char in raw {
        if char == "." {
            capitalizeNext = true
            continue
        }
        guard char.isLetter || char.isNumber || char == "_" else { continue }
        if capitalizeNext {
            result += String(char).uppercased()
            capitalizeNext = false
        } else {
            result.append(char)
        }
    }
    return result
}

// MARK: - BindingKey slot-type recovery (for the keyed `@BindType` form)

/// Map every `BindingKey<Slot>` declaration across the composed sources to its slot type, keyed by its
/// reference (`"PrefsKeys.primary"` → `"any PrefsBackend"`). The keyed `@BindType(K.member, …)` form names the
/// slot only by this reference, so its doubles field derives the slot type from here.
func bindingKeySlotTypes(in sourceFiles: [SourceFileSyntax]) -> [String: String] {
    var slots: [String: String] = [:]
    for tree in sourceFiles {
        let finder = BindingKeyFinder()
        finder.walk(tree)
        for (reference, slotType) in finder.slots { slots[reference] = slotType }
    }
    return slots
}

/// Walks a parsed file for `BindingKey<Slot>` static/global declarations, tracking enclosing type names
/// (including `extension`ed types) so a key reconstructs as `Enclosing.member`.
private final class BindingKeyFinder: SyntaxVisitor {
    private(set) var slots: [String: String] = [:]
    private var enclosing: [String] = []

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { push(node.name.text); return .visitChildren }
    override func visitPost(_ node: EnumDeclSyntax) { pop() }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { push(node.name.text); return .visitChildren }
    override func visitPost(_ node: StructDeclSyntax) { pop() }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { push(node.name.text); return .visitChildren }
    override func visitPost(_ node: ClassDeclSyntax) { pop() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { push(node.name.text); return .visitChildren }
    override func visitPost(_ node: ActorDeclSyntax) { pop() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.extendedType.trimmedDescription)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { pop() }

    private func push(_ name: String) { enclosing.append(name) }
    private func pop() { if !enclosing.isEmpty { enclosing.removeLast() } }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.bindings.count == 1,
            let binding = node.bindings.first,
            let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
            let slotType = bindingKeyGenericArgument(of: binding)
        else { return .visitChildren }
        let reference = (enclosing + [pattern.identifier.text]).joined(separator: ".")
        slots[reference] = slotType
        return .visitChildren
    }

    /// The `Slot` of a `BindingKey<Slot>` binding — from the annotation `: BindingKey<Slot>` or the
    /// initializer `= BindingKey<Slot>()` — or `nil` when the binding isn't a `BindingKey`.
    private func bindingKeyGenericArgument(of binding: PatternBindingSyntax) -> String? {
        if let identifierType = binding.typeAnnotation?.type.as(IdentifierTypeSyntax.self),
            identifierType.name.text == "BindingKey",
            let argument = identifierType.genericArgumentClause?.arguments.first
        {
            return argument.argument.trimmedDescription
        }
        if let call = binding.initializer?.value.as(FunctionCallExprSyntax.self),
            let specialization = call.calledExpression.as(GenericSpecializationExprSyntax.self),
            let base = specialization.expression.as(DeclReferenceExprSyntax.self),
            base.baseName.text == "BindingKey",
            let argument = specialization.genericArgumentClause.arguments.first
        {
            return argument.argument.trimmedDescription
        }
        return nil
    }
}
