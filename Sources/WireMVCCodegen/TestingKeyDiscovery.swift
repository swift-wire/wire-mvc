// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import SwiftSyntax

// Discovery of the `TestingKey` a keyed test harness declares (H2.2b), and the derived names the generated
// keyed factory + dispatch bind to. A `TestingKey` static carries `@BindType` markers in two forms — the
// metatype form `@BindType(Slot.self, Mock.self)` and the keyed form `@BindType(Slot.primary, Mock.self)`,
// where `Slot.primary` is a `BindingKey<Slot>` (mirroring `@Provides(key)` / `@Replaces(key)`). This reads
// them and derives the same `_<Key>Doubles` field name swift-wire's WireGen does, so the generated
// the doubles field names line up with WireGen's struct. The two sides must agree
// on those names blind, so both restate the identical `identifierName(forType:key:)` rule.
//
// The keyed form's field name needs the slot *type* (`identifierName` uses it), which the attribute doesn't
// carry — only the key reference. It is recovered from the `BindingKey<Slot>` declaration in the composed
// sources (``bindingKeySlotTypes(in:)``); a key whose declaration isn't found is skipped.
//
// Scope is one `TestingKey` per target — the key drives the harness. A second key is an **error**, not a
// silent preference for the first: both would generate a variant graph, but only one factory is emitted, so
// a suite passing the second would quietly be served the first's graph. Serving several variants from one
// target is deferred (swift-wire/swift-wire#336); rejecting the second keeps the deferral visible
// instead of letting it surface as a mysteriously wrong mock.

/// One `@BindType` substitution on a `TestingKey` — the doubles field it contributes.
public struct TestingBindSubstitution: Sendable, Equatable {
    /// The `_<Key>Doubles` field name for this slot, matching WireGen's `identifierName(forType:key:)` — the
    /// by-type name (`noteBackend`) or the keyed name (`prefsBackendKeyedPrefsKeysPrimary`).
    public let fieldName: String
    /// The concrete mock type the slot binds to (`"MockNoteBackend"`) — the doubles field's type and the
    /// generated doubles field's type.
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
    /// The declaration's `#fileID` (`ModuleName/File.swift`) and `#line` — what `TestingKey()`'s defaulting
    /// `init` captured at this declaration, reconstructible here because both come from one source in one
    /// build. The generated factory compares the key it is handed against these, so a suite passing some
    /// *other* module's key is caught rather than silently served this variant (see
    /// ``keyIdentityAssertion(for:)``).
    ///
    /// `nil` when the declaring file's module isn't known — the caller passed no module attribution for it,
    /// so `#fileID` can't be reconstructed and the assertion is skipped rather than guessed wrong.
    public let declarationFileID: String?
    /// The declaration's `#line`. Meaningless without ``declarationFileID``.
    public let declarationLine: Int

    /// The variant name — the key reference with `.` → `_` (`"NoteTestBinds_mockBackend"`). Prefixes the
    /// doubles struct, the variant proxy type, and the facade method, matching WireGen.
    public var variantName: String { keyReference.split(separator: ".").map(String.init).joined(separator: "_") }

    /// The `_<Key>Doubles` struct type name — `_` + dot-joined-with-`_` reference + `Doubles`
    /// (`"_NoteTestBinds_mockBackendDoubles"`). Matches WireGen's `doublesStructTypeName(forKeyReference:)`.
    public var doublesTypeName: String { "_" + variantName + "Doubles" }

    /// The generated per-key harness namespace enum — holds the doubles ``TestBindStore``. `_`-prefixed to
    /// stay out of user code's namespace.
    public var harnessEnumName: String { "_WireMVCKeyed_" + variantName }
}

