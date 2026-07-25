import SwiftSyntax

// The route-registration codegen — the domain half of a route contributor. Ported verbatim from the
// `@Controller` macro's per-route generation (verbs → `builder.register`, `@Path`/`@Query`/`@JSONBody`/
// `@Header` bindings, `@JSONResponse`/`@ResponseStatus`, `@RawRoute`, the `~Copyable` middleware fold),
// with two seams so one generator serves both callers:
//   • `subjectAccessor` — the stored field the witness calls the controller through. The macro's peer
//     struct names it `controller`; the plugin-emitted structural proxy names it `_wireSubject`. The
//     factory fields (`_wireFactory_<key>`) are named identically on both, so only this one differs.
//   • diagnostics are collected into an array rather than emitted to a macro expansion context, so the
//     `WireMVCRouteGen` tool can resolve their source locations and print compiler-style lines.
//
// This is the single source of truth: the macro and the tool both fold their witness body from
// `RouteBlockGenerator`, so the register/bind/encode logic can't drift between them. The generator's
// methods are split across extensions (per concern) to keep any one type body readable.

/// Generates the `builder.register` blocks that make up a route-contributor witness body, accumulating
/// any route-shape diagnostics. One instance per controller (holds the accumulated diagnostics).
struct RouteBlockGenerator {
    /// The field the witness calls the controller through — `controller` (macro peer struct) or
    /// `_wireSubject` (plugin-emitted structural proxy).
    let subjectAccessor: String
    /// The `@Factory` template keys visible across the input sources — how a non-`.self`
    /// `@Middleware(X)` argument is classified: a key in this set is a factory (its `create` is called
    /// on the lifted `_wireFactory_<key>`); any other key is a graph binding (referenced as `_wire<key>`).
    let factoryKeys: Set<String>
    /// The `@WireMVCBootstrap` composition root's `@ErrorResponse` entries (M5.5 Phase 3) — the **global
    /// default tier**, folded into every route's terminal after the controller's own, before the
    /// binding-error built-in. Empty for the `@Controller` macro path (which has no whole-graph view of
    /// the Bootstrap); populated by `WireMVCRouteGen`, which reads the Bootstrap once.
    let globalErrorMappings: [ErrorMapping]
    /// Set for a `@Scoped(seed:)` controller (the seed type): its routes construct the controller fresh
    /// per request from the proxy's `_wireEnterScope` thunk, rather than calling the held `_wireSubject`.
    /// `nil` for an app-scoped (`@Singleton`) controller. Set at the start of `routeBlocks`.
    private var scopedSeedType: String?
    /// Set when this controller is a keyed-harness *variant subject* (H2.2b): a `@Scoped(seed:)` controller
    /// whose injected slot a `TestingKey`'s `@BindType` substitutes, in a test target that links
    /// `WireMVCTesting`. Its scoped routes gain a per-request keyed branch — header → per-key doubles →
    /// variant proxy, else an explicit 500 — around the untouched production scope entry. `nil` for every
    /// other controller (and the whole production path), whose prologue is byte-for-byte unchanged.
    var keyedScopeEntry: KeyedScopeEntry?
    private(set) var diagnostics: [RouteCodegenDiagnostic] = []

    /// The expression the witness calls the controller through — a per-request `wireMVCController` local
    /// for a scoped controller, else the held subject field (`self._wireSubject`).
    var subjectExpression: String {
        scopedSeedType == nil ? "self.\(subjectAccessor)" : scopeEntryLocalName
    }

    /// The per-request scoped-controller local's name — deliberately `wireMVC`-prefixed so it can't
    /// collide with a handler's decoded parameter locals.
    private let scopeEntryLocalName = "wireMVCController"

    /// The per-request scope-teardown closure's local name — the `@Teardown` walk for the request scope's
    /// own bindings, returned by `_wireEnterScope` alongside the controller (M5.4.5).
    private let scopeTeardownLocalName = "wireMVCScopeTeardown"

