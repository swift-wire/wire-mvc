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
        discoveredBindings[wrapper, default: []].contains(.streamingBody)
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
        // A body can be streamed once: reading it consumes the reader.
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
}
