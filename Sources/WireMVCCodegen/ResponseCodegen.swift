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
        staticHeaders: [ResponseHeaderEntry],
        drainsMiddleware: Bool,
        mode: ResolvedResponseMode?
    ) -> String? {
        let attributes = function.attributes
        let route = function.name.text
        guard let shape = responseReturnShape(of: function, route: route) else { return nil }
        let staticsLiteral = self.staticsLiteral(staticHeaders)

        // A **bodiless response tuple** states its own response mode: no `body` label means no body, and
        // `status:` means the status is computed. Both facts are in the signature, more explicitly than an
        // attribute could put them — so this shape takes no response annotation, and one written anyway
        // would be a declaration carrying no information.
        //
        // The rule the design record states ("exactly one response annotation") is kept in substance:
        // every route states its response mode exactly once, in an annotation *or* in a return type that
        // says it unambiguously. A `Void` handler with no annotation stays a diagnostic, because there the
        // status genuinely is unstated — which is the silent-default the rule was written against.
        if shape.isTuple, !shape.hasBody {
            if let annotation = responseAnnotationName(on: attributes) {
                record(
                    RouteCodegenDiagnostic(
                        .responseAnnotationOnSelfDescribingReturn(route, annotation: annotation),
                        at: function.name
                    )
                )
                return nil
            }
            return """
                let \(returnLocal) = \(call)
                wireMVCOutcome = .status(\(returnLocal).\(responseTupleStatusLabel), \
                headerFields: \(headerExpression(shape: shape, statics: staticsLiteral, drainsMiddleware: drainsMiddleware)))
                """
        }

        if let mode, mode.terminal == .buffered {
            return bufferedOutcome(
                from: function,
                call: call,
                shape: shape,
                staticsLiteral: staticsLiteral,
                drainsMiddleware: drainsMiddleware,
                mode: mode
            )
        }

        // A `.bodiless` mode — `@ResponseStatus`. Only `Void` reaches here: a body-carrying tuple is rejected
        // below, and the bodiless one returned above.
        if let mode, mode.terminal == .bodiless {
            guard let annotatedStatus = bodilessStatus(from: attributes, annotation: mode.name) else {
                record(
                    RouteCodegenDiagnostic(
                        .bodilessModeNeedsStatus(route, annotation: mode.name),
                        at: function.name
                    )
                )
                return nil
            }
            guard !shape.hasBody else {
                record(RouteCodegenDiagnostic(.responseStatusOnValue(route), at: function.name))
                return nil
            }
            let fields =
                (staticsLiteral != nil || drainsMiddleware)
                ? ", headerFields: \(headerExpression(shape: shape, statics: staticsLiteral, drainsMiddleware: drainsMiddleware))"
                : ""
            return "\(call)\nwireMVCOutcome = .status(\(annotatedStatus)\(fields))"
        }

        // Only `.streaming` can reach here, and it never does — `responseEmission` routes it to
        // `streamingOutcome` before this is called. Reported rather than fallen through to "needs an
        // annotation", which would send someone who wrote one looking in the wrong place.
        if let mode {
            record(RouteCodegenDiagnostic(.responseModeMissingCodec(route, annotation: mode.name), at: function.name))
            return nil
        }
        record(RouteCodegenDiagnostic(.missingResponseAnnotation(route), at: function.name))
        return nil
    }

    /// The buffered terminal's assignment: the handler's return, through the mode's own codec.
    ///
    /// The counterpart of ``streamingOutcome(from:call:staticHeaders:drainsMiddleware:mode:)``, and shaped
    /// like it deliberately — one function per terminal, each reading the same mode. Every mode emits the
    /// same shape here; the generator no longer knows that JSON is JSON.
    private mutating func bufferedOutcome(
        from function: FunctionDeclSyntax,
        call: String,
        shape: ResponseReturnShape,
        staticsLiteral: String?,
        drainsMiddleware: Bool,
        mode: ResolvedResponseMode
    ) -> String? {
        let route = function.name.text
        let attributes = function.attributes
        guard let codec = mode.codec else {
            record(RouteCodegenDiagnostic(.responseModeMissingCodec(route, annotation: mode.name), at: function.name))
            return nil
        }
        // Unreachable: `mode.name` is the name of an attribute this route carries, so the lookup that
        // produced it is the same one this reads. Guarded rather than force-unwrapped, and it returns
        // without a diagnostic only because there is nothing true to say.
        guard let annotatedStatus = annotatedStatus(from: attributes, annotation: mode.name) else {
            return nil
        }
        guard shape.hasBody else {
            record(RouteCodegenDiagnostic(.responseModeOnVoid(route, annotation: mode.name), at: function.name))
            return nil
        }
        // A returned status wins, so an annotated one could never be read. Rejecting the argument makes
        // the dead value unwritable rather than merely diagnosed; the bare annotation is still required,
        // because it names the codec.
        if shape.hasStatus, explicitStatusArgument(from: attributes, annotation: mode.name) != nil {
            record(
                RouteCodegenDiagnostic(
                    .deadResponseStatusArgument(route, annotation: mode.name),
                    at: function.name
                )
            )
            return nil
        }
        let fields = headerExpression(shape: shape, statics: staticsLiteral, drainsMiddleware: drainsMiddleware)
        // The codec is called on its *unbound* generic type: `Value` is inferred from the argument, so
        // this spelling serves a handler whose return type is opaque (`some Encodable`) as well as a
        // named one — which a `Codec<ReturnType>` spelling could not.
        guard shape.isTuple else {
            return """
                wireMVCOutcome = WireMVCResponse.encoded(
                try \(codec).encodeResponseBody(\(call), coding: \(codingExpression)),
                status: \(annotatedStatus),
                headerFields: \(fields)
                )
                """
        }
        let value = shape.hasStatus ? "\(returnLocal).\(responseTupleStatusLabel)" : annotatedStatus
        return """
            let \(returnLocal) = \(call)
            wireMVCOutcome = WireMVCResponse.encoded(
            try \(codec).encodeResponseBody(\(returnLocal).\(responseTupleBodyLabel), coding: \(codingExpression)),
            status: \(value),
            headerFields: \(fields)
            )
            """
    }

    /// The `WireMVCStreamingOutcome` expression a `.streaming` route's `building` closure ends in, or `nil`
    /// if this route fails to type-check as one.
    ///
    /// The producer is spelled from the mode's `codec` and resolved in the *controller's* module against
    /// whatever adapter it imports — the codegen names no HTML library, which is what keeps `@HTMLResponse`
    /// a convention rather than a dependency on Elementary, and is now what lets any streaming mode name a
    /// producer WireMVC has never heard of.
    mutating func streamingOutcome(
        from function: FunctionDeclSyntax,
        call: String,
        staticHeaders: [ResponseHeaderEntry],
        drainsMiddleware: Bool,
        mode: ResolvedResponseMode?
    ) -> String? {
        let route = function.name.text
        guard let mode else { return nil }
        guard let producer = mode.codec else {
            record(RouteCodegenDiagnostic(.responseModeMissingCodec(route, annotation: mode.name), at: function.name))
            return nil
        }
        guard let status = annotatedStatus(from: function.attributes, annotation: mode.name) else {
            return nil
        }
        guard let shape = responseReturnShape(of: function, route: route) else { return nil }
        guard shape.hasBody else {
            record(RouteCodegenDiagnostic(.responseModeOnVoid(route, annotation: mode.name), at: function.name))
            return nil
        }
        if shape.hasStatus, explicitStatusArgument(from: function.attributes, annotation: mode.name) != nil {
            record(
                RouteCodegenDiagnostic(
                    .deadResponseStatusArgument(route, annotation: mode.name),
                    at: function.name
                )
            )
            return nil
        }
        let statics = staticsLiteral(staticHeaders)
        let fields = headerExpression(shape: shape, statics: statics, drainsMiddleware: drainsMiddleware)

        guard shape.isTuple else {
            // `return` even though this is the only statement in the simple case: with a binding or a scope
            // prologue the `building` closure is multi-statement, and Swift infers a closure's result type
            // from a bare trailing expression only when it is the *sole* statement. One spelling for both.
            return """
                return WireMVCStreamingOutcome(
                status: \(status),
                headerFields: \(fields),
                producer: \(producer)(\(call))
                )
                """
        }
        let resolvedStatus = shape.hasStatus ? "\(returnLocal).\(responseTupleStatusLabel)" : status
        return """
            let \(returnLocal) = \(call)
            return WireMVCStreamingOutcome(
            status: \(resolvedStatus),
            headerFields: \(fields),
            producer: \(producer)(\(returnLocal).\(responseTupleBodyLabel))
            )
            """
    }

    /// The terminal for a **streaming** route (`@HTMLResponse`).
    ///
    /// `wireMVCStreamingTerminal` discriminates inside its own `do`/`catch` and consumes the sender once,
    /// afterwards — the same single-consume-site invariant the buffered terminal above maintains. Sending
    /// inside the `do` does not compile (`'responseSender' consumed more than once`), so the shape is the
    /// checker's choice rather than a preference.
    ///
    /// Everything that can fail *before* the head goes out — scope entry, body collection, parameter
    /// binding, the handler call, the header drain — sits inside `building`, so all of it still maps
    /// through the same `@ErrorResponse` chain a buffered route uses. Nothing after the first byte can be
    /// mapped; that is inherent to streaming, and is why the producer is only reached once `building`
    /// returns. The generated code never names the producer type: it is inferred from `building`.
    func streamingClosureBody(
        hasBinds: Bool,
        hasBody: Bool,
        binds: [String],
        outcome: String,
        scopeEntryPreamble: String,
        scopeEntryPrologue: String,
        errorMappings: [ErrorMapping]
    ) -> String {
        let bindsBlock = binds.isEmpty ? "" : binds.joined(separator: "\n") + "\n"
        // `building` ends in the outcome. A single-expression body needs no `return`; a multi-statement one
        // (a response tuple, a bind, a prologue) supplies its own — `streamingOutcome` writes it.
        let body = "\(scopeEntryPrologue)\(bindsBlock)\(outcome)"
        // A body route takes the collecting overload: `collectBody` consumes the reader, which a closure
        // cannot do, and hoisting the read above the call would take it outside the mapped region.
        let readerArgument = hasBody ? "\ncollectingBodyFrom: reader," : ""
        let buildingParameter = hasBody ? " requestBody in" : ""
        return """
            \(scopeEntryPreamble)try await wireMVCStreamingTerminal(
            responseSender: responseSender,\(readerArgument)
            building: {\(buildingParameter)
            \(body)
            },
            errorMapping: { wireMVCError in
            \(errorChainExpression(mappings: errorMappings, includeBindingBuiltin: hasBinds))
            }
            )
            """
    }

    /// The name of whichever response annotation is written on this route, or `nil` if none is.
    private func responseAnnotationName(on attributes: AttributeListSyntax) -> String? {
        responseAnnotationNames(on: attributes).first
    }

    /// Every response annotation written on this route, in source order — for the "exactly one" rule.
    ///
    /// An annotation is a response annotation because a `@ResponseMode` declaration for it was found, not
    /// because it is one of three names this file used to list. That single change is what makes a mode
    /// declared outside WireMVC visible to the rest of the generator.
    func responseAnnotationNames(on attributes: AttributeListSyntax) -> [String] {
        var names: [String] = []
        for case let .attribute(attr) in attributes {
            let name = attr.attributeName.trimmedDescription
            if discoveredModes[name] != nil { names.append(name) }
        }
        return names
    }

    /// The `status:` argument written on `annotation`, or `nil` for the bare form — as distinct from
    /// ``annotatedStatus(from:annotation:)``, which substitutes `.ok` and so cannot tell an author-written
    /// status from the default.
    func explicitStatusArgument(from attributes: AttributeListSyntax, annotation: String) -> String? {
        for case let .attribute(attr) in attributes where attr.attributeName.trimmedDescription == annotation {
            guard case let .argumentList(list) = attr.arguments else { return nil }
            return list.first { $0.label?.text == "status" }?.expression.trimmedDescription
        }
        return nil
    }

    /// The `statics:` literal, or `nil` when the route contributes no constant fields.
    func staticsLiteral(_ entries: [ResponseHeaderEntry]) -> String? {
        entries.isEmpty ? nil : responseHeaderLiteral(entries)
    }

    /// The `headerFields:` argument — one `WireMVCResponseHeaders.resolved` call over whichever
    /// contributors this route actually has. Both arguments default, so a route with only one names only
    /// that one.
    func headerExpression(shape: ResponseReturnShape, statics: String?, drainsMiddleware: Bool) -> String {
        let returned = shape.hasHeaders ? "\(returnLocal).\(responseTupleHeadersLabel)" : nil
        let arguments = [
            statics.map { "statics: \($0)" },
            returned.map { "returned: \($0)" },
            drainsMiddleware ? "middleware: try await \(responseHeaderDrainLocal).drain()" : nil,
        ].compactMap { $0 }
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
    mutating func responseReturnShape(
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

    /// The status `annotation` names, defaulting to `.ok` for the bare form; `nil` when absent entirely.
    func annotatedStatus(from attributes: AttributeListSyntax, annotation: String) -> String? {
        for case let .attribute(attr) in attributes where attr.attributeName.trimmedDescription == annotation {
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

    /// The status a `.bodiless` mode names, read off whichever annotation the route actually wrote.
    ///
    /// Both spellings, because the two that exist are both reasonable and a mode author picks one without
    /// knowing this function exists: `@ResponseStatus(.noContent)` takes its status **unlabelled** (there is
    /// nothing else it could be saying), while every body-carrying mode takes `status:` alongside the codec's
    /// other arguments. Reading only the first is what made a `.bodiless` mode declared outside WireMVC
    /// produce an empty witness — a route dropped in silence, which is the failure `noRouteIsSilentlyDropped`
    /// exists to catch.
    func bodilessStatus(from attributes: AttributeListSyntax, annotation: String) -> String? {
        for case let .attribute(attr) in attributes where attr.attributeName.trimmedDescription == annotation {
            guard case let .argumentList(list) = attr.arguments, !list.isEmpty else { return nil }
            if let labelled = list.first(where: { $0.label?.text == "status" }) {
                return labelled.expression.trimmedDescription
            }
            // The unlabelled first argument, and only when it is unlabelled: a mode taking some other
            // labelled argument is not naming a status with it.
            guard let first = list.first, first.label == nil else { return nil }
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

/// The per-request ``ResponseHeaderRegistry``, created at the fold base and threaded through the box.
let responseHeaderRegistryLocal = "wireMVCResponseHeaderRegistry"

/// The registry read off the *final* box, before `withPendingContents` consumes it — the terminal drains
/// this when it builds the outcome. Bound only for a typed terminal with a fold; a raw handler has no
/// outcome to drain into, and a route with no middleware has no registry at all.
let responseHeaderDrainLocal = "wireMVCResponseHeaderDrain"

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