    /// The lines that enter the request scope, prepended to a scoped route's terminal body. `_wireEnterScope`
    /// returns `(controller, teardown)`; the controller is dispatched on, and an **async `defer`** runs the
    /// scope teardown on *every* exit of the enclosing scope (handler return, a mapped/rethrown throw) — and,
    /// being declared after entry, is skipped when entry itself throws (nothing was constructed). Teardown
    /// errors are collected by the closure and discarded here (the response is the request's outcome). The
    /// seed is the register closure's `request` (seed-from-`HTTPRequest`).
    private var scopeEntryProloguePrefix: String {
        guard scopedSeedType != nil else { return "" }
        guard let keyed = keyedScopeEntry else {
            return """
                let (\(scopeEntryLocalName), \(scopeTeardownLocalName)) = try await self.\(contributorProxyScopeEntryAccessor)(request)
                defer { _ = await \(scopeTeardownLocalName)() }

                """
        }
        // The in-`do` half: enter request scope via the variant proxy when a keyed suite is active and its
        // doubles were resolved by the preamble, else the untouched production `_wireEnterScope`. Both
        // `_wireEnterScope` calls stay inside the `do` so their throws are mapped by the route's catch.
        return """
            let (\(scopeEntryLocalName), \(scopeTeardownLocalName)): (\(keyed.subjectType), @Sendable () async -> [any Error])
            if let wireMVCVariantProxy, let wireMVCDoubles {
            (\(scopeEntryLocalName), \(scopeTeardownLocalName)) = try await wireMVCVariantProxy.\(contributorProxyScopeEntryAccessor)(request, wireMVCDoubles)
            } else {
            (\(scopeEntryLocalName), \(scopeTeardownLocalName)) = try await self.\(contributorProxyScopeEntryAccessor)(request)
            }
            defer { _ = await \(scopeTeardownLocalName)() }

            """
    }

    /// The keyed scope-entry *preamble* for a variant subject (H2.2b), emitted **before** the route's `do`
    /// block — so its explicit-500 send escapes the closure directly rather than routing through the `catch`
    /// (which would re-consume the `consuming` sender). The dispatch gates on the per-key `@TaskLocal` variant
    /// proxy: the keyed `.wiremvc(_:)` factory binds it around the serve, so a non-`nil` read means a keyed
    /// suite is driving this route and doubles are mandatory. It resolves `wireMVCVariantProxy` +
    /// `wireMVCDoubles` for the in-`do` entry: under a keyed suite a request whose correlated doubles are
    /// present carries them through (the `@BindType`d slot resolves to the supplied mock), and a request that
    /// reaches the route with no supplied doubles — no header, or no store entry — is an explicit 500. When
    /// the task-local is unbound (a keyless `.wiremvc()` suite, or any non-keyed serving) both locals are
    /// `nil` and the route takes the production path.
    private var scopeEntryPreamble: String {
        guard scopedSeedType != nil, let keyed = keyedScopeEntry else { return "" }
        let missingMessage =
            "WireMVC keyed test harness: no bound doubles for a request reaching this route under key "
            + "\(keyed.keyReference) — wrap the request in withBindValues(...)\\n"
        return """
            let wireMVCVariantProxy = \(keyed.harnessEnumName).\(keyed.variantProxyBoxName)
            let wireMVCDoubles: \(keyed.doublesTypeName)?
            if wireMVCVariantProxy != nil {
            guard
            let wireMVCCorrelationID = wireMVCTestCorrelationID(in: request),
            let wireMVCResolvedDoubles = \(keyed.harnessEnumName).\(keyed.doublesStoreName).value(for: wireMVCCorrelationID)
            else {
            try await WireMVCOutcome.body([UInt8]("\(missingMessage)".utf8), .internalServerError).send(on: responseSender)
            return
            }
            wireMVCDoubles = wireMVCResolvedDoubles
            } else {
            wireMVCDoubles = nil
            }

            """
    }

    /// The joined `builder.register` blocks for every verb-annotated function on the controller — the
    /// witness body. A route that fails validation is diagnosed at its offending node and skipped, so
    /// the rest of the controller still generates (no cascade of downstream errors).
    mutating func routeBlocks(of controller: ControllerDeclaration, pathPrefix: String) -> String {
        scopedSeedType = controller.scopedSeedType
        // Controller-scope `@Middleware` wraps every route, outer to each route's own middleware.
        let controllerMiddleware = middlewareConstructions(from: controller.attributes)
        // Controller-scope `@ErrorResponse` covers every route, consulted after each route's own.
        let controllerErrorMappings = errorMappings(from: controller.attributes, scopeLabel: "controller")
        var blocks: [String] = []
        for function in controller.functions {
            guard let verb = verb(from: function.attributes) else { continue }  // no verb → helper, skip
            if let block = routeBlock(
                function: function,
                verb: verb,
                prefix: pathPrefix,
                controllerMiddleware: controllerMiddleware,
                controllerErrorMappings: controllerErrorMappings
            ) {
                blocks.append(block)
            }
        }
        return blocks.joined(separator: "\n")
    }

