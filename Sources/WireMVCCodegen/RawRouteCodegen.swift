// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import SwiftSyntax

// The raw-route half of the route codegen: `@RawRoute` parameter binding (type-inferred and by explicit
// role), the `@NotFound` fallback, and the two places a raw handler is handed something other than the
// register closure's own primitive — the unwrapped request context, and the header-applying sender.
//
// Split from RouteCodegen.swift for the same reason ResponseCodegen.swift was: the file is over
// SwiftLint's 1000-line ceiling, and these methods share only the generator's diagnostics.

// MARK: - Raw route codegen

extension RouteBlockGenerator {
    private enum RawRole { case context, reader, sender }

    func hasRawRoute(_ function: FunctionDeclSyntax) -> Bool {
        for case let .attribute(attr) in function.attributes
        where attr.attributeName.trimmedDescription == "RawRoute" {
            return true
        }
        return false
    }

    /// The `@RawRoute` register call: pass the register closure's primitives straight to the handler. A
    /// bare `@RawRoute` matches each parameter by type (`HTTPRequest`, `[String: Substring]`) and by the
    /// reader/sender/context generic parameters' constraints. An explicit `@RawRoute(.role, …)` binds the
    /// parameters positionally by the listed roles — one role per parameter — so a **transformed slot**
    /// whose type a middleware produces (e.g. `consuming MultiPartSender<S>`) binds by role rather than by
    /// an inference that can't name it. No decode, no encode either way.
    mutating func rawRouteBlock(
        function: FunctionDeclSyntax,
        verb: Verb,
        path: String,
        middleware: [String]
    ) -> String? {
        guard let mapping = rawCallArgs(function, foldsMiddleware: !middleware.isEmpty) else { return nil }
        // A scoped controller — or any variant witness (including a seedless app-`@Singleton` `@TestScopable`
        // one) — reconstructs its subject per request, so the raw call dispatches on `subjectExpression`
        // (`wireMVCController`) after the scope-entry prologue, not the held `_wireSubject`; a production
        // app-`@Singleton` raw route stays `self._wireSubject`, byte-for-byte unchanged. When the fold threads
        // doubles the correlation is hoisted above the fold, as in the typed path.
        let call =
            "\(effectMarkers(of: function))\(subjectExpression).\(function.name.text)(\(mapping.callArgs.joined(separator: ", ")))"
        let foldThreadsDoubles = middleware.contains { $0.contains(Self.doublesCreateArgument) }
        let terminalBody = "\(foldThreadsDoubles ? "" : scopeEntryPreamble)\(scopeEntryProloguePrefix)\(call)"
        // Scope entry needs `request` (its seed, and the variant preamble's correlation), even when the
        // handler itself doesn't take it.
        let needsRequest = mapping.used.contains("request") || scopedSeedType != nil || keyedScopeEntry != nil
        // A raw handler writes its own head, so there is no outcome to inject contributions into — its
        // sender is wrapped instead. The registry the wrapper takes comes from the courier on the fold-less
        // path and from the *box's own destructure* on the folded one; `emitRegisterClosure` binds it under
        // `registryLocal` either way, so this side only has to name it.
        return emitRegister(
            verb: verb,
            path: path,
            middleware: middleware,
            hoistedPreamble: foldThreadsDoubles ? scopeEntryPreamble : "",
            requestName: needsRequest ? "request" : "_",
            contextName: "requestContext",
            parametersName: mapping.used.contains("pathParameters") ? "pathParameters" : "_",
            readerName: mapping.used.contains("reader") ? "reader" : "_",
            registryLocal: responseHeaderRegistryLocal,
            terminalBody: terminalBody
        )
    }

