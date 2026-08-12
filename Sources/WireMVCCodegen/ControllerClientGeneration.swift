import SwiftParser
import SwiftSyntax

// The per-controller typed test client. For each `@Controller` in a **test** consumer, this emits a
// `struct <Name>Client` with one method per typed route — parameters taken from the route's
// `@Path`/`@Query`/`@Header`/`@JSONBody` bindings, return taken from its `@JSONResponse` type.
//
// The client is handed to the body of that controller's `withClient` rather than reached through a
// module-scope variable, so the doubles a test supplies and the routes it can call arrive together and name
// the same controller. See `KeyedHarnessGeneration`.
//
// Everything here is derived from the same declarations the witness is, so a test driving a route through
// its generated method is checked against the route: renaming it, changing a `@Path`'s type, or altering the
// response body becomes a compile error instead of a runtime surprise. The methods return the decoded value
// and throw `WireMVCRouteError` on a non-2xx (see `WireMVCTesting/TypedRouteClient.swift`), so the happy
// path carries no status assertion and no decode.
//
// Every method also takes `headers:`, defaulted empty. A route can depend on a header it does not declare —
// read by a middleware or a scoped binding off the `HTTPRequest` rather than bound with `@Header` — and the
// typed surface would otherwise be unusable for it. A declared `@Header` binding wins over an extra of the
// same name.
//
// A `@RawRoute` gets a **shim** rather than a typed method. Its parameters are all *roles* (the request,
// reader and sender the server supplies), and it writes its own response — so there is nothing to type on
// either side. What is still derivable is the request line: the verb and the path template, including its
// `{placeholder}`s, which become `String` parameters. The shim returns the untyped ``TestResponse`` and does
// not treat a non-2xx as a failure, because a raw route may answer one by design. So a raw route stops being
// a stringly-typed path in the test even though its payload stays untyped.
//
// `@NotFound` still gets nothing: an unmatched path is not addressable as a route. That, and any request a
// test wants to malform deliberately, stays on `TestClient`'s untyped verbs.

/// One typed route's client-facing shape, read off the handler declaration.
struct ClientRoute {
    /// The handler's name — the generated method's name, so the client reads like the controller.
    let functionName: String
    /// The wire method: `"GET"`.
    let wireMethod: String
    /// The full `{name}`-template path, controller prefix included.
    let pathTemplate: String
    let parameters: [ClientRouteParameter]
    /// The `@JSONResponse` body type, `nil` for a `@ResponseStatus` (Void) route, an `@HTMLResponse` one,
    /// or a raw one.
    let responseType: String?
    /// A `@RawRoute`: the shim returns `TestResponse` and applies no status rule.
    let isRaw: Bool
    /// An `@HTMLResponse`: the method returns the rendered markup as a `String`.
    ///
    /// There is no type to decode into — the handler's return is `some HTML`, an opaque type the client
    /// could not name even if markup were decodable. What a test wants to assert on is the markup itself,
    /// so that is what the method hands back.
    let isHTML: Bool
}

/// One binding on a typed route, as the generated method exposes it.
struct ClientRouteParameter {
    /// The binding wrapper — `Path`, `Query`, `Header`, `JSONBody`.
    let wrapper: String
    /// The name on the wire: the attribute's literal (`@Path("id")`) or the parameter's own name.
    let wireName: String
    /// The parameter's name in the generated method — the handler's own, so the two read alike.
    let name: String
    /// The declared type, `?` included when optional.
    let type: String
    var isOptional: Bool { type.hasSuffix("?") }
}

/// The generated client type for a controller — `NotesControllerClient`.
func controllerClientTypeName(_ controller: String) -> String { controller + "Client" }

/// The typed client for one controller, or `nil` when it has no route with a derivable shape (every route
/// `@RawRoute`, or none annotated) — an empty client is noise, so nothing is emitted.
func renderControllerClient(controller: ControllerDeclaration, pathPrefix: String) -> String? {
    let routes = clientRoutes(of: controller, pathPrefix: pathPrefix)
    guard !routes.isEmpty else { return nil }

    let typeName = controllerClientTypeName(controller.name)
    let methods = routes.map(renderClientMethod).joined(separator: "\n\n")
    let raw = """
        /// Typed access to `\(controller.name)`'s routes, derived from its verb annotations. Each method
        /// returns the route's decoded response and throws `WireMVCRouteError` for a non-2xx.
        struct \(typeName) {
        let client: TestClient

        \(methods)
        }
        """
    return Parser.parse(source: raw).formatted().description
}