/// What a variant subject's route dispatch needs to emit the keyed entry on the *variant* witness — the
/// per-key harness namespace + doubles store to correlate a request's doubles from, and the key reference for
/// the missing-doubles 500 message. The variant witness's `self` is the variant proxy, so it enters request
/// scope directly (`self._wireEnterScope(request, doubles)`) with no production branch. Built per matching
/// controller by ``renderControllerExtensions`` and threaded into ``RouteBlockGenerator``.
public struct KeyedScopeEntry: Sendable, Equatable {
    public let harnessEnumName: String
    public let doublesStoreName: String
    public let keyReference: String
    /// The subject whose doubles this route's entry takes — names the store and the 500 message, so a test
    /// that forgets to supply doubles is told which controller it missed rather than which key.
    public let subject: String

    public init(
        harnessEnumName: String,
        doublesStoreName: String,
        keyReference: String,
        subject: String
    ) {
        self.harnessEnumName = harnessEnumName
        self.doublesStoreName = doublesStoreName
        self.keyReference = keyReference
        self.subject = subject
    }
}

/// The doubles ``TestBindStore`` member name for a subject inside the generated per-key harness enum. One
/// store per routed subject, because each subject enters scope with its own `_<Variant>_<Subject>Doubles`.
public func harnessDoublesStoreName(subject: String) -> String {
    lowerCamelCased(subject) + "Doubles"
}

/// The per-subject doubles struct WireGen emits — `_<Variant>_<Subject>Doubles`, carrying only the slots that
/// subject reaches. wire-mvc derives the *name* by the same convention swift-wire renders it under and trusts
/// the field list, exactly as it already trusts `_<Key>Doubles`: a mismatch is a build error on swift-wire's
/// side, so the two agree or the build fails.
public func subjectDoublesTypeName(variantName: String, subject: String) -> String {
    "_\(variantName)_\(subject)Doubles"
}

/// The unprefixed alias a test names at the call site — `NotesControllerDoubles`. The generated struct keeps
/// swift-wire's `_` prefix; this is the ergonomic surface wire-mvc owns.
public func subjectDoublesAliasName(subject: String) -> String { subject + "Doubles" }

/// Lower-camel a type name for use as a member — `NotesController` → `notesController`.
func lowerCamelCased(_ name: String) -> String {
    guard let first = name.first else { return name }
    return first.lowercased() + name.dropFirst()
}

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

/// The `Wire.bootstrap<Variant>()` variant-app-graph bootstrap method — the keyed factory builds the variant
/// graph (production minus the mocked/lifted bindings and the scoped-subject proxies), so a mocked eager
/// `@Singleton`'s `init` never runs under the keyed suite. Mirrors WireGen's `bootstrap<Variant>()`.
public func variantBootstrapMethodName(variantName: String) -> String {
    "bootstrap\(variantName)"
}

/// Lower-camel a type's simple name by lowercasing only its first character — WireGen's `identifierName`
/// rule for a plain identifier (`HTTPClient` → `hTTPClient`, `NoteBackend` → `noteBackend`).
func lowerCamelFirst(_ name: String) -> String {
    guard let first = name.first else { return name }
    return first.lowercased() + name.dropFirst()
}

