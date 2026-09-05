// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

import SwiftSyntax

// The `builder.register` emission — the shape every route's registration closure has, and the one place
// the middleware fold is built. Split out of `RouteCodegen.swift` (which was at its length budget) because
// it is a self-contained concern: everything here is about the *closure around* a terminal, and nothing
// about the terminal itself.

extension RouteBlockGenerator {
    /// The `builder.register` call, wrapping the terminal in the route's middleware fold when there is
    /// one. `requestName`/`contextName`/`parametersName`/`readerName` name (or `_`) the values the
    /// *terminal* uses. With no middleware they name the register closure's params directly. With
    /// middleware, the register closure binds request/context/reader/sender unconditionally to build the
    /// base box, and the terminal re-binds its values off the folded final box via `withContents` —
    /// path parameters are still captured from the register closure by the terminal's binds, and are
    /// *also* boxed, as half of the ``RouteContext`` the fold reads.
    func emitRegister(
        verb: Verb,
        path: String,
        middleware: [String],
        hoistedPreamble: String = "",
        requestName: String,
        contextName: String,
        parametersName: String,
        readerName: String,
        registryLocal: String? = nil,
        terminalBody: String
    ) -> String {
        emitRegisterClosure(
            registerCall: "builder.register(method: \(verb.method), path: \"\(path)\")",
            routeTemplate: path,
            middleware: middleware,
            hoistedPreamble: hoistedPreamble,
            requestName: requestName,
            contextName: contextName,
            parametersName: parametersName,
            readerName: readerName,
            registryLocal: registryLocal,
            terminalBody: terminalBody
        )
    }

    /// The register-closure emission, shared by `builder.register(method:path:)` (routes) and
    /// `builder.registerNotFound` (the `@NotFound` fallback) — the closure body is
    /// identical; only the call that takes it differs. `registerCall` is everything up to the trailing
    /// closure.
    func emitRegisterClosure(
        registerCall: String,
        routeTemplate: String?,
        middleware: [String],
        hoistedPreamble: String = "",
        requestName: String,
        contextName: String,
        parametersName: String,
        readerName: String,
        registryLocal: String? = nil,
        terminalBody: String
    ) -> String {
        guard !middleware.isEmpty else {
            // The courier is taken apart here, in the register closure's own frame. Both halves come out of
            // one `takeContents()` because the registry is linear: it cannot be read off a borrow, and two
            // consuming methods cannot both be called on one courier.
            let registry =
                registryLocal.map { "let \($0) = \(contentsLocal).responseHeaders.take()\n" } ?? ""
            let contents = "let \(contentsLocal) = requestContext.takeContents()\n"
            // `hoistedPreamble` carries a variant witness's doubles correlation, so it has to lead here too
            // — not only on the fold path.
            return """
                \(registerCall) { \(requestName), \(contextName), \(parametersName), \(readerName), responseSender in
                \(hoistedPreamble)\(contents)\(registry)\(terminalBody)
                }
                """
        }
        // `middleware` holds each fold entry's expression — a graph binding read off the proxy
        // (`self._wire<Type>` / `self._wire<key>`) or a lifted factory's `create` call — computed by
        // `middlewareConstructions`. `hoistedPreamble` (a variant witness whose fold threads doubles) binds
        // `wireMVCDoubles` above the fold so the `create(doubles:)` reads it; it's empty otherwise.
        let fold = middleware.joined(separator: "\n")
        // The registry comes out of the courier here and goes straight into the box, which owns it for the
        // rest of the request and threads it through the fold — so a transforming middleware that rebuilds
        // the box carries the same one (the parameter is required, which is what makes losing it a compile
        // error rather than a vanished header).
        //
        // The terminal then takes it back **off the box's own destructure**, as the fifth yielded value,
        // rather than off a local captured above the fold. That is the whole point of the exercise: a
        // capture is task-isolated, and a sender wrapped with a task-isolated registry cannot be handed on
        // `sending` — which is what stopped a `@RawRoute` declaring `consuming sending Sender`.
        //
        // The route identity the fold's box carries. Both halves are already in this frame: the template
        // is the `path:` the route registers under — compile-time text — and the parameters are the
        // register closure's third argument, which is why this needs no plumbing through the router. The
        // parameter is bound unconditionally on this path (rather than `\(parametersName)`, which is `_`
        // for a route with no `@Path` binds) because the box wants it whether the handler does or not.
        // `registerNotFound` has no matched template, so it passes `nil` — and folds nothing today anyway.
        let routeExpression =
            routeTemplate.map { "RouteContext(template: \"\($0)\", pathParameters: pathParameters)" } ?? "nil"
        return """
            \(registerCall) { request, requestContext, pathParameters, reader, responseSender in
                \(hoistedPreamble)let \(contentsLocal) = requestContext.takeContents()
                let \(baseContextLocal) = \(contentsLocal).base
                let \(foldRegistryLocal) = \(contentsLocal).responseHeaders.take()
                let \(foldRouteLocal) = \(routeExpression)
                let wireMVCBaseBox = RequestResponseMiddlewareBox.pending(request: request, requestContext: \(baseContextLocal), route: \(foldRouteLocal), reader: reader, responseSender: responseSender, responseHeaders: \(foldRegistryLocal))
                let wireMVCChain = wireCompose {
            \(fold)
                }
                try await wireMVCChain.intercept(input: wireMVCBaseBox) { wireMVCFinalBox in
                    return try await wireMVCFinalBox.withPendingContents { \(requestName), \(contextName), _, \(readerName), responseSender, \(registryLocal ?? unusedRegistryLocal) in
                    \(unusedRegistryDiscard(registryLocal))\(terminalBody)
                    }
                }
            }
            """
    }

