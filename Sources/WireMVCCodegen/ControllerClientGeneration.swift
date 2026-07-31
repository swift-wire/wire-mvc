import SwiftParser
import SwiftSyntax

// The per-controller typed test client. For each `@Controller` in a **test** consumer, this emits a
// `struct <Name>Client` with one method per typed route — parameters taken from the route's
// `@Path`/`@Query`/`@Header`/`@JSONBody` bindings, return taken from its `@JSONResponse` type.
//
// The client is handed to the body of that controller's `withBindValues` rather than reached through a
// module-scope variable, so the doubles a test supplies and the routes it can call arrive together and name
// the same controller. See `KeyedHarnessGeneration`.
//
// Everything here is derived from the same declarations the witness is, so a test driving a route through
// its generated method is checked against the route: renaming it, changing a `@Path`'s type, or altering the
// response body becomes a compile error instead of a runtime surprise. The methods return the decoded value
// and throw `WireMVCRouteError` on a non-2xx (see `WireMVCTesting/TypedRouteClient.swift`), so the happy
// path carries no status assertion and no decode.
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
    /// The `@JSONResponse` body type, `nil` for a `@ResponseStatus` (Void) route or a raw one.
    let responseType: String?
    /// A `@RawRoute`: the shim returns `TestResponse` and applies no status rule.
    let isRaw: Bool
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

        /// This controller's routes over the running suite's transport. A **keyed** suite receives the client
        /// as its `withBindValues` body argument instead, so the doubles and the routes arrive together; this
        /// is how a keyless suite — which has no such block — reaches the same typed surface.
        static var current: Self { Self(client: .current) }

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
    let signature = signatureParts.joined(separator: ", ")
    let generics = route.isRaw ? "<WireMVCRawReturn: ~Copyable>" : ""
    let returns = route.isRaw ? " -> WireMVCRawReturn" : route.responseType.map { " -> \($0)" } ?? ""

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
    } else if let headers {
        arguments.append("headers: \(headers)")
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
                isRaw: true
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
        let returnType = function.signature.returnClause?.type.trimmedDescription
        let returnsValue = returnType != nil && returnType != "Void" && returnType != "()"
        if hasAttribute("JSONResponse", on: function.attributes) {
            guard returnsValue else { return nil }
        } else if hasAttribute("ResponseStatus", on: function.attributes) {
            guard !returnsValue else { return nil }
        } else {
            return nil
        }

        return ClientRoute(
            functionName: function.name.text,
            wireMethod: verb.method,
            pathTemplate: pathTemplate,
            parameters: parameters,
            responseType: returnsValue ? returnType : nil,
            isRaw: false
        )
    }
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
