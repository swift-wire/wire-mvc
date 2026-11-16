// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import SwiftSyntax

// The `@NotFound` fallback's registration: raw, or typed like a route.
//
// A fallback answers requests that matched no route, so it has no template, and nothing to bind from one.
// That rules out `@Path` and nothing else. Encoding the response never depended on a template, and nor do
// `@Query`, `@Header` or a body binding. So a typed fallback is emitted through the same terminal a route
// is, and differs only in what it is called through and where it is registered.

extension RouteBlockGenerator {
    /// The local the generated entry binds the app's coding to, ahead of a typed fallback's registration.
    /// A route's witness is handed the app's coding as a parameter; the fallback is registered in the entry
    /// itself, which has no such parameter, so it reads this instead.
    static let notFoundCodingLocal = "wireMVCNotFoundCoding"

    /// The `builder.registerNotFound { … }` for a `@NotFound` handler method, called through
    /// `subjectExpression` (the generated entry's `bootstrap` local). A `@RawRoute` handler writes its own
    /// response; any other is typed. `nil` with a diagnostic when the handler cannot be registered as written.
    mutating func notFoundRegistration(function: FunctionDeclSyntax, subjectExpression: String) -> String? {
        if hasRawRoute(function) {
            return rawNotFoundRegistration(function: function, subjectExpression: subjectExpression)
        }
        return typedNotFoundRegistration(function: function, subjectExpression: subjectExpression)
    }

    /// A typed fallback: the route path of ``routeBlock`` with no template, no fold and no controller tiers.
    ///
    /// - **No fold.** The Bootstrap's `@Middleware` wraps the finished router, so it reaches the fallback
    ///   without being folded here, as it does for the raw and synthesised fallbacks.
    /// - **Error tiers.** The handler's own `@ErrorResponse` entries, then the Bootstrap's: the Bootstrap
    ///   *is* the global tier, so there is no controller tier between the two.
    /// - **Coding.** The app's, read off ``notFoundCodingLocal``. A `@Coding` on the method itself has no
    ///   proxy field to be read from, so it is diagnosed rather than ignored.
    private mutating func typedNotFoundRegistration(
        function: FunctionDeclSyntax,
        subjectExpression: String
    ) -> String? {
        let name = function.name.text
        guard acceptsTypedNotFound(function) else { return nil }
        subjectOverride = subjectExpression
        appCodingExpression = Self.notFoundCodingLocal
        guard let (staticHeaders, mode) = responseMode(of: function, controllerResponseHeaders: []) else {
            return nil
        }
        let hasBody = routeHasBody(function)
        guard let streamsBody = validatedBodyObligations(of: function, hasBody: hasBody, mode: mode) else {
            return nil
        }
        guard let (binds, callArgs) = parameterBindings(of: function, path: "", hasBody: hasBody) else {
            return nil
        }
        let call = "\(effectMarkers(of: function))\(subjectExpression).\(name)(\(callArgs.joined(separator: ", ")))"
        guard let emission = responseEmission(of: function, call: call, staticHeaders: staticHeaders, mode: mode)
        else { return nil }
        let names = registerClosureParameters(hasBinds: !binds.isEmpty, hasBody: hasBody, streamsBody: streamsBody)
        return emitRegisterClosure(
            registerCall: "builder.registerNotFound",
            routeTemplate: nil,
            middleware: [],
            requestName: names.request,
            contextName: "requestContext",
            parametersName: names.pathParameters,
            readerName: names.reader,
            registryLocal: responseHeaderDrainLocal,
            terminalBody: terminalBody(
                emission: emission,
                hasBody: hasBody,
                streamsBody: streamsBody,
                binds: binds,
                errorMappings: tieredErrorMappings(of: function, controller: []),
                foldThreadsDoubles: false
            )
        )
    }

    /// The three ways a fallback can be mis-declared as typed, each diagnosed: no response mode, a `@Coding`
    /// of its own, or a `@Path` binding. `false` when one was recorded.
    private mutating func acceptsTypedNotFound(_ function: FunctionDeclSyntax) -> Bool {
        let name = function.name.text
        // The rule every route keeps: the response mode is stated exactly once, in an annotation or in a
        // bodiless tuple return. A fallback with neither is told all three ways to state it, raw among them.
        guard !responseAnnotationNames(on: function.attributes).isEmpty || returnsBodilessResponseTuple(function)
        else {
            record(RouteCodegenDiagnostic(.notFoundWithoutResponse(name), at: function.name))
            return false
        }
        if let coding = codingKey(from: function.attributes) {
            record(RouteCodegenDiagnostic(.notFoundRouteCoding(name), at: coding.node))
            return false
        }
        // Checked ahead of `parameterBindings`, whose own check would report a placeholder missing from the
        // empty path, true but beside the point.
        for parameter in function.signature.parameterClause.parameters {
            guard let binding = binding(from: parameter.attributes), namesPathPlaceholder(binding.wrapper) else {
                continue
            }
            let parameterName = (parameter.secondName ?? parameter.firstName).text
            record(RouteCodegenDiagnostic(.notFoundPathBinding(name, parameter: parameterName), at: parameter))
            return false
        }
        return true
    }

    /// Whether the handler returns a labelled response tuple with no `body`, the `(status:headers:)` shape
    /// that states its response mode in its signature and needs no annotation. Read off the syntax alone:
    /// `responseReturnShape` records diagnostics, and this only asks whether one of the forms applies.
    private func returnsBodilessResponseTuple(_ function: FunctionDeclSyntax) -> Bool {
        guard let tuple = function.signature.returnClause?.type.as(TupleTypeSyntax.self) else { return false }
        let labels = tuple.elements.compactMap { $0.firstName?.text }
        return labels.contains(responseTupleStatusLabel) && !labels.contains(responseTupleBodyLabel)
    }
}
