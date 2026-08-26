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
    /// User-declared bindings and their obligations, scanned from `@RequestBinding` declarations across the
    /// input sources (the consumer's and every Wire-aware dependency's). Empty for the `@Controller` macro
    /// path, which sees only the file it expands in — so the built-in wrappers stay recognised on their own,
    /// and a user binding needs the plugin.
    var discoveredBindings: [String: DeclaredRequestBinding] = [:]
    /// Response modes and their (terminal, codec, client body) triple, scanned from `@ResponseMode`
    /// declarations across the input sources. Defaults to the **built-ins alone**, which is what the
    /// `@Controller` macro path sees: it expands in one file and has not parsed `Macros.swift`, so a route
    /// annotated `@JSONResponse` must still generate identically there. A mode declared anywhere else needs
    /// the plugin, exactly as a user binding does.
    var discoveredModes: [String: DeclaredResponseMode] = [:]
    /// The `@WireMVCBootstrap` composition root's `@ErrorResponse` entries (M5.5 Phase 3) — the **global
    /// default tier**, folded into every route's terminal after the controller's own, before the
    /// binding-error built-in. Empty for the `@Controller` macro path (which has no whole-graph view of
    /// the Bootstrap); populated by `WireMVCRouteGen`, which reads the Bootstrap once.
    let globalErrorMappings: [ErrorMapping]
    /// The controller-scope `@Coding(T.self)` type, if it declares one. A route's own `@Coding` beats it,
    /// and the app's — passed into the witness as `wireMVCAppCoding` — is what both fall back to.
    var controllerCoding: String?
    /// The route currently being rendered, if it declares its own `@Coding`.
    var routeCoding: String?

    /// Which coding settings this route encodes and decodes with: route, then controller, then the app's,
    /// which the composition root resolved and passed in. Innermost wins, as `@Middleware` and
    /// `@ErrorResponse` do.
    var codingExpression: String {
        guard let reference = routeCoding ?? controllerCoding else { return "wireMVCAppCoding" }
        return "self.\(codingProxyField(for: reference))"
    }
    /// Set for a `@Scoped(seed:)` controller (the seed type): its routes construct the controller fresh
    /// per request from the proxy's `_wireEnterScope` thunk, rather than calling the held `_wireSubject`.
    /// `nil` for an app-scoped (`@Singleton`) controller. Set at the start of `routeBlocks`.
    var scopedSeedType: String?
    /// Set when this witness is a keyed-harness *variant* witness (H2.2b) — the one emitted on the variant
    /// proxy type for a `@Scoped(seed:)` subject in a test target that links `WireMVCTesting`. Its scoped
    /// routes correlate the request's per-key doubles from the `TestBindStore` (else an explicit 500) and
    /// enter request scope through the variant proxy (`self`). `nil` for the production witness (and every
    /// keyless path), whose prologue is byte-for-byte unchanged.
    var keyedScopeEntry: KeyedScopeEntry?
    /// The `@Factory` keys whose lifted factory is **mock-consuming** under this variant witness's key — swift-wire
    /// re-emits each as a variant factory whose `create` takes the per-request `doubles` (the mocked `@Inject`
    /// rides the call, not a held field). The fold threads `wireMVCDoubles` to those `create`s and leaves every
    /// other factory's `create` box-role-only. Empty for a production witness (no factory takes doubles).
    var doublesThreadedFactoryKeys: Set<String> = []
    private(set) var diagnostics: [RouteCodegenDiagnostic] = []

    /// Record a route-shape diagnostic. The array keeps its `private(set)` setter and this is the one way
    /// in, so the response half (ResponseCodegen.swift) can report without the storage becoming writable
    /// module-wide.
    mutating func record(_ diagnostic: RouteCodegenDiagnostic) {
        diagnostics.append(diagnostic)
    }

    /// The expression the witness calls the controller through — a per-request `wireMVCController` local for a
    /// scoped controller *or any variant witness* (which reconstructs the subject per request), else the held
    /// subject field (`self._wireSubject`) for a production app-`@Singleton` controller.
    var subjectExpression: String {
        scopedSeedType == nil && keyedScopeEntry == nil ? "self.\(subjectAccessor)" : scopeEntryLocalName
    }

    /// The `create` argument a mock-consuming variant factory's fold entry threads — the per-request doubles
    /// ahead of the box-role metatypes. Also the marker `foldThreadsDoubles` detects to hoist the doubles
    /// correlation above the fold (so `wireMVCDoubles` is in scope where the fold's `create` reads it).
    static let doublesCreateArgument = "doubles: wireMVCDoubles, "

    /// The per-request scoped-controller local's name — deliberately `wireMVC`-prefixed so it can't
    /// collide with a handler's decoded parameter locals.
    let scopeEntryLocalName = "wireMVCController"

    /// The per-request scope-teardown closure's local name — the `@Teardown` walk for the request scope's
    /// own bindings, returned by `_wireEnterScope` alongside the controller (M5.4.5).
    private let scopeTeardownLocalName = "wireMVCScopeTeardown"

    /// The lines that enter the request scope, prepended to a scoped route's terminal body. `_wireEnterScope`
    /// returns `(controller, teardown)`; the controller is dispatched on, and an **async `defer`** runs the
    /// scope teardown on *every* exit of the enclosing scope (handler return, a mapped/rethrown throw) — and,
    /// being declared after entry, is skipped when entry itself throws (nothing was constructed). Teardown
    /// errors are collected by the closure and discarded here (the response is the request's outcome). The
    /// seed is the register closure's `request` (seed-from-`HTTPRequest`).
    var scopeEntryProloguePrefix: String {
        // A production app-`@Singleton` controller is held (no scope entry); every scoped controller and every
        // variant witness (including a seedless app-scoped one) enters per request.
        guard scopedSeedType != nil || keyedScopeEntry != nil else { return "" }
        // Production seed-scoped: plain entry. Variant seed-scoped: `(request, doubles)`. Variant **seedless**
        // (app-`@Singleton` `@TestScopable`): `(doubles)` only — the controller can't consume the request, so
        // the rebuild takes just the mock. The `_wireEnterScope` call stays in the `do` so its throw is mapped.
        let entryCall: String
        if keyedScopeEntry == nil {
            entryCall = "self.\(contributorProxyScopeEntryAccessor)(request)"
        } else if scopedSeedType != nil {
            entryCall = "self.\(contributorProxyScopeEntryAccessor)(request, wireMVCDoubles)"
        } else {
            entryCall = "self.\(contributorProxyScopeEntryAccessor)(wireMVCDoubles)"
        }
        return """
            let (\(scopeEntryLocalName), \(scopeTeardownLocalName)) = try await \(entryCall)
            defer { _ = await \(scopeTeardownLocalName)() }

            """
    }

    /// The keyed scope-entry *preamble* for a variant subject's witness (H2.2b), emitted **before** the route's
    /// `do` block — so its explicit-500 send escapes the closure directly rather than routing through the
    /// `catch` (which would re-consume the `consuming` sender). The variant witness is registered only under a
    /// keyed suite (the keyed `.wiremvc(_:)` factory hand-registers it), so doubles are always mandatory here:
    /// it correlates the request's doubles from the per-key `TestBindStore` (by the `X-WireMVC-Test-Binds`
    /// header) into `wireMVCDoubles` for the in-`do` entry — the `@BindType`d slot then resolves to the
    /// supplied mock — and a request that reaches the route with no supplied doubles (no header, or no store
    /// entry) is an explicit 500.
    var scopeEntryPreamble: String {
        // Emitted for any variant witness (seed-scoped or seedless); the production witness has no preamble.
        guard let keyed = keyedScopeEntry else { return "" }
        let missingMessage =
            "WireMVC keyed test harness: no bound doubles for a request reaching this route under key "
            + "\(keyed.keyReference) — wrap the request in "
            + "withClient(supplying: \(subjectDoublesAliasName(subject: keyed.subject))(...))\\n"
        // `harnessIsActive` is the backstop behind the emission gating: this witness is only ever built for a
        // test consumer and registered by the keyed factory, so it cannot reach production — but if that ever
        // regressed, doubles must not resolve off an attacker-suppliable header. Requiring a live
        // `runSuite` makes the regression fail closed (an explicit 500) instead of silently mocking a
        // production dependency. See `WireMVCTesting/TestVariantHarness.swift`.
        return """
            guard
            WireMVCTesting.harnessIsActive,
            let wireMVCCorrelationID = wireMVCTestCorrelationID(in: request),
            let wireMVCDoubles = \(keyed.harnessEnumName).\(keyed.doublesStoreName).value(for: wireMVCCorrelationID)
            else {
            try await WireMVCOutcome.body([UInt8]("\(missingMessage)".utf8), .internalServerError).send(on: responseSender)
            return
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
        // Controller-scope `@ResponseHeader` constants cover every route; a route naming the same field wins.
        let controllerResponseHeaders = responseHeaderEntries(from: controller.attributes, scopeLabel: "controller")
        controllerCoding = codingKey(from: controller.attributes)?.reference
        var blocks: [String] = []
        for function in controller.functions {
            guard let verb = verb(from: function.attributes) else { continue }  // no verb → helper, skip
            // An override naming the binding the controller already selected resolves to the same value,
            // so it changes nothing. Diagnosed rather than ignored: the author asked for different settings
            // on this route and would otherwise get the enclosing scope's silently. `WireMVCCoding.self` is
            // the form that invites it — there is only one spelling of the unkeyed binding.
            //
            // Route-versus-controller only. A controller repeating the *app* tier is the same mistake but
            // is not visible here: the app's coding is a witness parameter the composition root passes in,
            // so this codegen never sees which binding it came from.
            let route = codingKey(from: function.attributes)
            if let route, route.reference == controllerCoding {
                diagnostics.append(
                    RouteCodegenDiagnostic(
                        .redundantCodingOverride(route.reference, scope: "route"),
                        at: route.node
                    )
                )
            }
            routeCoding = route?.reference
            if let block = routeBlock(
                function: function,
                verb: verb,
                prefix: pathPrefix,
                controllerMiddleware: controllerMiddleware,
                controllerErrorMappings: controllerErrorMappings,
                controllerResponseHeaders: controllerResponseHeaders
            ) {
                blocks.append(block)
            }
        }
        return blocks.joined(separator: "\n")
    }

    /// A route's response mode: its resolved constant header fields, and the mode its annotation declares.
    /// `nil` when the route states its mode more than once, which is diagnosed here.
    ///
    /// Split out of `routeBlock` for length, along the seam the rest of this file already follows — the
    /// response half is its own concern (see `ResponseCodegen.swift`).
    private mutating func responseMode(
        of function: FunctionDeclSyntax,
        controllerResponseHeaders: [ResponseHeaderEntry]
    ) -> (staticHeaders: [ResponseHeaderEntry], mode: ResolvedResponseMode?)? {
        // Tier order is application order: controller entries first, the route's after, so the route's
        // `.set` replaces and its `.append` adds. Nothing is filtered out here.
        let staticHeaders =
            controllerResponseHeaders + responseHeaderEntries(from: function.attributes, scopeLabel: "route")
        // A route states its response mode exactly once. Two annotations is a contradiction, and silently
        // honouring the first (which is what the response chain would do) is a worse way to find that out.
        let annotations = responseAnnotationNames(on: function.attributes)
        if annotations.count > 1 {
            record(
                RouteCodegenDiagnostic(
                    .multipleResponseAnnotations(
                        function.name.text,
                        annotations: annotations.map { "@\($0)" }.joined(separator: ", ")
                    ),
                    at: function.name
                )
            )
            return nil
        }
        // The mode is whatever its declaration says it is. A route with no annotation at all resolves to
        // `nil` here and is diagnosed further down, where the return shape is known — a bodiless response
        // tuple states its mode in the signature and legitimately carries no annotation.
        let mode = annotations.first.flatMap { name in
            discoveredModes[name].map { ResolvedResponseMode(name: name, declared: $0) }
        }
        // No content-type seeding here. The producer supplies its own (`WireMVCBodyProducer.contentType`),
        // which is where a codec's content type belongs — the codegen naming `text/html` was a special case
        // that only existed because the producer had nowhere to put it, and it could never have served a
        // response mode WireMVC does not know by name.
        return (staticHeaders, mode)
    }

    /// Which terminal a route needs, and the statements that feed it: the buffered assignment a `.buffered`
    /// or `.bodiless` mode emits, or the outcome expression a `.streaming` mode's `building` closure ends in.
    /// `nil` when the route was diagnosed.
    ///
    /// The choice is the mode's `terminal`, read off its declaration — not a test for the two annotation
    /// names this generator used to know.
    private mutating func responseEmission(
        of function: FunctionDeclSyntax,
        call: String,
        staticHeaders: [ResponseHeaderEntry],
        drainsMiddleware: Bool,
        mode: ResolvedResponseMode?
    ) -> ResponseEmission? {
        if mode?.terminal == .streaming {
            return streamingOutcome(
                from: function,
                call: call,
                staticHeaders: staticHeaders,
                drainsMiddleware: drainsMiddleware,
                mode: mode
            )
            .map(ResponseEmission.streaming)
        }
        return responseComputation(
            from: function,
            call: call,
            staticHeaders: staticHeaders,
            drainsMiddleware: drainsMiddleware,
            mode: mode
        )
        .map(ResponseEmission.buffered)
    }

    private mutating func routeBlock(
        function: FunctionDeclSyntax,
        verb: Verb,
        prefix: String,
        controllerMiddleware: [String],
        controllerErrorMappings: [ErrorMapping],
        controllerResponseHeaders: [ResponseHeaderEntry]
    ) -> String? {
        let path = joinPath(prefix, verb.path ?? "")
        // Caught here rather than left to the router's startup precondition: the template is a literal in
        // the source, so this is knowable at build time.
        guard !recordWildcardSegment(in: path, at: function.name) else { return nil }
        let middleware = controllerMiddleware + middlewareConstructions(from: function.attributes)
        if hasRawRoute(function) {
            // A raw handler writes its own response, so it has no outcome for these to land in. Silently
            // ignoring them would look like they applied.
            let raw = responseHeaderEntries(from: function.attributes, scopeLabel: "route")
            if !raw.isEmpty || !controllerResponseHeaders.isEmpty {
                diagnostics.append(
                    RouteCodegenDiagnostic(.responseHeaderOnRawRoute(function.name.text), at: function.name)
                )
            }
            return rawRouteBlock(function: function, verb: verb, path: path, middleware: middleware)
        }
        // Tier order is application order: controller entries first, the route's after, so the route's
        // `.set` replaces and its `.append` adds. Nothing is filtered out here.
        guard
            let (staticHeaders, mode) = responseMode(
                of: function,
                controllerResponseHeaders: controllerResponseHeaders
            )
        else { return nil }
        let hasBody = routeHasBody(function)
        guard let streamsBody = validatedBodyObligations(of: function, hasBody: hasBody, mode: mode) else {
            return nil
        }
        guard let (binds, callArgs) = parameterBindings(of: function, path: path, hasBody: hasBody)
        else { return nil }
        let hasBinds = !binds.isEmpty
        let call =
            "\(effectMarkers(of: function))\(subjectExpression).\(function.name.text)(\(callArgs.joined(separator: ", ")))"
        // Every typed route drains. The registry rides the courier context, so it exists whether or not
        // this route has a fold — and a global middleware must reach a route with no `@Middleware` of its
        // own, which is most of them. Making it conditional would miss those silently.
        let drainsMiddleware = true
        guard
            let emission = responseEmission(
                of: function,
                call: call,
                staticHeaders: staticHeaders,
                drainsMiddleware: drainsMiddleware,
                mode: mode
            )
        else { return nil }
        let errorMappings = tieredErrorMappings(of: function, controller: controllerErrorMappings)
        let names = registerClosureParameters(hasBinds: hasBinds, hasBody: hasBody, streamsBody: streamsBody)
        // When the fold threads doubles (a mock-consuming variant factory), the doubles correlation must bind
        // `wireMVCDoubles` *above* the fold — the fold's `create(doubles:)` reads it. So hoist the preamble to
        // the register-closure top and drop it from the terminal (which still enters scope off the hoisted
        // binding). Otherwise the preamble stays in the terminal, byte-for-byte unchanged.
        let foldThreadsDoubles = middleware.contains { $0.contains(Self.doublesCreateArgument) }
        let terminalBody = terminalBody(
            emission: emission,
            hasBody: hasBody,
            streamsBody: streamsBody,
            binds: binds,
            errorMappings: errorMappings,
            foldThreadsDoubles: foldThreadsDoubles
        )
        return emitRegister(
            verb: verb,
            path: path,
            middleware: middleware,
            hoistedPreamble: foldThreadsDoubles ? scopeEntryPreamble : "",
            requestName: names.request,
            // Only the fold-less path takes the registry off the register closure's context; through a fold
            // it comes off the final box, and the terminal has no use for the unwrapped context.
            contextName: middleware.isEmpty ? "requestContext" : "_",
            parametersName: names.pathParameters,
            readerName: names.reader,
            registryLocal: drainsMiddleware ? responseHeaderDrainLocal : nil,
            terminalBody: terminalBody
        )
    }

    /// The terminal the register closure ends in, in whichever of the two shapes the route's response
    /// half produced — the streaming one ends in an expression its `building` closure returns, the
    /// buffered one assigns `wireMVCOutcome`. Split out of `routeBlock` to keep it within the body-length
    /// budget; the choice is `emission`'s and nothing else here reads it.
    private func terminalBody(
        emission: ResponseEmission,
        hasBody: Bool,
        streamsBody: Bool,
        binds: [String],
        errorMappings: [ErrorMapping],
        foldThreadsDoubles: Bool
    ) -> String {
        // Hoisted above the fold when it threads doubles, so it is dropped from the terminal here.
        let preamble = foldThreadsDoubles ? "" : scopeEntryPreamble
        let hasBinds = !binds.isEmpty
        switch emission {
        case .streaming(let outcome):
            return streamingClosureBody(
                hasBinds: hasBinds,
                hasBody: hasBody,
                streamsBody: streamsBody,
                binds: binds,
                outcome: outcome,
                scopeEntryPreamble: preamble,
                scopeEntryPrologue: scopeEntryProloguePrefix,
                errorMappings: errorMappings
            )
        case .buffered(let response):
            return closureBody(
                hasBinds: hasBinds,
                hasBody: hasBody,
                binds: binds,
                response: response,
                scopeEntryPreamble: preamble,
                scopeEntryPrologue: scopeEntryProloguePrefix,
                errorMappings: errorMappings
            )
        }
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
            // A path binding's name must have a matching `{name}` in the route template — otherwise it can
            // only ever fail at runtime (`missingPathParameter`), so reject it at the seam. Keyed on the
            // `.path` obligation rather than the name `Path`, so a binding declared outside WireMVC gets the
            // same check: the obligation *is* "this one names a placeholder".
            // `{name*}` provides the placeholder `name` too — a catch-all binds its remainder under the
            // name without the marker, so a `@Path` naming it is satisfied.
            if namesPathPlaceholder(binding.wrapper),
                !path.contains("{\(bindingName)}"), !path.contains("{\(bindingName)*}")
            {
                diagnostics.append(
                    RouteCodegenDiagnostic(.pathPlaceholderMissing(name: bindingName, path: path), at: param)
                )
                return nil
            }
            let keyword = "let"
            binds.append(
                "\(keyword) \(internalName) = \(bindExpression(for: param, binding: binding, name: bindingName, hasBody: hasBody, function: function))"
            )
            callArgs.append(isWildcard ? internalName : "\(param.firstName.text): \(internalName)")
        }
        return (binds, callArgs)
    }

    /// The binding call for one parameter: `bindOptional` (→ `T?`) for an optional type,
    /// `bindOptional(...) ?? default` for a defaulted parameter, else the throwing `bind`. `body` is
    /// the collected request body (`requestBody`) for routes with a `@JSONBody`, else `nil`.
    private mutating func bindExpression(
        for param: FunctionParameterSyntax,
        binding: Binding,
        name: String,
        hasBody: Bool,
        function: FunctionDeclSyntax
    ) -> String {
        let type = param.type.trimmedDescription
        // A streaming binding is handed the reader rather than a collected body, and there is no optional
        // form: `bindOptional` exists because a *header* or *query* item may be absent, and a request body
        // reader is always present — an empty body is a stream that ends immediately, not a missing one.
        if let lent = lentStreamExpression(for: param, binding: binding, name: name, function: function) {
            return lent
        }
        if streamsRequestBody(binding.wrapper) {
            return "try await \(binding.wrapper)<\(type)>.bindReader("
                + "name: \"\(name)\", request: request, pathParameters: pathParameters, reader: reader, "
                + "coding: \(codingExpression))"
        }
        let bodyArgument = hasBody ? "requestBody" : "nil"
        let args =
            "name: \"\(name)\", request: request, pathParameters: pathParameters, body: \(bodyArgument), "
            + "coding: \(codingExpression)"
        if type.hasSuffix("?") {
            let underlying = String(type.dropLast())
            return "try await \(binding.wrapper)<\(underlying)>.bindOptional(\(args))"
        }
        if let defaultValue = param.defaultValue?.value.trimmedDescription {
            return "try await \(binding.wrapper)<\(type)>.bindOptional(\(args)) ?? \(defaultValue)"
        }
        return "try await \(binding.wrapper)<\(type)>.bind(\(args))"
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

    /// The `@ErrorResponse` tiers a route's terminal consults, innermost first: the route's own, then the
    /// controller's, then the Bootstrap's global default (M5.5 Phase 3). Order *is* the rule — the fold
    /// takes the first match — so this is one place rather than a concatenation repeated at each call.
    fileprivate mutating func tieredErrorMappings(
        of function: FunctionDeclSyntax,
        controller: [ErrorMapping]
    ) -> [ErrorMapping] {
        errorMappings(from: function.attributes, scopeLabel: "route") + controller + globalErrorMappings
    }

    /// Which of the register closure's parameters this route actually binds, and which are `_`.
    ///
    /// Each is `_` unless something in the terminal names it, because an unused closure parameter is a
    /// warning in generated code the consumer cannot silence.
    ///
    /// - `request`: any binding needs it, and so does a scoped controller (it is the scope-entry seed) and a
    ///   keyed variant witness (its preamble correlates per-request doubles off it). Without the last two, a
    ///   parameterless route on a seedless `@TestScopable` controller binds `_` and the preamble then
    ///   references a name that is not in scope.
    /// - `reader`: a route that collects its body *or* streams it. The two tiers differ in what happens to
    ///   the reader, not in whether it is named.
    fileprivate func registerClosureParameters(
        hasBinds: Bool,
        hasBody: Bool,
        streamsBody: Bool
    ) -> (request: String, pathParameters: String, reader: String) {
        (
            request: (hasBinds || scopedSeedType != nil || keyedScopeEntry != nil) ? "request" : "_",
            pathParameters: hasBinds ? "pathParameters" : "_",
            reader: (hasBody || streamsBody) ? "reader" : "_"
        )
    }

    fileprivate func routeHasBody(_ function: FunctionDeclSyntax) -> Bool {
        for param in function.signature.parameterClause.parameters {
            if let binding = binding(from: param.attributes), readsRequestBody(binding.wrapper) {
                return true
            }
        }
        return false
    }

}

// MARK: - Attribute reading

extension RouteBlockGenerator {
    // Read by the raw-route half in RawRouteCodegen.swift, so not fileprivate.
    struct Verb {
        let method: String  // e.g. ".get"
        let path: String?
    }

    // Read by the streaming half in RequestStreamingCodegen.swift, so not private.
    struct Binding {
        let wrapper: String  // e.g. "Path"
        let name: String?
    }

    fileprivate func verb(from attributes: AttributeListSyntax) -> Verb? {
        for case let .attribute(attr) in attributes {
            let name = attr.attributeName.trimmedDescription
            if let method = routeVerbMethod(for: name) {
                return Verb(method: method, path: routeFirstStringLiteral(attr.arguments))
            }
        }
        return nil
    }

    // Read by the streaming half in RequestStreamingCodegen.swift, so not private.
    func binding(from attributes: AttributeListSyntax) -> Binding? {
        for case let .attribute(attr) in attributes {
            let name = attr.attributeName.trimmedDescription
            if discoveredBindings[name] != nil {
                return Binding(wrapper: name, name: routeFirstStringLiteral(attr.arguments))
            }
        }
        return nil
    }

    /// The `@JSONResponse` status expression (verbatim), `.ok` if present without a status, or `nil`
    /// if there's no `@JSONResponse`.
    /// that appends or defers is exactly what a repeatable field wants, so it passes.
    /// The `@ResponseStatus(_)` status expression (verbatim), or `nil` if absent.
    /// Join a controller prefix and a verb subpath into one `{name}`-template path.
    private func joinPath(_ prefix: String, _ sub: String) -> String {
        routeJoinPath(prefix, sub)
    }
}

extension RouteBlockGenerator {
    /// Whether a binding reads the request body — the `@RequestBinding(.body)` obligation.
    ///
    /// One rule, and one source of truth. WireMVC's own `@JSONBody` states `.body` on its declaration like
    /// any other binding, and the scan reads it from there — nothing restates it.
    func readsRequestBody(_ wrapper: String) -> Bool {
        discoveredBindings[wrapper]?.contains(.body) ?? false
    }

    /// Whether a binding names a `{name}` path placeholder — the `@RequestBinding(.path)` obligation.
    func namesPathPlaceholder(_ wrapper: String) -> Bool {
        discoveredBindings[wrapper]?.contains(.path) ?? false
    }

}

/// The labels a route's **response tuple** return may carry, in canonical order. A handler returns either
/// its body alone or a labelled tuple naming what it wants to say about the response alongside it:
/// `-> (status: HTTPResponse.Status, headers: HTTPFields, body: Document)`, or any suffix-subset of that
/// ending in `body`.
///
/// Keyed on **labels**, not element type spellings.

// MARK: - Error response codegen (`@ErrorResponse`)

/// How an `@ErrorResponse` entry produces the outcome — a bare status (the `(E.self, .status)` form) or a
/// callable applied to the bound error (an inline `{ (e: E) in … }` closure). File-scope to keep the
/// generator's nested types one level deep.
private enum ErrorResponder {
    case status(String)  // a status expression, e.g. ".notFound"
    case call(String)  // a callable expression: "({ (e: T) in … })"
    case statusWithBody(status: String, call: String)  // `(E.self, .status, { e in body })`
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
    var isThrowing: Bool {
        switch responder {
        case .call, .statusWithBody: return true  // the closure, and encoding its value, can both throw
        case .status: return false
        }
    }
}

extension RouteBlockGenerator {
    /// The `@Coding(T.self)` source named at one scope, if any.
    func codingKey(from attributes: AttributeListSyntax) -> (reference: String, node: ExprSyntax)? {
        for case let .attribute(attr) in attributes where attr.attributeName.trimmedDescription == "Coding" {
            guard let arguments = attr.arguments?.as(LabeledExprListSyntax.self), let first = arguments.first
            else { continue }
            return (first.expression.trimmedDescription, first.expression)
        }
        return nil
    }

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
        // Form (2): `(E.self, .status, { e in body })`. Checked before form (1), which would otherwise
        // match on argument count and silently drop the closure.
        if arguments.count == 3, let status = arguments.dropFirst().first,
            let last = arguments.dropFirst(2).first
        {
            let typeExpr = first.expression.trimmedDescription
            guard typeExpr.hasSuffix(".self"), let closure = last.expression.as(ClosureExprSyntax.self) else {
                diagnostics.append(RouteCodegenDiagnostic(.errorResponseUnresolvedMapping(typeExpr), at: attr))
                return nil
            }
            let errorType = String(typeExpr.dropLast(".self".count))
            return ErrorMapping(
                errorType: errorType,
                isCatchAll: isCatchAllErrorType(errorType),
                responder: .statusWithBody(
                    status: status.expression.trimmedDescription,
                    call: "(\(closure.trimmedDescription))"
                )
            )
        }
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

        return "wireMVCOutcome = \(errorChainExpression(mappings: mappings, elements: elements))"
    }

    /// The consultation chain as a bare expression. The buffered terminal assigns it; the streaming
    /// terminal returns it from `errorMapping`. Same chain, same order, two callers.
    func errorChainExpression(mappings: [ErrorMapping], includeBindingBuiltin: Bool) -> String {
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
        return errorChainExpression(mappings: mappings, elements: elements)
    }

    private func errorChainExpression(mappings: [ErrorMapping], elements: [String]) -> String {
        let tryPrefix = mappings.contains(where: \.isThrowing) ? "try " : ""
        if elements.count == 1 {
            return "\(tryPrefix)\(elements[0])"
        }
        let chain = elements.joined(separator: "\n?? ")
        return "\(tryPrefix)(\n\(chain)\n)"
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
        case .statusWithBody(let status, let callable):
            return terminal
                ? "wireMVCRespondAny(to: wireMVCError, status: \(status), \(callable))"
                : "wireMVCRespond(to: wireMVCError, as: \(mapping.errorType).self, status: \(status), \(callable))"
        }
    }
}

/// What a route's response half produced — the two terminal shapes, kept apart because the streaming one
/// ends in an expression the `building` closure returns while the buffered one assigns `wireMVCOutcome`.
enum ResponseEmission {
    case buffered(String)
    case streaming(String)
}
