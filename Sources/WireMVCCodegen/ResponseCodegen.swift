import SwiftSyntax

// The response half of the route codegen: what a route says about its status and header fields, and how
// the two contributors — `@ResponseHeader` constants and the handler's labelled response tuple — resolve
// into the one `headerFields:` argument the terminal passes to `WireMVCOutcome`.
//
// Split out of `RouteCodegen.swift` along the seam that file already documents ("the generator's methods
// are split across extensions, per concern"): the request half (verbs, path templates, parameter binding,
// the middleware fold) and this half share only the generator's diagnostics array.

extension RouteBlockGenerator {
    mutating func responseComputation(
        from function: FunctionDeclSyntax,
        call: String,
        staticHeaders: [ResponseHeaderEntry]
    ) -> String? {
        let attributes = function.attributes
        let route = function.name.text
        guard let shape = responseReturnShape(of: function, route: route) else { return nil }
        let staticsLiteral = staticHeaders.isEmpty ? nil : responseHeaderLiteral(staticHeaders)

        if let annotatedStatus = jsonResponseStatus(from: attributes) {
            guard shape.hasBody else {
                record(RouteCodegenDiagnostic(.jsonResponseOnVoid(route), at: function.name))
                return nil
            }
            // The untouched path: no statics, no tuple — the exact string this emitted before.
            guard shape.isTuple || staticsLiteral != nil else {
                return "wireMVCOutcome = try WireMVCResponse.json(\(call), status: \(annotatedStatus), "
                    + "coding: \(codingExpression))"
            }
            guard shape.isTuple else {
                return "wireMVCOutcome = try WireMVCResponse.json(\(call), status: \(annotatedStatus), "
                    + "headerFields: \(headerExpression(shape: shape, statics: staticsLiteral)), "
                    + "coding: \(codingExpression))"
            }
            let value = shape.hasStatus ? "\(returnLocal).\(responseTupleStatusLabel)" : annotatedStatus
            return """
                let \(returnLocal) = \(call)
                wireMVCOutcome = try WireMVCResponse.json(\(returnLocal).\(responseTupleBodyLabel), \
                status: \(value), headerFields: \(headerExpression(shape: shape, statics: staticsLiteral)), \
                coding: \(codingExpression))
                """
        }

        if let annotatedStatus = responseStatus(from: attributes) {
            guard !shape.hasBody else {
                record(RouteCodegenDiagnostic(.responseStatusOnValue(route), at: function.name))
                return nil
            }
            guard shape.isTuple else {
                let fields =
                    staticsLiteral.map { _ in
                        ", headerFields: \(headerExpression(shape: shape, statics: staticsLiteral))"
                    } ?? ""
                return "\(call)\nwireMVCOutcome = .status(\(annotatedStatus)\(fields))"
            }
            let value = shape.hasStatus ? "\(returnLocal).\(responseTupleStatusLabel)" : annotatedStatus
            return """
                let \(returnLocal) = \(call)
                wireMVCOutcome = .status(\(value), \
                headerFields: \(headerExpression(shape: shape, statics: staticsLiteral)))
                """
        }

        record(RouteCodegenDiagnostic(.missingResponseAnnotation(route), at: function.name))
        return nil
    }

    /// The `headerFields:` argument — one `WireMVCResponseHeaders.resolved` call over whichever
    /// contributors this route actually has. Both arguments default, so a route with only one names only
    /// that one.
    private func headerExpression(shape: ResponseReturnShape, statics: String?) -> String {
        let returned = shape.hasHeaders ? "\(returnLocal).\(responseTupleHeadersLabel)" : nil
        let arguments = [statics.map { "statics: \($0)" }, returned.map { "returned: \($0)" }].compactMap { $0 }
        guard !arguments.isEmpty else { return "[:]" }
        return "WireMVCResponseHeaders.resolved(\(arguments.joined(separator: ", ")))"
    }

    /// The `[ResponseHeaderContribution]` literal for a route's `@ResponseHeader` constants, in tier order
    /// (controller entries first). No codegen-time deduplication: applying them in order *is* the tier
    /// rule, so a route's `.set` naturally replaces the controller's and a route's `.append` naturally adds
    /// to it.
    private func responseHeaderLiteral(_ entries: [ResponseHeaderEntry]) -> String {
        "[" + entries.map(\.contributionLiteral).joined(separator: ", ") + "]"
    }

    /// What a handler's return clause says about the response — whether it carries a body, and whether it
    /// is a labelled response tuple naming a status and/or header fields alongside it.
    struct ResponseReturnShape {
        let isTuple: Bool
        let hasStatus: Bool
        let hasHeaders: Bool
        let hasBody: Bool

        static let void = ResponseReturnShape(isTuple: false, hasStatus: false, hasHeaders: false, hasBody: false)
        static let body = ResponseReturnShape(isTuple: false, hasStatus: false, hasHeaders: false, hasBody: true)
    }

