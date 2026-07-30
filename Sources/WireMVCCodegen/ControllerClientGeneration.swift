import SwiftParser
import SwiftSyntax

// The per-controller typed test client. For each `@Controller` in a **test** consumer, this emits a
// `struct <Name>Client` with one method per typed route — parameters taken from the route's
// `@Path`/`@Query`/`@Header`/`@JSONBody` bindings, return taken from its `@JSONResponse` type — plus a
// module-scope `var <name>: <Name>Client` the suite reads, mirroring the generated free `withBindValues`.
//
// Everything here is derived from the same declarations the witness is, so a test driving a route through
// its generated method is checked against the route: renaming it, changing a `@Path`'s type, or altering the
// response body becomes a compile error instead of a runtime surprise. The methods return the decoded value
// and throw `WireMVCRouteError` on a non-2xx (see `WireMVCTesting/TypedRouteClient.swift`), so the happy
// path carries no status assertion and no decode.
//
// A route with no derivable shape emits no method and no diagnostic: `@RawRoute` (streaming, SSE) owns its
// own wire format, and `@NotFound` is not addressable by path. Those stay on `TestClient`'s untyped verbs,
// which remain the escape hatch for anything a test wants to malform deliberately.

/// One typed route's client-facing shape, read off the handler declaration.
struct ClientRoute {
    /// The handler's name — the generated method's name, so the client reads like the controller.
    let functionName: String
    /// The wire method: `"GET"`.
    let wireMethod: String
    /// The full `{name}`-template path, controller prefix included.
    let pathTemplate: String
    let parameters: [ClientRouteParameter]
    /// The `@JSONResponse` body type, or `nil` for a `@ResponseStatus` (Void) route.
    let responseType: String?
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

/// The module-scope accessor a suite reads — `notesController` for `NotesController`. Lower-camelled like
/// the graph's binding properties, and a free variable like the generated `withBindValues`, so a test
/// writes `try await notesController.fetch(id: "x")`.
func controllerClientAccessorName(_ controller: String) -> String { lowerCamelFirst(controller) }

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

        /// `\(controller.name)`'s routes, over the running suite's transport.
        var \(controllerClientAccessorName(controller.name)): \(typeName) {
            \(typeName)(client: .current)
        }
        """
    return Parser.parse(source: raw).formatted().description
}

/// One route's method: the bindings become parameters, the response type becomes the return, and the body
/// is a single `routeResponse` call plus a decode.
private func renderClientMethod(_ route: ClientRoute) -> String {
    let signature = route.parameters.map { "\($0.name): \($0.type)" }.joined(separator: ", ")
    let returns = route.responseType.map { " -> \($0)" } ?? ""

    // `@Path`/`@Query`/`@Header` values are converted with `String(_:)`, the exact inverse of the
    // `LosslessStringConvertible` parse the route's binding does — so what the test passes is what the
    // handler receives. An optional binding contributes nothing when it is `nil`.
    let pathParameters = wireEntries(route.parameters.filter { $0.wrapper == "Path" })
    let queryItems = queryEntries(route.parameters.filter { $0.wrapper == "Query" })
    let headers = wireEntries(route.parameters.filter { $0.wrapper == "Header" })

    var arguments = ["method: \"\(route.wireMethod)\"", "path: \"\(route.pathTemplate)\""]
    if let pathParameters { arguments.append("pathParameters: \(pathParameters)") }
    if let queryItems { arguments.append("query: \(queryItems)") }
    if let headers { arguments.append("headers: \(headers)") }
    if let body = route.parameters.first(where: { $0.wrapper == "JSONBody" }) {
        arguments.append("json: \(body.name)")
    }

    let call = "try await client.routeResponse(\(arguments.joined(separator: ", ")))"
    let body: String
    if let responseType = route.responseType {
        body = """
            let wireMVCResponse = \(call)
            return try wireMVCResponse.json(\(responseType).self)
            """
    } else {
        // A `@ResponseStatus` route has no body to decode; `routeResponse` has already thrown for a non-2xx.
        body = "_ = \(call)"
    }

    return """
        /// `\(route.wireMethod) \(route.pathTemplate)`
        func \(route.functionName)(\(signature)) async throws\(returns) {
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
        guard !hasAttribute("RawRoute", on: function.attributes) else { return nil }

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
            pathTemplate: routeJoinPath(pathPrefix, verb.path ?? ""),
            parameters: parameters,
            responseType: returnsValue ? returnType : nil
        )
    }
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