/// One route's method: the bindings become parameters, the response type becomes the return, and the body
/// is a single `routeResponse` call plus a decode.
private func renderClientMethod(_ route: ClientRoute) -> String {
    var signatureParts = route.parameters.map { "\($0.name): \($0.type)" }
    if route.isRaw {
        // A raw route declares no header or body binding to derive from, but a test may still need to send
        // them — without these the only way to reach the route would be the untyped client, losing the
        // derived path. Both the body and the response handler mirror the proposal's `HTTPClient.perform`,
        // so a route that reads or writes incrementally is expressible in the same shape the app's own
        // clients use.
        signatureParts.append("headers: [String: String] = [:]")
        signatureParts.append("body: consuming HTTPClientRequestBody<TestRequestWriter>? = nil")
        signatureParts.append(
            "responseHandler: (HTTPResponse, consuming TestResponseReader) async throws -> WireMVCRawReturn"
        )
    }
    if !route.isRaw {
        // Every method takes extra headers, matching the raw shim. A route can depend on a header it does not
        // *declare* — an auth token, tenant id or trace id read by a middleware or a scoped binding off the
        // `HTTPRequest` rather than bound with `@Header` — and without this a test for such a route would have
        // to abandon the typed method entirely, losing the derived path and decoded response along with it.
        signatureParts.append("headers: [String: String] = [:]")
    }
    let signature = signatureParts.joined(separator: ", ")
    let generics = route.isRaw ? "<WireMVCRawReturn: ~Copyable>" : ""
    let returns =
        if route.isRaw { " -> WireMVCRawReturn" } else if route.isHTML { " -> String" } else {
            route.responseType.map { " -> \($0)" } ?? ""
        }

    // `@Path`/`@Query`/`@Header` values are converted with `String(_:)`, the exact inverse of the
    // `LosslessStringConvertible` parse the route's binding does — so what the test passes is what the
    // handler receives. An optional binding contributes nothing when it is `nil`.
    let pathParameters = wireEntries(route.parameters.filter { $0.wrapper == "Path" })
    let queryItems = queryEntries(route.parameters.filter { $0.wrapper == "Query" })
    let headers = wireEntries(route.parameters.filter { $0.wrapper == "Header" })

    var arguments = ["method: \"\(route.wireMethod)\"", "path: \"\(route.pathTemplate)\""]
    if let pathParameters { arguments.append("pathParameters: \(pathParameters)") }
    if let queryItems { arguments.append("query: \(queryItems)") }
    if route.isRaw {
        arguments.append("headers: headers")
        arguments.append("body: body")
        arguments.append("responseHandler: responseHandler")
    } else {
        arguments.append("headers: \(headerArgument(route.parameters.filter { $0.wrapper == "Header" }))")
    }
    if let body = route.parameters.first(where: { $0.wrapper == "JSONBody" }) {
        arguments.append("json: \(body.name)")
    }

    let entryPoint = route.isRaw ? "performRawRoute" : "routeResponse"
    let call = "try await client.\(entryPoint)(\(arguments.joined(separator: ", ")))"
    let body: String
    if route.isRaw {
        // The raw route owns its response, so the shim forwards the handler's return untouched.
        body = "return \(call)"
    } else if route.isHTML {
        // Markup, not a decoded value — `routeResponse` has already thrown for a non-2xx.
        body = """
            let wireMVCResponse = \(call)
            return wireMVCResponse.bodyText
            """
    } else if let responseType = route.responseType {
        body = """
            let wireMVCResponse = \(call)
            return try wireMVCResponse.json(\(responseType).self)
            """
    } else {
        // A `@ResponseStatus` route has no body to decode; `routeResponse` has already thrown for a non-2xx.
        body = "_ = \(call)"
    }

    let note =
        route.isRaw
        ? " — `@RawRoute`: the response head and body reader are handed to `responseHandler`, and a non-2xx is not a failure"
        : ""
    return """
        /// `\(route.wireMethod) \(route.pathTemplate)`\(note)
        func \(route.functionName)\(generics)(\(signature)) async throws\(returns) {
        \(body)
        }
        """
}

/// A `[wire: String(value)]` dictionary literal for path or header bindings, or `nil` when there are none.
/// An optional binding is folded in only when non-`nil`, so omitting it omits the header rather than
/// sending `"nil"`.
/// The `headers:` argument for a typed method: the caller's `headers` merged under the route's own `@Header`
/// bindings, so a declared binding wins over an extra of the same name. Built as a chain from `headers`
/// rather than merging a separate literal into it, which keeps the optional case from nesting one merge
/// inside another.
private func headerArgument(_ parameters: [ClientRouteParameter]) -> String {
    let required = parameters.filter { !$0.isOptional }
    var expression = "headers"
    if !required.isEmpty {
        let literal = "[" + required.map { "\"\($0.wireName)\": String(\($0.name))" }.joined(separator: ", ") + "]"
        expression += ".merging(\(literal)) { _, declared in declared }"
    }
    for parameter in parameters where parameter.isOptional {
        expression +=
            ".merging(\(parameter.name).map { [\"\(parameter.wireName)\": String($0)] } ?? [:]) "
            + "{ _, declared in declared }"
    }
    return expression
}