    /// The raw-route role mapping: for each handler parameter, the register-closure primitive it binds
    /// to (explicit `@RawRoute(.role, …)` or inferred by type/constraint), plus which primitives are
    /// used. Shared by `rawRouteBlock` (routes) and `notFoundRegistration` (the `@NotFound` fallback).
    /// `nil` with a diagnostic on an unbindable parameter or a missing response sender.
    private mutating func rawCallArgs(
        _ function: FunctionDeclSyntax,
        foldsMiddleware: Bool = false
    ) -> (callArgs: [String], used: Set<String>)? {
        let params = Array(function.signature.parameterClause.parameters)
        var callArgs: [String] = []
        var used: Set<String> = []

        if let explicitRoles = explicitRawRoles(function) {
            guard explicitRoles.count == params.count else {
                record(
                    RouteCodegenDiagnostic(
                        .rawRouteRoleCountMismatch(
                            function.name.text,
                            roles: explicitRoles.count,
                            parameters: params.count
                        ),
                        at: function.name
                    )
                )
                return nil
            }
            // Whether to wrap is decided **per slot**, not by "roles were named at all". Naming `.reader`
            // to get a reader says nothing about the sender beside it, and the blanket rule silently cost
            // such a route every contributed response header.
            let genericRoles = rawGenericRoles(function)
            for (param, role) in zip(params, explicitRoles) {
                guard let primitive = rawPrimitive(forRoleName: role) else {
                    record(
                        RouteCodegenDiagnostic(.unsupportedRawParameter(name: role, type: role), at: param)
                    )
                    return nil
                }
                // A transformed slot names a compound type (`MultiPartSender<S>`); an untransformed one is
                // the function's own generic parameter, constrained by `HTTPResponseSender`. That is the
                // property the wrap depends on, and it is the same test the inferred path already makes.
                let base = strippingOwnership(param.type.trimmedDescription)
                let wrapsSender = primitive == "responseSender" && genericRoles[base] == .sender
                callArgs.append(
                    "\(rawArgumentLabel(param))\(rawArgument(forPrimitive: primitive, wrapsSender: wrapsSender, foldsMiddleware: foldsMiddleware))"
                )
                used.insert(primitive)
            }
        } else {
            let roles = rawGenericRoles(function)
            for param in params {
                let type = strippingOwnership(param.type.trimmedDescription)
                let canonical = type.filter { !$0.isWhitespace }
                let primitive: String
                if canonical == "HTTPRequest" {
                    primitive = "request"
                } else if canonical == "[String:Substring]" {
                    primitive = "pathParameters"
                } else if roles[type] == .context {
                    primitive = "requestContext"
                } else if roles[type] == .reader {
                    primitive = "reader"
                } else if roles[type] == .sender {
                    primitive = "responseSender"
                } else {
                    let name = (param.secondName ?? param.firstName).text
                    record(
                        RouteCodegenDiagnostic(.unsupportedRawParameter(name: name, type: type), at: param)
                    )
                    return nil
                }
                callArgs.append(
                    "\(rawArgumentLabel(param))\(rawArgument(forPrimitive: primitive, wrapsSender: true, foldsMiddleware: foldsMiddleware))"
                )
                used.insert(primitive)
            }
        }

        guard used.contains("responseSender") else {
            record(
                RouteCodegenDiagnostic(.rawRouteMissingSender(function.name.text), at: function.name)
            )
            return nil
        }
        return (callArgs, used)
    }

    /// The `builder.registerNotFound { … }` for a `@NotFound` handler method, called
    /// through `subjectExpression` (the generated `@main`'s `bootstrap` local — not `self`). In practice
    /// the method is `@RawRoute` (it writes the response directly); the raw role mapping is reused, so a
    /// `@NotFound @RawRoute func handleNotFound(request:, responseSender:)` binds exactly like a route.
    /// `nil` with a diagnostic if the mapping fails (e.g. no response sender).
    mutating func notFoundRegistration(function: FunctionDeclSyntax, subjectExpression: String) -> String? {
        guard hasRawRoute(function) else {
            record(RouteCodegenDiagnostic(.notFoundNotRaw(function.name.text), at: function.name))
            return nil
        }
        guard let mapping = rawCallArgs(function) else { return nil }
        return emitRegisterClosure(
            registerCall: "builder.registerNotFound",
            // The fallback is what answers when *nothing* matched, so there is no template to name and no
            // parameters to have matched. It folds no middleware today, so nothing reads this; passing
            // `nil` rather than a made-up template is what keeps that true if it ever does.
            routeTemplate: nil,
            middleware: [],
            requestName: mapping.used.contains("request") ? "request" : "_",
            contextName: "requestContext",
            parametersName: "_",
            readerName: mapping.used.contains("reader") ? "reader" : "_",
            // The fallback is a raw route like any other, so it binds the registry and wraps its sender —
            // which is what lets a global middleware's header reach a 404. It must be raw (see
            // `notFoundNotRaw`), so without this it is the one response that could never carry one.
            registryLocal: responseHeaderRegistryLocal,
            terminalBody:
                "\(effectMarkers(of: function))\(subjectExpression).\(function.name.text)(\(mapping.callArgs.joined(separator: ", ")))"
        )
    }

    /// The call-argument label for a raw handler parameter (`""` for a wildcard first name, else `name: `).
    private func rawArgumentLabel(_ param: FunctionParameterSyntax) -> String {
        param.firstName.tokenKind == .wildcard ? "" : "\(param.firstName.text): "
    }

