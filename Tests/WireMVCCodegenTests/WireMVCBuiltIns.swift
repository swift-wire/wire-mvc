// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

import Foundation
import SwiftParser
import SwiftSyntax

@testable import WireMVCCodegen

/// WireMVC's own bindings and response modes, read from **its actual sources**.
///
/// The generator has no table of built-ins. In a real build the plugin re-parses WireMVC (a Wire-aware
/// dependency of every consumer that can use its macros) and the scan finds `@Path`, `@JSONResponse` and the
/// rest exactly as it finds a user's `@FormBody`. These tests call the renderers directly, so they have to
/// supply what the plugin would — and reading the same files the plugin reads is the only way to do that
/// without reintroducing the hardcoded table this replaced.
///
/// A restated table would drift from the declarations; this cannot, because it *is* the declarations.
enum WireMVCBuiltIns {
    static let bindings: [String: DeclaredRequestBinding] = scanRequestBindings(in: [parsed("RequestBinding.swift")])
    static let modes: [String: DeclaredResponseMode] = scanResponseModes(in: [parsed("Macros.swift")])

    /// **Every** WireMVC source, as `(path, source)` pairs for `generateRouteContributors`.
    ///
    /// That entry point's contract is "every source the plugin passes", and the plugin passes a Wire-aware
    /// dependency's whole module — WireMVC included, since it is a direct dependency of any target that can
    /// use its macros. A test giving it only fixture sources tests a configuration that cannot occur.
    ///
    /// The whole module rather than the two files that declare the bindings and modes, because the halves
    /// are spread: `RequestBinding.swift` declares `@JSONBody`, `RequestSending.swift` carries its
    /// `RequestBodySendable` conformance, and the send-conformance lint reads both. Passing a subset
    /// reproduces no real build and produces warnings no real build emits.
    static let declarationFiles: [(path: String, source: String)] = {
        let directory = wireMVCSources
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasSuffix(".swift") }
            .sorted() ?? []
        precondition(!names.isEmpty, "no sources found at \(directory.path)")
        return names.map { (path: "WireMVC/\($0)", source: text($0)) }
    }()

    private static func parsed(_ name: String) -> SourceFileSyntax {
        Parser.parse(source: text(name))
    }

    private static let wireMVCSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // WireMVCCodegenTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root
        .appendingPathComponent("Sources/WireMVC")

    private static func text(_ name: String) -> String {
        let url = wireMVCSources.appendingPathComponent(name)
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("cannot read \(url.path) — WireMVC's own declarations are what these tests bind against")
        }
        return source
    }
}