private func wireEntries(_ parameters: [ClientRouteParameter]) -> String? {
    guard !parameters.isEmpty else { return nil }
    let required = parameters.filter { !$0.isOptional }
    let optional = parameters.filter(\.isOptional)
    let base =
        required.isEmpty
        ? "[:]"
        : "[" + required.map { "\"\($0.wireName)\": String(\($0.name))" }.joined(separator: ", ") + "]"
    guard !optional.isEmpty else { return base }
    let merges = optional.map {
        ".merging(\($0.name).map { [\"\($0.wireName)\": String($0)] } ?? [:]) { _, new in new }"
    }
    return base + merges.joined()
}

/// A `[(name:value:)]` array literal for query bindings, or `nil` when there are none. Order follows the
/// declaration, and an optional binding contributes an item only when non-`nil`.
private func queryEntries(_ parameters: [ClientRouteParameter]) -> String? {
    guard !parameters.isEmpty else { return nil }
    if parameters.allSatisfy({ !$0.isOptional }) {
        return "[" + parameters.map { "(name: \"\($0.wireName)\", value: String(\($0.name)))" }.joined(separator: ", ")
            + "]"
    }
    // Each entry is parenthesised: `??` binds looser than `+`, so an unparenthesised
    // `optional.map { … } ?? [] + [next]` would parse as `optional ?? ([] + [next])` and drop every
    // following item whenever the optional is present.
    let entries = parameters.map { parameter -> String in
        parameter.isOptional
            ? "(\(parameter.name).map { [(name: \"\(parameter.wireName)\", value: String($0))] } ?? [])"
            : "([(name: \"\(parameter.wireName)\", value: String(\(parameter.name)))])"
    }
    return entries.joined(separator: " + ")
}

/// Every route on a controller with a derivable client shape, in declaration order. A handler is skipped
/// when it carries no verb, is `@RawRoute`, or has a parameter with no binding wrapper — the witness
/// diagnoses those, so skipping here reports nothing twice.
func clientRoutes(of controller: ControllerDeclaration, pathPrefix: String) -> [ClientRoute] {
    controller.functions.compactMap { function in
        guard let verb = clientVerb(from: function.attributes) else { return nil }
        let pathTemplate = routeJoinPath(pathPrefix, verb.path ?? "")

        // A raw route declares roles, not bindings, so its parameters come from the path template instead.
        if hasAttribute("RawRoute", on: function.attributes) {
            return ClientRoute(
                functionName: function.name.text,
                wireMethod: verb.method,
                pathTemplate: pathTemplate,
                parameters: pathPlaceholderParameters(in: pathTemplate),
                responseType: nil,
                isRaw: true,
                isHTML: false
            )
        }

        var parameters: [ClientRouteParameter] = []
        for parameter in function.signature.parameterClause.parameters {
            guard let binding = clientBinding(from: parameter.attributes) else { return nil }
            let name = (parameter.secondName ?? parameter.firstName).text
            parameters.append(
                ClientRouteParameter(
                    wrapper: binding.wrapper,
                    wireName: binding.name ?? name,
                    name: name,
                    type: parameter.type.trimmedDescription
                )
            )
        }

        // Exactly one response annotation is required, and the witness diagnoses a mismatch; here the
        // annotation just picks whether the method returns a value.
        //
        // A **labelled response tuple** is projected down to its `body` element: what crosses the wire is
        // the encoded body, so that is what the client decodes. A tuple with no `body` (the bodiless
        // `(status:headers:)` redirect shape) has nothing to decode and reads as no value at all.
        let declaredReturn = function.signature.returnClause?.type
        let projection = responseTupleProjection(of: declaredReturn)
        let returnType = projection.isResponseTuple ? projection.body : declaredReturn?.trimmedDescription
        let returnsValue = returnType != nil && returnType != "Void" && returnType != "()"
        // A bodiless response tuple carries no annotation — its return type is the declaration — so it has
        // to be admitted here explicitly. Falling through to `return nil` would drop the route from the
        // client silently, which is the same failure the tuple projection was added to fix.
        let selfDescribing = projection.isResponseTuple && projection.body == nil
        // Every response mode must be admitted explicitly. Falling through to `return nil` drops the route
        // from the client *silently* — the failure the response-tuple projection was added to fix, and the
        // one `@HTMLResponse` reintroduced by being a fourth mode added to a three-way test.
        let isHTML = hasAttribute("HTMLResponse", on: function.attributes)
        if hasAttribute("JSONResponse", on: function.attributes) {
            guard returnsValue else { return nil }
        } else if isHTML {
            guard returnsValue else { return nil }
        } else if hasAttribute("ResponseStatus", on: function.attributes) {
            guard !returnsValue else { return nil }
        } else if !selfDescribing {
            return nil
        }

        return ClientRoute(
            functionName: function.name.text,
            wireMethod: verb.method,
            pathTemplate: pathTemplate,
            parameters: parameters,
            responseType: (returnsValue && !isHTML) ? returnType : nil,
            isRaw: false,
            isHTML: isHTML
        )
    }

}