    private mutating func routeBlock(
        function: FunctionDeclSyntax,
        verb: Verb,
        prefix: String,
        controllerMiddleware: [String],
        controllerErrorMappings: [ErrorMapping]
    ) -> String? {
        let path = joinPath(prefix, verb.path ?? "")
        let middleware = controllerMiddleware + middlewareConstructions(from: function.attributes)
        if hasRawRoute(function) {
            return rawRouteBlock(function: function, verb: verb, path: path, middleware: middleware)
        }
        let hasBody = routeHasBody(function)
        guard let (binds, callArgs) = parameterBindings(of: function, path: path, hasBody: hasBody)
        else { return nil }
        let hasBinds = !binds.isEmpty
        let call = "try await \(subjectExpression).\(function.name.text)(\(callArgs.joined(separator: ", ")))"
        guard let response = responseComputation(from: function, call: call) else { return nil }
        // Route-scope `@ErrorResponse` is consulted before the controller's (route overrides controller);
        // the Bootstrap's global tier is the default, consulted last (M5.5 Phase 3).
        let errorMappings =
            self.errorMappings(from: function.attributes, scopeLabel: "route")
            + controllerErrorMappings
            + globalErrorMappings
        // A scoped controller's terminal always needs `request` — it is the scope-entry seed.
        let requestName = (hasBinds || scopedSeedType != nil) ? "request" : "_"
        let parametersName = hasBinds ? "pathParameters" : "_"
        let readerName = hasBody ? "reader" : "_"
        return emitRegister(
            verb: verb,
            path: path,
            middleware: middleware,
            requestName: requestName,
            contextName: "_",
            parametersName: parametersName,
            readerName: readerName,
            terminalBody: closureBody(
                hasBinds: hasBinds,
                hasBody: hasBody,
                binds: binds,
                response: response,
                scopeEntryPreamble: scopeEntryPreamble,
                scopeEntryPrologue: scopeEntryProloguePrefix,
                errorMappings: errorMappings
            )
        )
    }
}

// MARK: - Raw route codegen

extension RouteBlockGenerator {
    private enum RawRole { case context, reader, sender }

