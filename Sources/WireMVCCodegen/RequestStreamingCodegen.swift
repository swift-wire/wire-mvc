import SwiftSyntax

// The request half's streaming tier: which parameter is handed the reader, and the combinations that cannot
// be honoured. Split from `RouteCodegen.swift` along the seam that file already follows — `RawRouteCodegen`
// and `ResponseCodegen` are the other two — and because the whole of this concern is three questions asked
// once per route.

extension RouteBlockGenerator {
    /// Whether a binding **streams** the request body — the `@RequestBinding(.streamingBody)` obligation.
    ///
    /// Distinct from ``readsRequestBody(_:)`` and never true alongside it on one route: the terminal either
    /// collects the body into `[UInt8]` and hands it to every binding, or hands the reader itself to exactly
    /// one. There is no arrangement that does both, because collecting consumes the reader.
    func streamsRequestBody(_ wrapper: String) -> Bool {
        !(discoveredBindings[wrapper]?.isDisjoint(with: .anyStreamedBody) ?? true)
    }

    /// Whether a binding lends the **handler** a stream — `@RequestBinding(.bodyStream)`.
    ///
    /// Emitted differently from every other binding: not `let x = Wrapper<T>.bind(…)` but
    /// `var x = Wrapper.makeStream(reader: reader)`, passed `&x`. The stream borrows the reader, which stays
    /// in the terminal's frame, so a `~Escapable` stream cannot outlive the request — and the handler needs
    /// a mutable binding because pulling from a stream advances it.
    func lendsBodyStream(_ wrapper: String) -> Bool {
        discoveredBindings[wrapper]?.contains(.bodyStream) ?? false
    }

    /// Whether a lent stream's parameter is `consuming`, which is the only ownership that fits.
    ///
    /// A stream is consumed exactly once, through `withParts`. `inout` was emitted here briefly, on the
    /// theory that it would become usable when SE-0293 gains `inout` support — but it is not merely
    /// unavailable, it is **wrong for this shape**: calling a `consuming` method on an `inout` binding is
    /// `missing reinitialization of inout parameter after consume` regardless of property wrappers, and
    /// there is nothing sensible to put back. `borrowing` cannot call a consuming method at all.
    func hasConsumingOwnership(_ parameter: FunctionParameterSyntax) -> Bool {
        guard let attributed = parameter.type.as(AttributedTypeSyntax.self) else { return false }
        return attributed.specifiers.contains { $0.trimmedDescription == "consuming" }
    }

    /// The parameters that stream the body, in declaration order. More than one is a contradiction; keeping
    /// them all lets the diagnostic say how many rather than just "too many".
    func streamingBodyParameters(_ function: FunctionDeclSyntax) -> [FunctionParameterSyntax] {
        function.signature.parameterClause.parameters.filter { param in
            guard let binding = binding(from: param.attributes) else { return false }
            return streamsRequestBody(binding.wrapper)
        }
    }

    /// Whether this route streams its body, or `nil` if its body obligations contradict each other.
    ///
    /// Three ways they can. Every one is *also* caught further down — the reader would be consumed twice or
    /// not exist at all, and the move-only checker is unforgiving about both — but that error names a line
    /// of generated code, and the author needs to be told which of their routes is wrong and why.
    mutating func validatedBodyObligations(
        of function: FunctionDeclSyntax,
        hasBody: Bool,
        mode: ResolvedResponseMode?
    ) -> Bool? {
        let streaming = streamingBodyParameters(function)
        let route = function.name.text
        // A body can be streamed once: reading it consumes the reader. Both streamed kinds count — a route
        // cannot reduce the body *and* lend it to the handler, for the same reason it cannot do either twice.
        if streaming.count > 1 {
            record(
                RouteCodegenDiagnostic(
                    .multipleStreamingBodyBindings(route, count: streaming.count),
                    at: streaming[1]
                )
            )
            return nil
        }
        guard !streaming.isEmpty else { return false }
        // Collecting consumes the reader too, so the two tiers cannot share a route.
        if hasBody {
            record(RouteCodegenDiagnostic(.streamingBodyWithCollectedBody(route), at: function.name))
            return nil
        }
        // The streaming *response* terminal takes the reader itself — it collects the request body before
        // the head goes out, because a closure cannot consume a value it only borrows. So there is none left
        // to hand a streaming binding, and the combination is refused rather than emitted.
        if mode?.terminal == .streaming {
            record(RouteCodegenDiagnostic(.streamingBodyOnStreamingResponse(route), at: function.name))
            return nil
        }
        return true
    }

    /// The expression that builds a lent stream, or `nil` if this parameter is not one.
    ///
    /// Kept with the rest of the streaming concern rather than beside the `bind` / `bindStreaming` spellings
    /// it sits among, because none of it is shared with them: a different type comes from a different place
    /// and is constructed rather than called.
    mutating func lentStreamExpression(
        for param: FunctionParameterSyntax,
        binding: Binding,
        name: String,
        function: FunctionDeclSyntax
    ) -> String? {
        guard lendsBodyStream(binding.wrapper) else { return nil }
        // The type comes from the binding's `@RequestBinding(stream:)` and is spelled with **no type
        // argument** — the reader is the argument and inference does the rest, which is the only way a
        // witness can name a reader-dependent type.
        guard let stream = discoveredBindings[binding.wrapper]?.streamType else {
            record(RouteCodegenDiagnostic(.bodyStreamNeedsStreamType(binding: binding.wrapper), at: param))
            return ""
        }
        guard hasConsumingOwnership(param) else {
            record(
                RouteCodegenDiagnostic(.bodyStreamNeedsOwnership(function.name.text, parameter: name), at: param)
            )
            return ""
        }
        return "\(stream)(request: request, reader: reader)"
    }
}