/// Whether the return clause is a labelled response tuple and, if so, the type of its `body` element.
///
/// The two answers have to travel together. A `(status:headers:)` redirect *is* a response tuple with no
/// body, and only knowing both facts distinguishes it from a handler genuinely returning a tuple payload —
/// which is what decides whether the client method decodes a value, returns nothing, or (getting it wrong)
/// disappears entirely because a bodiless tuple looked like a returned value to `@ResponseStatus`.
///
/// Deliberately permissive where `RouteCodegen` is strict: it recognises the shape and leaves everything
/// else alone. The route codegen owns diagnosing a malformed response tuple; duplicating that judgement
/// here would mean two places to keep in agreement, over a declaration the witness has already rejected.
private func responseTupleProjection(of type: TypeSyntax?) -> (isResponseTuple: Bool, body: String?) {
    guard let tuple = type?.as(TupleTypeSyntax.self) else { return (false, nil) }
    let labels = tuple.elements.compactMap { $0.firstName?.text }
    let known = [responseTupleStatusLabel, responseTupleHeadersLabel, responseTupleBodyLabel]
    guard labels.contains(where: known.contains) else { return (false, nil) }
    let body = tuple.elements.first { $0.firstName?.text == responseTupleBodyLabel }?.type.trimmedDescription
    return (true, body)
}

/// A path placeholder's Swift parameter name — `user-id` becomes `userId`. Deliberately *not*
/// `sanitizeIdentifier`: that replicates WireGen's doubles-field rule, which drops separators without
/// camel-casing (`userid`) and exists to agree with another tool. This one only has to read well.
func placeholderParameterName(_ placeholder: String) -> String {
    let segments = placeholder.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
    guard let first = segments.first else { return placeholder }
    let head = first.first.map { $0.lowercased() + first.dropFirst() } ?? ""
    let tail = segments.dropFirst().map { segment in
        segment.first.map { $0.uppercased() + segment.dropFirst() } ?? ""
    }
    let name = head + tail.joined()
    // A placeholder starting with a digit can't be a parameter name.
    return name.first?.isNumber == true ? "_" + name : name
}

/// The `{placeholder}`s of a path template, in order, as `String` path parameters — how a raw route's shim
/// gets its arguments when the handler declares no bindings. A placeholder that isn't already a valid Swift
/// identifier is sanitised for the parameter name; the wire name stays as written.
func pathPlaceholderParameters(in template: String) -> [ClientRouteParameter] {
    var parameters: [ClientRouteParameter] = []
    var seen: Set<String> = []
    var remainder = Substring(template)
    while let open = remainder.firstIndex(of: "{"), let close = remainder[open...].firstIndex(of: "}") {
        let wireName = String(remainder[remainder.index(after: open)..<close])
        remainder = remainder[remainder.index(after: close)...]
        guard !wireName.isEmpty, seen.insert(wireName).inserted else { continue }
        parameters.append(
            ClientRouteParameter(
                wrapper: "Path",
                wireName: wireName,
                name: placeholderParameterName(wireName),
                type: "String"
            )
        )
    }
    return parameters
}

private func clientVerb(from attributes: AttributeListSyntax) -> (method: String, path: String?)? {
    for case let .attribute(attribute) in attributes {
        if let method = routeWireMethod(for: attribute.attributeName.trimmedDescription) {
            return (method, routeFirstStringLiteral(attribute.arguments))
        }
    }
    return nil
}

private func clientBinding(from attributes: AttributeListSyntax) -> (wrapper: String, name: String?)? {
    for case let .attribute(attribute) in attributes {
        let wrapper = attribute.attributeName.trimmedDescription
        if routeBindingWrappers.contains(wrapper) {
            return (wrapper, routeFirstStringLiteral(attribute.arguments))
        }
    }
    return nil
}

private func hasAttribute(_ name: String, on attributes: AttributeListSyntax) -> Bool {
    attributes.contains { element in
        if case let .attribute(attribute) = element {
            return attribute.attributeName.trimmedDescription == name
        }
        return false
    }
}