    /// The role names of an explicit `@RawRoute(.role, …)`, or `nil` for a bare `@RawRoute` / `@RawRoute()`
    /// (which uses type/constraint inference instead).
    private func explicitRawRoles(_ function: FunctionDeclSyntax) -> [String]? {
        for case let .attribute(attr) in function.attributes
        where attr.attributeName.trimmedDescription == "RawRoute" {
            guard let arguments = attr.arguments?.as(LabeledExprListSyntax.self), !arguments.isEmpty else {
                return nil
            }
            return arguments.compactMap {
                $0.expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
            }
        }
        return nil
    }

    /// The register-closure primitive a `@RawRoute` role names — the role name *is* the primitive name;
    /// this also validates the role against the known set.
    private func rawPrimitive(forRoleName role: String) -> String? {
        ["request", "requestContext", "pathParameters", "reader", "responseSender"].contains(role) ? role : nil
    }

    /// The expression a raw handler is actually called with for a primitive. Two differ from the register
    /// closure's own binding, and both for the same reason — what the *route* is handed is not what the
    /// *stack above it* passed:
    ///
    /// - `requestContext` is unwrapped to the app's real context. A raw handler generic over
    ///   `Ctx: HTTPServerCapability.RequestContext` would otherwise silently accept the courier.
    /// - `responseSender` is wrapped so contributed header fields reach a response the handler writes
    ///   itself — there is no outcome to inject them into. Without it a middleware's header vanishes on
    ///   every raw route, including the `@NotFound` fallback, which must be raw.
    ///
    /// `wrapsSender` is decided **per slot**, on both paths, by one question: is this parameter the register
    /// closure's own sender, or a transformed one a middleware pins? A transformed slot names a compound type
    /// — `MultiPartSender<S>`, which cannot also be `ResponseHeaderApplyingSender<MultiPartSender<S>>` — so it
    /// keeps the courier unwrap and forgoes contributions; naming a transformed slot is the "I am taking over
    /// this primitive" signal. An untransformed sender is wrapped whether or not roles were named.
    ///
    /// It used to be false for the whole explicit-role path, which read the signal off the wrong thing: a
    /// handler naming `.reader` to get a reader forfeited every contributed response header for a sender it
    /// had not touched. Harmless while every explicit-role route in the tree was a transformed-sender one;
    /// wrong the moment a duplex route named both.
    ///
    /// Kept separate from ``rawPrimitive(forRoleName:)`` because that one's result is also the *role*
    /// bookkeeping (`used`), which the missing-sender diagnostic keys on.
    private func rawArgument(
        forPrimitive primitive: String,
        wrapsSender: Bool,
        foldsMiddleware: Bool
    ) -> String {
        switch primitive {
        // Through a fold the terminal's context binding is *already* the app's real context — the box was
        // built over it — so there is nothing left to unwrap. Only the fold-less path still holds the
        // courier, and there it comes out of the same destructure the registry does.
        case "requestContext": return foldsMiddleware ? "requestContext" : "\(contentsLocal).base"
        case "responseSender" where wrapsSender:
            return "ResponseHeaderApplyingSender(wrapping: responseSender, registry: \(responseHeaderRegistryLocal))"
        default: return primitive
        }
    }

    /// Map each handler generic parameter to a raw role by its constraint — `AsyncReader` → reader,
    /// `HTTPResponseSender` → sender — so a parameter of that generic type binds to the matching
    /// register-closure primitive.
    private func rawGenericRoles(_ function: FunctionDeclSyntax) -> [String: RawRole] {
        var roles: [String: RawRole] = [:]
        guard let generics = function.genericParameterClause else { return roles }
        for parameter in generics.parameters {
            let constraint = parameter.inheritedType?.trimmedDescription ?? ""
            if constraint.contains("AsyncReader") {
                roles[parameter.name.text] = .reader
            } else if constraint.contains("HTTPResponseSender") {
                roles[parameter.name.text] = .sender
            } else if constraint.contains("RequestContext") {
                roles[parameter.name.text] = .context
            }
        }
        return roles
    }

    /// Strip leading ownership/transfer specifiers (`consuming sending Sender` → `Sender`) so the base
    /// type matches a generic-parameter name or a concrete raw-primitive type.
    private func strippingOwnership(_ type: String) -> String {
        var base = type
        for specifier in ["consuming ", "borrowing ", "inout ", "sending ", "__owned ", "__shared "] {
            while base.hasPrefix(specifier) { base = String(base.dropFirst(specifier.count)) }
        }
        return base
    }
}