/// Find the harness's `TestingKey` across the parsed sources — a `static let`/module-scope `let` initialised
/// with `TestingKey()` (or annotated `: TestingKey`), with its `@BindType`/`@Scopable` markers. `nil` when
/// there is none (the keyless path).
///
/// Every key found beyond the first is reported as an error against its own declaration, naming the one that
/// won. The harness emits a single `.wiremvc(_ key:, _ mode:)` factory bound to that key's variant graph, so
/// a second key has no way to be served and would otherwise be a silent wrong-graph bug.
public func discoverTestingKeys(
    in sourceFiles: [(path: String, tree: SourceFileSyntax)],
    sourceModules: [String: String] = [:],
    consumerModule: String? = nil
) -> (key: DiscoveredTestingKey?, diagnostics: [LocatedRouteDiagnostic]) {
    // The keyed `@BindType(K.member, …)` form names the slot by its `BindingKey` reference, not its type, so
    // its doubles field needs the `BindingKey<Slot>` declaration's `Slot`. Collect those across every source
    // first — that one *may* legitimately live in the app and be re-parsed here, unlike the key itself.
    let bindingKeySlots = bindingKeySlotTypes(in: sourceFiles.map(\.tree))

    // Only the target being built may declare the key it serves. A dependency's sources are re-parsed into
    // every consumer, so a library's `TestingKey` would otherwise be picked up here — and, because the first
    // key found wins, could be served *instead of* this target's own, reporting the target's real key as the
    // duplicate. swift-wire refuses a foreign key outright (`foreignTestingKeyDiagnostic`), so there is no
    // second diagnostic to raise here; skipping keeps the two sides agreeing on which key is served.
    // Files with no module attribution are kept, so the older flat argument form still behaves as before.
    let ownSources = sourceFiles.filter { file in
        guard let consumerModule, let module = sourceModules[file.path] else { return true }
        return module == consumerModule
    }

    var served: DiscoveredTestingKey?
    var diagnostics: [LocatedRouteDiagnostic] = []
    for file in ownSources {
        let finder = TestingKeyFinder(bindingKeySlots: bindingKeySlots)
        finder.walk(file.tree)
        guard !finder.keys.isEmpty else { continue }
        let converter = SourceLocationConverter(fileName: file.path, tree: file.tree)
        for found in finder.keys {
            guard let first = served else {
                let location = converter.location(for: found.declarationPosition)
                served = found.key.locatedAt(
                    // `#fileID` is `ModuleName/File.swift` — the *base* name, not the build-machine path the
                    // codegen walks, so a generated assertion matches what the declaration captured.
                    fileID: sourceModules[file.path].map { "\($0)/\(baseName(of: file.path))" },
                    line: location.line
                )
                continue
            }
            diagnostics.append(
                LocatedRouteDiagnostic(
                    message: .multipleTestingKeys(found.key.keyReference, first: first.keyReference),
                    location: converter.location(for: found.declarationPosition)
                )
            )
        }
    }
    return (served, diagnostics)
}

/// A `TestingKey` declaration with the position its diagnostic anchors to.
struct FoundTestingKey {
    let key: DiscoveredTestingKey
    let declarationPosition: AbsolutePosition
}

/// The last path component of `path` — the file name `#fileID` carries. Hand-rolled rather than reached for
/// through `NSString`/`URL` so this module stays Foundation-free like the rest of the codegen.
func baseName(of path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
}

extension DiscoveredTestingKey {
    /// This key with its declaration site attached — the `#fileID`/`#line` a generated identity assertion
    /// reconstructs. Applied by ``discoverTestingKeys(in:sourceModules:)``, which is where the file path and
    /// its module attribution are both in hand.
    func locatedAt(fileID: String?, line: Int) -> DiscoveredTestingKey {
        DiscoveredTestingKey(
            keyReference: keyReference,
            substitutions: substitutions,
            declarationFileID: fileID,
            declarationLine: line
        )
    }
}

/// Walks a parsed file for every `TestingKey` static, reading its `@BindType` markers and tracking the
/// enclosing type names so each key reference reconstructs as `Enclosing.member`. All of them are collected,
/// not just the first — the extras are what the single-key rule reports.
private final class TestingKeyFinder: SyntaxVisitor {
    private(set) var keys: [FoundTestingKey] = []
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
        guard node.bindings.count == 1,
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
        keys.append(
            FoundTestingKey(
                // The declaration site is attached by `discoverTestingKeys`, which holds the file path and
                // its module attribution; the finder sees only the tree.
                key: DiscoveredTestingKey(
                    keyReference: reference,
                    substitutions: substitutions,
                    declarationFileID: nil,
                    declarationLine: 0
                ),
                declarationPosition: pattern.identifier.positionAfterSkippingLeadingTrivia
            )
        )
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
/// so the generated doubles field names match WireGen's struct. By-type:
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
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        push(node.name.text)
        return .visitChildren
    }
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