    /// The fold-entry expression for each `@Middleware(...)`, in written order. Every middleware is read
    /// from the graph, off the proxy field the plugin lifts it onto — never constructed inline. The
    /// dispatch on the argument:
    /// - `T.self` → `self._wire<T>` — the middleware is a graph binding, injected by type. The plugin's
    ///   `.injectsFromGraph` pass gives the proxy a `_wire<T>` field holding that binding.
    /// - a key that names a `@Factory` template (`factoryKeys`) → `self._wireFactory_<key>.create(
    ///   Builder.RequestContext.Base.self, Builder.Reader.self, Builder.ResponseSender.self)` — the
    ///   generic-with-deps factory case. The plugin synthesises `_WireFactory_<key>` and lifts it onto the
    ///   proxy; the fold calls its `create`, specialised at the builder's box associated types.
    /// - any other key → `self._wire<key>` — a keyed graph binding, injected by the same
    ///   `.injectsFromGraph` pass under the sanitised-key field name.
    func middlewareConstructions(from attributes: AttributeListSyntax) -> [String] {
        var constructions: [String] = []
        for case let .attribute(attr) in attributes
        where attr.attributeName.trimmedDescription == "Middleware" {
            guard
                let arguments = attr.arguments?.as(LabeledExprListSyntax.self),
                let first = arguments.first
            else { continue }
            let expression = first.expression.trimmedDescription
            if expression.hasSuffix(".self") {
                let type = String(expression.dropLast(".self".count))
                constructions.append("self.\(dependencyPropertyName(forType: type))")
            } else if factoryKeys.contains(expression) {
                let property = factoryPropertyName(forKey: expression)
                // A mock-consuming factory under this variant is a swift-wire variant factory: its `create`
                // takes the per-request `doubles` ahead of the box-role metatypes (the mocked `@Inject` rides
                // the call). Every other factory's `create` is box-role-only, as in production.
                let doublesArgument = doublesThreadedFactoryKeys.contains(expression) ? Self.doublesCreateArgument : ""
                constructions.append(
                    "self.\(property).create(\(doublesArgument)Builder.RequestContext.Base.self, Builder.Reader.self, Builder.ResponseSender.self)"
                )
            } else {
                constructions.append("self.\(dependencyPropertyName(forKey: expression))")
            }
        }
        return constructions
    }
}