    /// Read the return clause. No clause, or `Void`/`()`, is Void; a tuple whose labels are drawn from
    /// `status`/`headers`/`body` is a response tuple; anything else is a plain body.
    ///
    /// A tuple is only *read* as a response tuple when it uses one of those labels — an ordinary unlabelled
    /// tuple stays a body, so nothing about existing routes changes. Once it does use one, the whole label
    /// list must be a legal form, because a near-miss (`(status:, header:)`) is far more likely a typo than
    /// an intentional payload, and silently encoding it as a JSON body would be a confusing way to find out.
    private mutating func responseReturnShape(
        of function: FunctionDeclSyntax,
        route: String
    ) -> ResponseReturnShape? {
        guard let returnType = function.signature.returnClause?.type else { return .void }
        let text = returnType.trimmedDescription
        if text == "Void" || text == "()" { return .void }
        guard let tuple = returnType.as(TupleTypeSyntax.self) else { return .body }

        let labels = tuple.elements.map { $0.firstName?.text ?? "" }
        let known = [responseTupleStatusLabel, responseTupleHeadersLabel, responseTupleBodyLabel]
        guard labels.contains(where: known.contains) else { return .body }

        // The legal forms. `(body:)` alone is absent because a one-element labelled tuple is not a tuple
        // type in Swift — it collapses to the element, which is the plain-body case.
        let legal: [[String]] = [
            [responseTupleHeadersLabel, responseTupleBodyLabel],
            [responseTupleStatusLabel, responseTupleBodyLabel],
            [responseTupleStatusLabel, responseTupleHeadersLabel, responseTupleBodyLabel],
            [responseTupleStatusLabel, responseTupleHeadersLabel],
        ]
        guard legal.contains(labels) else {
            record(
                RouteCodegenDiagnostic(
                    .responseTupleInvalidLabels(
                        route,
                        labels: labels.map { $0.isEmpty ? "_" : $0 }.joined(separator: ", ")
                    ),
                    at: returnType
                )
            )
            return nil
        }
        return ResponseReturnShape(
            isTuple: true,
            hasStatus: labels.contains(responseTupleStatusLabel),
            hasHeaders: labels.contains(responseTupleHeadersLabel),
            hasBody: labels.contains(responseTupleBodyLabel)
        )
    }

    private func jsonResponseStatus(from attributes: AttributeListSyntax) -> String? {
        for case let .attribute(attr) in attributes where attr.attributeName.trimmedDescription == "JSONResponse" {
            guard case let .argumentList(list) = attr.arguments else { return ".ok" }
            let statusArg = list.first { $0.label?.text == "status" }
            return statusArg?.expression.trimmedDescription ?? ".ok"
        }
        return nil
    }

    /// The `@ResponseHeader(name, value[, verb])` constants written at one scope, in source order.
    ///
    /// Two entries for one field are only diagnosed when **both** are `set`, because that is the case with
    /// no answer — they land in one ordered list and neither can be said to have been meant. A second entry

    mutating func responseHeaderEntries(
        from attributes: AttributeListSyntax,
        scopeLabel: String
    ) -> [ResponseHeaderEntry] {
        var entries: [ResponseHeaderEntry] = []
        var setFields: Set<String> = []
        for case let .attribute(attr) in attributes
        where attr.attributeName.trimmedDescription == "ResponseHeader" {
            guard case let .argumentList(list) = attr.arguments, (2...3).contains(list.count) else { continue }
            let arguments = Array(list)
            let name = arguments[0].expression.trimmedDescription
            let value = arguments[1].expression.trimmedDescription
            // `.append` / `ResponseHeaderVerb.append` / a typealias — take the case name, which is all the
            // emitted contribution needs.
            let verb =
                arguments.count == 3
                ? String(arguments[2].expression.trimmedDescription.split(separator: ".").last ?? "set")
                : "set"
            if verb == "set", !setFields.insert(name).inserted {
                record(
                    RouteCodegenDiagnostic(.responseHeaderDuplicateField(field: name, scope: scopeLabel), at: attr)
                )
                continue
            }
            entries.append(ResponseHeaderEntry(name: name, value: value, verb: verb))
        }
        return entries
    }

    private func responseStatus(from attributes: AttributeListSyntax) -> String? {
        for case let .attribute(attr) in attributes where attr.attributeName.trimmedDescription == "ResponseStatus" {
            guard case let .argumentList(list) = attr.arguments, let first = list.first else { continue }
            return first.expression.trimmedDescription
        }
        return nil
    }
}

/// The labels a route's **response tuple** return may carry, in canonical order: a handler returns
/// either its body alone or a labelled tuple naming what it wants to say about the response alongside
/// it — `-> (status: HTTPResponse.Status, headers: HTTPFields, body: Document)`, or a subset.
///
/// Keyed on **labels**, not element type spellings. A syntactic macro can only compare type text, so
/// matching on `HTTPFields` would misread a body type that happens to be spelled that way, and would
/// inherit the type-spelling fragility the raw-route record already flags as a residual. Labels are
/// unambiguous, self-documenting at the return site, and let the elements stay the plain re-exported
/// `HTTPResponse.Status` / `HTTPFields` rather than needing wrapper types.
let responseTupleStatusLabel = "status"
let responseTupleHeadersLabel = "headers"
let responseTupleBodyLabel = "body"

/// The terminal's local holding a response-tuple return, so its elements can be projected more than once.
/// `wireMVC`-prefixed like every other generated local, so it can't collide with a decoded parameter.
let returnLocal = "wireMVCReturn"

/// One `@ResponseHeader(name, value[, verb])` constant. All three are kept as the **written text**, since
/// the codegen emits them verbatim into a `ResponseHeaderContribution` literal and never interprets them.
/// `verb` is the case name alone (`"append"`), so the emitted contribution is `.append(name, value)` —
/// `ResponseHeaderVerb` and `ResponseHeaderContribution` share case names precisely so this is a
/// pass-through rather than a mapping table.
struct ResponseHeaderEntry {
    let name: String
    let value: String
    let verb: String

    var contributionLiteral: String { ".\(verb)(\(name), \(value))" }
}