    private func hasRawRoute(_ function: FunctionDeclSyntax) -> Bool {
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
    fileprivate mutating func rawRouteBlock(
        function: FunctionDeclSyntax,
        verb: Verb,
        path: String,
        middleware: [String]
    ) -> String? {
        guard let mapping = rawCallArgs(function) else { return nil }
        return emitRegister(
            verb: verb,
            path: path,
            middleware: middleware,
            requestName: mapping.used.contains("request") ? "request" : "_",
            contextName: mapping.used.contains("requestContext") ? "requestContext" : "_",
            parametersName: mapping.used.contains("pathParameters") ? "pathParameters" : "_",
            readerName: mapping.used.contains("reader") ? "reader" : "_",
            terminalBody:
                "try await self.\(subjectAccessor).\(function.name.text)(\(mapping.callArgs.joined(separator: ", ")))"
        )
    }

    /// The raw-route role mapping: for each handler parameter, the register-closure primitive it binds
    /// to (explicit `@RawRoute(.role, …)` or inferred by type/constraint), plus which primitives are
    /// used. Shared by `rawRouteBlock` (routes) and `notFoundRegistration` (the `@NotFound` fallback).
    /// `nil` with a diagnostic on an unbindable parameter or a missing response sender.
    private mutating func rawCallArgs(
        _ function: FunctionDeclSyntax
    ) -> (callArgs: [String], used: Set<String>)? {
        let params = Array(function.signature.parameterClause.parameters)
        var callArgs: [String] = []
        var used: Set<String> = []

        if let explicitRoles = explicitRawRoles(function) {
            guard explicitRoles.count == params.count else {
                diagnostics.append(
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
            for (param, role) in zip(params, explicitRoles) {
                guard let primitive = rawPrimitive(forRoleName: role) else {
                    diagnostics.append(
                        RouteCodegenDiagnostic(.unsupportedRawParameter(name: role, type: role), at: param)
                    )
                    return nil
                }
                callArgs.append("\(rawArgumentLabel(param))\(primitive)")
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
                    diagnostics.append(
                        RouteCodegenDiagnostic(.unsupportedRawParameter(name: name, type: type), at: param)
                    )
                    return nil
                }
                callArgs.append("\(rawArgumentLabel(param))\(primitive)")
                used.insert(primitive)
            }
        }

        guard used.contains("responseSender") else {
            diagnostics.append(
                RouteCodegenDiagnostic(.rawRouteMissingSender(function.name.text), at: function.name)
            )
            return nil
        }
        return (callArgs, used)
    }

    /// The `builder.registerNotFound { … }` for a `@NotFound` handler method (M5.5 Phase 4), called
    /// through `subjectExpression` (the generated `@main`'s `bootstrap` local — not `self`). In practice
    /// the method is `@RawRoute` (it writes the response directly); the raw role mapping is reused, so a
    /// `@NotFound @RawRoute func handleNotFound(request:, responseSender:)` binds exactly like a route.
    /// `nil` with a diagnostic if the mapping fails (e.g. no response sender).
    mutating func notFoundRegistration(function: FunctionDeclSyntax, subjectExpression: String) -> String? {
        guard hasRawRoute(function) else {
            diagnostics.append(RouteCodegenDiagnostic(.notFoundNotRaw(function.name.text), at: function.name))
            return nil
        }
        guard let mapping = rawCallArgs(function) else { return nil }
        return emitRegisterClosure(
            registerCall: "builder.registerNotFound",
            middleware: [],
            requestName: mapping.used.contains("request") ? "request" : "_",
            contextName: mapping.used.contains("requestContext") ? "requestContext" : "_",
            parametersName: "_",
            readerName: mapping.used.contains("reader") ? "reader" : "_",
            terminalBody:
                "try await \(subjectExpression).\(function.name.text)(\(mapping.callArgs.joined(separator: ", ")))"
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

// MARK: - Register call & middleware fold

extension RouteBlockGenerator {
    /// The `builder.register` call, wrapping the terminal in the route's middleware fold when there is
    /// one. `requestName`/`contextName`/`parametersName`/`readerName` name (or `_`) the values the
    /// *terminal* uses. With no middleware they name the register closure's params directly. With
    /// middleware, the register closure binds request/context/reader/sender unconditionally to build the
    /// base box, and the terminal re-binds its values off the folded final box via `withContents` —
    /// path parameters are captured from the register closure (never boxed).
    fileprivate func emitRegister(
        verb: Verb,
        path: String,
        middleware: [String],
        requestName: String,
        contextName: String,
        parametersName: String,
        readerName: String,
        terminalBody: String
    ) -> String {
        emitRegisterClosure(
            registerCall: "builder.register(method: \(verb.method), path: \"\(path)\")",
            middleware: middleware,
            requestName: requestName,
            contextName: contextName,
            parametersName: parametersName,
            readerName: readerName,
            terminalBody: terminalBody
        )
    }

    /// The register-closure emission, shared by `builder.register(method:path:)` (routes) and
    /// `builder.registerNotFound` (the `@NotFound` fallback, M5.5 Phase 4) — the closure body is
    /// identical; only the call that takes it differs. `registerCall` is everything up to the trailing
    /// closure.
    fileprivate func emitRegisterClosure(
        registerCall: String,
        middleware: [String],
        requestName: String,
        contextName: String,
        parametersName: String,
        readerName: String,
        terminalBody: String
    ) -> String {
        guard !middleware.isEmpty else {
            return """
                \(registerCall) { \(requestName), \(contextName), \(parametersName), \(readerName), responseSender in
                \(terminalBody)
                }
                """
        }
        // `middleware` holds each fold entry's expression — a graph binding read off the proxy
        // (`self._wire<Type>` / `self._wire<key>`) or a lifted factory's `create` call — computed by
        // `middlewareConstructions`.
        let fold = middleware.joined(separator: "\n")
        return """
            \(registerCall) { request, requestContext, \(parametersName), reader, responseSender in
                let wireMVCBaseBox = RequestResponseMiddlewareBox.pending(request: request, requestContext: requestContext, reader: reader, responseSender: responseSender)
                let wireMVCChain = wireCompose {
            \(fold)
                }
                try await wireMVCChain.intercept(input: wireMVCBaseBox) { wireMVCFinalBox in
                    try await wireMVCFinalBox.withPendingContents { \(requestName), \(contextName), \(readerName), responseSender in
                    \(terminalBody)
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
    ///   Builder.RequestContext.self, Builder.Reader.self, Builder.ResponseSender.self)` — the
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
                constructions.append(
                    "self.\(property).create(Builder.RequestContext.self, Builder.Reader.self, Builder.ResponseSender.self)"
                )
            } else {
                constructions.append("self.\(dependencyPropertyName(forKey: expression))")
            }
        }
        return constructions
    }
}

// MARK: - Parameter binding & response

extension RouteBlockGenerator {
    /// The `let <name> = try await <Binding><<Type>>.bind(...)` lines and the handler call argument
    /// list, one entry per handler parameter.
    fileprivate mutating func parameterBindings(
        of function: FunctionDeclSyntax,
        path: String,
        hasBody: Bool
    ) -> (binds: [String], callArgs: [String])? {
        var binds: [String] = []
        var callArgs: [String] = []
        for param in function.signature.parameterClause.parameters {
            let internalName = (param.secondName ?? param.firstName).text
            let isWildcard = param.firstName.tokenKind == .wildcard
            guard let binding = self.binding(from: param.attributes) else {
                diagnostics.append(RouteCodegenDiagnostic(.unannotatedParameter(internalName), at: param))
                return nil
            }
            let bindingName = binding.name ?? (isWildcard ? internalName : param.firstName.text)
            // `@Path name` must have a matching `{name}` in the route template — otherwise it can only
            // ever fail at runtime (`missingPathParameter`), so reject it at the seam.
            if binding.wrapper == "Path", !path.contains("{\(bindingName)}") {
                diagnostics.append(
                    RouteCodegenDiagnostic(.pathPlaceholderMissing(name: bindingName, path: path), at: param)
                )
                return nil
            }
            binds.append(
                "let \(internalName) = \(bindExpression(for: param, binding: binding, name: bindingName, hasBody: hasBody))"
            )
            callArgs.append(isWildcard ? internalName : "\(param.firstName.text): \(internalName)")
        }
        return (binds, callArgs)
    }

    /// The binding call for one parameter: `bindOptional` (→ `T?`) for an optional type,
    /// `bindOptional(...) ?? default` for a defaulted parameter, else the throwing `bind`. `body` is
    /// the collected request body (`requestBody`) for routes with a `@JSONBody`, else `nil`.
    private func bindExpression(
        for param: FunctionParameterSyntax,
        binding: Binding,
        name: String,
        hasBody: Bool
    ) -> String {
        let type = param.type.trimmedDescription
        let bodyArgument = hasBody ? "requestBody" : "nil"
        let args = "name: \"\(name)\", request: request, pathParameters: pathParameters, body: \(bodyArgument)"
        if type.hasSuffix("?") {
            let underlying = String(type.dropLast())
            return "try await \(binding.wrapper)<\(underlying)>.bindOptional(\(args))"
        }
        if let defaultValue = param.defaultValue?.value.trimmedDescription {
            return "try await \(binding.wrapper)<\(type)>.bindOptional(\(args)) ?? \(defaultValue)"
        }
        return "try await \(binding.wrapper)<\(type)>.bind(\(args))"
    }

    /// The statement that assigns `wireMVCOutcome`: a JSON body (`@JSONResponse`) or a bare status
    /// (`@ResponseStatus`, after calling the handler for its effect). One response annotation is
    /// required.
    fileprivate mutating func responseComputation(from function: FunctionDeclSyntax, call: String) -> String? {
        let attributes = function.attributes
        let route = function.name.text
        let returnsValue = functionReturnsValue(function)
        if let status = jsonResponseStatus(from: attributes) {
            guard returnsValue else {
                diagnostics.append(RouteCodegenDiagnostic(.jsonResponseOnVoid(route), at: function.name))
                return nil
            }
            return "wireMVCOutcome = try WireMVCResponse.json(\(call), status: \(status))"
        }
        if let status = responseStatus(from: attributes) {
            guard !returnsValue else {
                diagnostics.append(RouteCodegenDiagnostic(.responseStatusOnValue(route), at: function.name))
                return nil
            }
            return "\(call)\nwireMVCOutcome = .status(\(status))"
        }
        diagnostics.append(RouteCodegenDiagnostic(.missingResponseAnnotation(route), at: function.name))
        return nil
    }

    /// Whether the handler returns a non-`Void` value — drives the `@JSONResponse`/`@ResponseStatus`
    /// vs. signature check. No return clause, or `Void`/`()`, is treated as Void.
    private func functionReturnsValue(_ function: FunctionDeclSyntax) -> Bool {
        guard let returnType = function.signature.returnClause?.type else { return false }
        let text = returnType.trimmedDescription
        return text != "Void" && text != "()"
    }

    /// The registration closure body. Compute the outcome — collecting the body first when a
    /// `@JSONBody` is present, mapping a `WireMVCBindingError` to its status — then send it once.
    ///
    /// Every typed terminal wraps its body — the scope-entry prologue (a throwing request-scoped binding),
    /// the body collect, the parameter binds, and the handler call + response encode — in a single `do`,
    /// and the `catch` consults the composed mappings (route-inner first) → binding-error built-in →
    /// `Swift.Error` catch-all → the **built-in 500** (via `errorCatchClause`, which never re-throws). So
    /// the terminal always holds the sender and writes a response; an unmapped throw is a clean `500`, not
    /// a dropped connection (M5.5 Phase 2). The `catch` binds `wireMVCError` only when the catch body
    /// references it (mappings or the binding-error built-in); a pure-500 terminal doesn't, so the
    /// binding is conditional to avoid an unused-variable warning.
    fileprivate func closureBody(
        hasBinds: Bool,
        hasBody: Bool,
        binds: [String],
        response: String,
        scopeEntryPreamble: String,
        scopeEntryPrologue: String,
        errorMappings: [ErrorMapping]
    ) -> String {
        let collect = hasBody ? "let requestBody = try await WireMVCRequest.collectBody(reader)\n" : ""
        let bindsBlock = binds.isEmpty ? "" : binds.joined(separator: "\n") + "\n"
        let referencesError = !errorMappings.isEmpty || hasBinds
        let catchClause = referencesError ? "} catch let wireMVCError {" : "} catch {"
        // The keyed-harness preamble (empty for every other route) sits *before* the `do`, so its explicit
        // 500 send escapes the closure directly rather than re-consuming the `consuming` sender through the
        // `catch`.
        return """
            \(scopeEntryPreamble)let wireMVCOutcome: WireMVCOutcome
            do {
            \(scopeEntryPrologue)\(collect)\(bindsBlock)\(response)
            \(catchClause)
            \(errorCatchClause(mappings: errorMappings, includeBindingBuiltin: hasBinds))
            }
            try await wireMVCOutcome.send(on: responseSender)
            """
    }

    fileprivate func routeHasBody(_ function: FunctionDeclSyntax) -> Bool {
        for param in function.signature.parameterClause.parameters {
            if let binding = binding(from: param.attributes), binding.wrapper == "JSONBody" {
                return true
            }
        }
        return false
    }
}

// MARK: - Attribute reading

extension RouteBlockGenerator {
    fileprivate struct Verb {
        let method: String  // e.g. ".get"
        let path: String?
    }

    private struct Binding {
        let wrapper: String  // e.g. "Path"
        let name: String?
    }

    private func verbMethod(for name: String) -> String? {
        switch name {
        case "Get": return ".get"
        case "Post": return ".post"
        case "Put": return ".put"
        case "Patch": return ".patch"
        case "Delete": return ".delete"
        default: return nil
        }
    }

    fileprivate func verb(from attributes: AttributeListSyntax) -> Verb? {
        for case let .attribute(attr) in attributes {
            let name = attr.attributeName.trimmedDescription
            if let method = verbMethod(for: name) {
                return Verb(method: method, path: firstStringLiteral(attr.arguments))
            }
        }
        return nil
    }

    private func binding(from attributes: AttributeListSyntax) -> Binding? {
        for case let .attribute(attr) in attributes {
            let name = attr.attributeName.trimmedDescription
            if routeBindingWrappers.contains(name) {
                return Binding(wrapper: name, name: firstStringLiteral(attr.arguments))
            }
        }
        return nil
    }

    /// The `@JSONResponse` status expression (verbatim), `.ok` if present without a status, or `nil`
    /// if there's no `@JSONResponse`.
    private func jsonResponseStatus(from attributes: AttributeListSyntax) -> String? {
        for case let .attribute(attr) in attributes where attr.attributeName.trimmedDescription == "JSONResponse" {
            guard case let .argumentList(list) = attr.arguments else { return ".ok" }
            let statusArg = list.first { $0.label?.text == "status" }
            return statusArg?.expression.trimmedDescription ?? ".ok"
        }
        return nil
    }

    /// The `@ResponseStatus(_)` status expression (verbatim), or `nil` if absent.
    private func responseStatus(from attributes: AttributeListSyntax) -> String? {
        for case let .attribute(attr) in attributes where attr.attributeName.trimmedDescription == "ResponseStatus" {
            guard case let .argumentList(list) = attr.arguments, let first = list.first else { continue }
            return first.expression.trimmedDescription
        }
        return nil
    }

    private func firstStringLiteral(_ arguments: AttributeSyntax.Arguments?) -> String? {
        guard case let .argumentList(list) = arguments, let first = list.first else { return nil }
        return first.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
    }

    /// Join a controller prefix and a verb subpath into one `{name}`-template path.
    private func joinPath(_ prefix: String, _ sub: String) -> String {
        let head = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        let tail = sub.isEmpty ? "" : (sub.hasPrefix("/") ? sub : "/" + sub)
        let joined = head + tail
        return joined.isEmpty ? "/" : joined
    }
}

/// The binding-wrapper attribute names a handler parameter can carry. File-scope (not a stored property)
/// so the generator's methods can live in extensions.
private let routeBindingWrappers: Set<String> = ["Path", "Query", "JSONBody", "Header"]

// MARK: - Error response codegen (`@ErrorResponse`)

/// How an `@ErrorResponse` entry produces the outcome — a bare status (the `(E.self, .status)` form) or a
/// callable applied to the bound error (an inline `{ (e: E) in … }` closure). File-scope to keep the
/// generator's nested types one level deep.
private enum ErrorResponder {
    case status(String)  // a status expression, e.g. ".notFound"
    case call(String)  // a callable expression: "({ (e: T) in … })"
}

/// One `@ErrorResponse` entry: the error type it matches, whether that type is the `Swift.Error`
/// catch-all, and how it produces the outcome — a bare status (the `(E.self, .status)` form) or an
/// inline `{ (e: E) in … }` closure applied to the bound error. Public (top-level, not nested in the
/// internal `RouteBlockGenerator`) so it can appear in the render functions' signatures — the global
/// (Bootstrap) tier is threaded to them as `[ErrorMapping]`. Constructed only in this file (its
/// `responder` is `fileprivate`), so nothing outside the codegen can build one.
public struct ErrorMapping {
    let errorType: String
    let isCatchAll: Bool
    fileprivate let responder: ErrorResponder
    var isThrowing: Bool { if case .call = responder { return true } else { return false } }
}

extension RouteBlockGenerator {
    /// Read the `@ErrorResponse` entries on one scope's attributes (controller or route), in source
    /// order, resolving a static-method reference against the controller declaration. Appends the
    /// duplicate-type and catch-all-ordering diagnostics.
    mutating func errorMappings(from attributes: AttributeListSyntax, scopeLabel: String) -> [ErrorMapping] {
        var mappings: [ErrorMapping] = []
        var seenTypes: Set<String> = []
        var catchAllSeen = false
        for case let .attribute(attr) in attributes
        where attr.attributeName.trimmedDescription == "ErrorResponse" {
            guard let mapping = errorMapping(from: attr) else { continue }
            if catchAllSeen {
                diagnostics.append(RouteCodegenDiagnostic(.errorResponseCatchAllNotLast(scope: scopeLabel), at: attr))
            }
            if !seenTypes.insert(mapping.errorType).inserted {
                diagnostics.append(
                    RouteCodegenDiagnostic(
                        .errorResponseDuplicateType(type: mapping.errorType, scope: scopeLabel),
                        at: attr
                    )
                )
            }
            if mapping.isCatchAll { catchAllSeen = true }
            mappings.append(mapping)
        }
        return mappings
    }

    /// Parse one `@ErrorResponse(...)` attribute, or `nil` (with a diagnostic) if it can't be resolved.
    private mutating func errorMapping(from attr: AttributeSyntax) -> ErrorMapping? {
        guard let arguments = attr.arguments?.as(LabeledExprListSyntax.self), let first = arguments.first
        else { return nil }
        // Form (1): `(E.self, .status)`.
        if arguments.count >= 2, let status = arguments.dropFirst().first {
            let typeExpr = first.expression.trimmedDescription
            guard typeExpr.hasSuffix(".self") else {
                diagnostics.append(RouteCodegenDiagnostic(.errorResponseUnresolvedMapping(typeExpr), at: attr))
                return nil
            }
            let errorType = String(typeExpr.dropLast(".self".count))
            return ErrorMapping(
                errorType: errorType,
                isCatchAll: isCatchAllErrorType(errorType),
                responder: .status(status.expression.trimmedDescription)
            )
        }
        // Form (3): an inline typed-parameter closure.
        if let closure = first.expression.as(ClosureExprSyntax.self) {
            guard let paramType = closureParameterType(closure) else {
                diagnostics.append(RouteCodegenDiagnostic(.errorResponseClosureNeedsTypedParameter, at: closure))
                return nil
            }
            return ErrorMapping(
                errorType: paramType,
                isCatchAll: isCatchAllErrorType(paramType),
                responder: .call("(\(closure.trimmedDescription))")
            )
        }
        // A named-function reference (`@ErrorResponse(SomeType.map)`) is deferred: a reference to the
        // annotated controller's own method is a circular macro reference (the compiler can't resolve the
        // type mid-expansion), and a reference to a separate type needs cross-module signature resolution
        // the codegen doesn't do. Diagnose and steer to an inline closure. See Notes/RouteErrorHandling.md.
        diagnostics.append(
            RouteCodegenDiagnostic(.errorResponseUnresolvedMapping(first.expression.trimmedDescription), at: attr)
        )
        return nil
    }

    /// The closure's first parameter type (`{ (e: NotFound) in … }` → `"NotFound"`), or `nil` if the
    /// parameter is untyped (`{ e in … }`) — which can't be matched on and is diagnosed.
    private func closureParameterType(_ closure: ClosureExprSyntax) -> String? {
        guard let signature = closure.signature,
            case let .parameterClause(clause)? = signature.parameterClause,
            let type = clause.parameters.first?.type
        else { return nil }
        return type.trimmedDescription
    }

    /// Whether an error type is the `Swift.Error` / `any Error` catch-all — a trailing `Error` component
    /// after any `any ` prefix.
    private func isCatchAllErrorType(_ type: String) -> Bool {
        var base = type
        while base.hasPrefix("any ") { base = String(base.dropFirst("any ".count)) }
        return (base.split(separator: ".").last.map(String.init) ?? base) == "Error"
    }

    /// The `catch` clause body assigning `wireMVCOutcome` — consult the composed mappings (route-inner
    /// first, already ordered by the caller) → the built-in binding-error status → the `Swift.Error`
    /// catch-all if present, else the **built-in 500**. The chain always ends in a non-optional terminal
    /// (a declared catch-all, or `.status(.internalServerError)`), so the terminal always writes a
    /// response: the target servers *abort* an escaped throw rather than synthesising a 500, so WireMVC
    /// owns it (see LinearSenderErrorModel.md / M5.5 Phase 2). An unmapped throw — a handler error, a
    /// throwing request-scoped binding, or a decode failure with no matching `@ErrorResponse` — becomes a
    /// clean `500`, not a dropped connection.
    func errorCatchClause(mappings: [ErrorMapping], includeBindingBuiltin: Bool) -> String {
        var elements: [String] = []
        for mapping in mappings where !mapping.isCatchAll {
            elements.append(chainElement(mapping, terminal: false))
        }
        if includeBindingBuiltin {
            elements.append("(wireMVCError as? WireMVCBindingError).map { WireMVCOutcome.status($0.status) }")
        }
        if let catchAll = mappings.first(where: { $0.isCatchAll }) {
            elements.append(chainElement(catchAll, terminal: true))
        } else {
            elements.append("WireMVCOutcome.status(.internalServerError)")
        }

        let tryPrefix = mappings.contains(where: \.isThrowing) ? "try " : ""
        if elements.count == 1 {
            return "wireMVCOutcome = \(tryPrefix)\(elements[0])"
        }
        let chain = elements.joined(separator: "\n?? ")
        return "wireMVCOutcome = \(tryPrefix)(\n\(chain)\n)"
    }

    /// One element of the `??` consultation chain. A non-terminal element yields `WireMVCOutcome?`
    /// (nil = fall through); the terminal (catch-all) element yields a non-optional `WireMVCOutcome`.
    private func chainElement(_ mapping: ErrorMapping, terminal: Bool) -> String {
        switch mapping.responder {
        case .status(let status):
            return terminal
                ? "WireMVCOutcome.status(\(status))"
                : "(wireMVCError is \(mapping.errorType) ? WireMVCOutcome.status(\(status)) : nil)"
        case .call(let callable):
            return terminal
                ? "wireMVCRespondAny(to: wireMVCError, \(callable))"
                : "wireMVCRespond(to: wireMVCError, \(callable))"
        }
    }
}

// MARK: - Factory-lift naming (structural ↔ domain handshake)

/// Derive the synthesised factory names from a `@Middleware(key)`'s canonical key text, using the same
/// sanitiser swift-wire's factory synthesis uses (any character outside `[A-Za-z0-9_]` → `_`). Both
/// sides must agree so the plugin's construction call resolves to the lifted property and the fold's
/// `create` names it.
public func sanitizedKeyFragment(_ key: String) -> String {
    String(key.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
}
public func factoryPropertyName(forKey key: String) -> String { "_wireFactory_" + sanitizedKeyFragment(key) }
public func factoryTypeName(forKey key: String) -> String { "_WireFactory_" + sanitizedKeyFragment(key) }

/// The proxy field an `@Middleware(T.self)` binding is read through — the same name swift-wire's
/// adapter-dependency pass gives the by-type injected field: `_wire` + the simple (generics- and
/// namespace-stripped) type name, upper-cameled (`Mod.RequireAdmin<…>` → `_wireRequireAdmin`). Both
/// sides derive it identically so the witness and the plugin-emitted struct meet on the field.
public func dependencyPropertyName(forType type: String) -> String {
    let withoutGenerics = type.prefix { $0 != "<" }
    let simple = withoutGenerics.split(separator: ".").last.map(String.init) ?? String(withoutGenerics)
    return "_wire" + simple.prefix(1).uppercased() + simple.dropFirst()
}

/// The proxy field an `@Middleware(key)` binding is read through when `key` is a graph binding key (not
/// a `@Factory` template) — `_wire` + the sanitised key, matching swift-wire's keyed adapter-dependency
/// field name.
public func dependencyPropertyName(forKey key: String) -> String { "_wire" + sanitizedKeyFragment(key) }
