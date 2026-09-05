// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import SwiftParser
public import SwiftSyntax

// Normalise the `import` declarations propagated into `_WireRoutes.swift`.
//
// `WireMVCRouteGen` re-parses the consumer's sources *and* the sources of every Wire-aware library it
// depends on (the build plugin's cross-module composition), and carries their imports into the generated
// file so the types a controller names stay in scope. They arrive verbatim, since nothing here interprets
// a type name — and verbatim carries the access level each was written at, which belongs to the file it
// was written in, not to this one. WireMVC's own `Routing.swift` writes `public import HTTPAPIs` because
// WireMVC's public API names the proposal's types; a consumer's composition root writes
// `package import Wire`. Unioned into one file, those modifiers are wrong two ways over:
//
//   • Access levels collide. The same module arrives from several files at several levels, and a file may
//     import a module only once — the compiler keeps the widest and warns "module 'X' is imported as
//     'public' from the same file; this 'internal' access level will be ignored" on every other one.
//   • Whichever level wins is then unused. Every declaration this generator emits is internal — the route
//     witnesses sit in extensions of WireGen's contributor proxies, which are deliberately internal — so
//     nothing public or package-level references the module, and the compiler says so: "public import of
//     'X' was not used in public declarations or inlinable code".
//
// So the canonical form is one import per module: the module (with any `import struct …` specifier), the
// union of the attributes it was seen with, and no access-level modifier. Internal is always enough for
// the code this generator emits.
//
// `@_exported` goes with the access level, and for a different reason. It re-exports a module to whoever
// imports *this* one — nothing the generated file needs, and not a property of the consumer that this
// generator is entitled to decide. Carried over it decides one anyway: WireMVC's `Exports.swift`
// re-exports `AsyncStreaming`/`HTTPAPIs`/`HTTPTypes`/`Middleware`, so the module holding
// `_WireRoutes.swift` re-exported them too — which is why a file there could name `HTTPResponse.Status`
// while importing neither `HTTPTypes` nor `WireMVC`. A file that wants those types imports them.

/// The canonical, deduplicated, sorted import lines for a generated file.
///
/// Each element of `imports` is a rendered import declaration as it was collected — from a parsed source
/// file, or synthesised here (`"import WireMVC"`). Re-parsing rather than string-matching means an
/// `#if`-guarded import normalises like any other: a lone import is folded into the per-module table,
/// while anything more (an `#if` block) has its inner imports rewritten in place and is emitted as it
/// stands.
public func normalizedImports(_ imports: some Sequence<String>) -> [String] {
    var modules: [ImportModule: ImportSpelling] = [:]
    var verbatim: [String] = []

    for line in imports {
        let snippet = Parser.parse(source: line)
        if let single = soleImportDeclaration(of: snippet) {
            modules[ImportModule(single), default: ImportSpelling()].absorb(single)
        } else {
            verbatim.append(ImportNormalizer().rewrite(snippet).trimmedDescription)
        }
    }

    let rendered = modules.map { $0.value.rendered(importing: $0.key) } + verbatim
    return Array(Set(rendered)).sorted()
}

/// The identity two imports have to share to be one import: the module path, plus the `struct`/`func`/…
/// specifier that narrows it. `import Foundation` and `import struct Foundation.Data` are different
/// imports and may both appear in a file, so they are different keys.
private struct ImportModule: Hashable {
    let kindSpecifier: String?
    let path: String

    init(_ node: ImportDeclSyntax) {
        kindSpecifier = node.importKindSpecifier?.text
        path = node.path.trimmedDescription
    }
}

/// How one module is imported, folded across every file that imported it.
private struct ImportSpelling {
    /// Every attribute the module was seen with, rendered (`@_spi(Generated)`, `@preconcurrency`,
    /// `@testable`). Unioned rather than taken from one spelling: each grants something — SPI
    /// declarations, a concurrency-checking relaxation, internal visibility — and the generated file may
    /// lean on any of them, since it composes declarations discovered across all of those files.
    private var attributes: Set<String> = []
    mutating func absorb(_ node: ImportDeclSyntax) {
        for element in node.attributes {
            guard case .attribute(let attribute) = element, !isExported(attribute) else { continue }
            attributes.insert(attribute.trimmedDescription)
        }
    }

    func rendered(importing module: ImportModule) -> String {
        let specifier = module.kindSpecifier.map { "\($0) " } ?? ""
        return (attributes.sorted() + ["import \(specifier)\(module.path)"]).joined(separator: " ")
    }
}

/// The lone `import` a snippet consists of, or nil when it is anything else — in practice an `#if`
/// block, whose clauses are normalised in place instead.
private func soleImportDeclaration(of snippet: SourceFileSyntax) -> ImportDeclSyntax? {
    guard snippet.statements.count == 1 else { return nil }
    return snippet.statements.first?.item.as(ImportDeclSyntax.self)
}

private func isExported(_ attribute: AttributeSyntax) -> Bool {
    attribute.attributeName.trimmedDescription == "_exported"
}

/// Rewrites every `import` declaration in a parsed snippet to its canonical form in place — used for an
/// `#if` block, where the clauses have to stay put and only the declarations inside them change.
private final class ImportNormalizer: SyntaxRewriter {
    override func visit(_ node: ImportDeclSyntax) -> DeclSyntax {
        // Whatever preceded the declaration — the newline and indentation that place it inside an `#if`
        // clause — hangs off its first token, which is about to be removed along with the modifier. Put it
        // back on whichever token leads the canonical form, or the clause collapses onto its `#if` line.
        let leadingTrivia = node.leadingTrivia
        var canonical = node
        canonical.attributes = node.attributes.filter { element in
            guard case .attribute(let attribute) = element else { return true }
            return !isExported(attribute)
        }
        // Dropping the modifier list drops the `public`/`package` token *and* the space that followed it,
        // so nothing else needs re-spacing: what precedes `import` is now either nothing or an attribute
        // that carries its own trailing space.
        canonical.modifiers = DeclModifierListSyntax()
        canonical.leadingTrivia = leadingTrivia
        return DeclSyntax(canonical)
    }
}
