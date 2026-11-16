// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import SwiftSyntax

// `@RequestBodyLimit`: which limit a route's body is read under, and the places the annotation cannot mean
// anything. Split from `RouteCodegen.swift` along the seam that file already follows, beside
// `RequestStreamingCodegen` — the other half of how a route treats its request body.

extension RouteBlockGenerator {
    /// The `@RequestBodyLimit` argument written at one scope, as source text, or `nil` when the scope writes
    /// none.
    ///
    /// The argument is emitted verbatim, so a limit the app already names (`Artwork.maximumSize`) works and
    /// the compiler checks it is an `Int` where the terminal receives it. Only a literal can be judged here,
    /// so a literal that is not positive is the one value diagnosed.
    mutating func requestBodyLimit(from attributes: AttributeListSyntax, scopeLabel: String) -> String? {
        var found: String?
        for case let .attribute(attr) in attributes
        where attr.attributeName.trimmedDescription == "RequestBodyLimit" {
            guard case let .argumentList(list) = attr.arguments, let argument = list.first else { continue }
            guard found == nil else {
                record(RouteCodegenDiagnostic(.requestBodyLimitDuplicate(scope: scopeLabel), at: attr))
                continue
            }
            let expression = argument.expression
            if let value = literalValue(of: expression), value <= 0 {
                record(
                    RouteCodegenDiagnostic(
                        .requestBodyLimitNotPositive(expression.trimmedDescription, scope: scopeLabel),
                        at: attr
                    )
                )
                continue
            }
            found = expression.trimmedDescription
        }
        return found
    }

    /// The limit a typed route's body is read under: the route's own, else the controller's — or `nil` for
    /// the terminal's default. A route that reads no body takes none, and saying one on the route itself is
    /// diagnosed, since it would limit nothing.
    mutating func effectiveRequestBodyLimit(
        of function: FunctionDeclSyntax,
        controllerLimit: String?,
        readsBody: Bool
    ) -> String? {
        let routeLimit = requestBodyLimit(from: function.attributes, scopeLabel: "route")
        guard readsBody else {
            if routeLimit != nil {
                record(RouteCodegenDiagnostic(.requestBodyLimitWithoutBody(function.name.text), at: function.name))
            }
            return nil
        }
        return routeLimit ?? controllerLimit
    }

    /// A raw route reads its body itself, so a limit on it would be honoured by nothing. Only the route's own
    /// annotation is diagnosed: a controller-scope limit is a policy for the routes it can reach, and failing
    /// every raw route beside them would make the two unable to share a controller.
    mutating func diagnoseRequestBodyLimitOnRawRoute(_ function: FunctionDeclSyntax) {
        if requestBodyLimit(from: function.attributes, scopeLabel: "route") != nil {
            record(RouteCodegenDiagnostic(.requestBodyLimitOnRawRoute(function.name.text), at: function.name))
        }
    }

    /// The value of an integer literal, signed or not, with its digit separators — `nil` for anything else.
    private func literalValue(of expression: ExprSyntax) -> Int? {
        if let literal = expression.as(IntegerLiteralExprSyntax.self) {
            return Int(literal.literal.text.filter { $0 != "_" })
        }
        if let prefixed = expression.as(PrefixOperatorExprSyntax.self), prefixed.operator.text == "-",
            let magnitude = literalValue(of: prefixed.expression)
        {
            return -magnitude
        }
        return nil
    }
}
