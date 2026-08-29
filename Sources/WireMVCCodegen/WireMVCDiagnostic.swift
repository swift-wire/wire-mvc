public import SwiftDiagnostics
public import SwiftSyntax

/// The `@Controller` route-codegen diagnostics — node-anchored `error`s (M1 standard), each emitted at
/// the offending parameter or function so the fix-it location is precise. Shared by the `@Controller`
/// macro (which routes them to the expansion context) and the `WireMVCRouteGen` tool (which prints them
/// as `file:line:col: error:`).
public enum WireMVCDiagnostic: DiagnosticMessage, Sendable {
    case unannotatedParameter(String)
    case scopedBindingOnUnscopedController(binding: String, worker: String, parameter: String, seed: String)
    case scopedBindingSeedMismatch(binding: String, worker: String, workerSeed: String, controllerSeed: String)
    case routeOmittedFromClient(route: String, binding: String, parameter: String)
    case pathPlaceholderMissing(name: String, path: String)
    case wildcardPathSegment(path: String, segment: String)
    case catchAllNotLastSegment(path: String, segment: String)
    case missingResponseAnnotation(String)
    case responseModeOnVoid(String, annotation: String)
    case responseStatusOnValue(String)
    case unsupportedRawParameter(name: String, type: String)
    case rawRouteMissingSender(String)
    case rawRouteRoleCountMismatch(String, roles: Int, parameters: Int)
    case middlewareFactoryRequiresFactory
    case errorResponseClosureNeedsTypedParameter
    case errorResponseUnresolvedMapping(String)
    case errorResponseDuplicateType(type: String, scope: String)
    case errorResponseCatchAllNotLast(scope: String)
    case notFoundNotRaw(String)
    case globalMiddlewareUnsupportedArgument(String)
    case multipleTestingKeys(String, first: String)
    case redundantCodingOverride(String, scope: String)
    case responseTupleInvalidLabels(String, labels: String)
    case responseHeaderDuplicateField(field: String, scope: String)
    case responseHeaderOnRawRoute(String)
    case responseAnnotationOnSelfDescribingReturn(String, annotation: String)
    case deadResponseStatusArgument(String, annotation: String)
    case responseModeMissingCodec(String, annotation: String)
    case bodilessModeNeedsStatus(String, annotation: String)
    case bodyStreamNeedsStreamType(binding: String)
    case bodyStreamNeedsOwnership(String, parameter: String)
    case multipleReaderBodyBindings(String, count: Int)
    case readerBodyWithCollectedBody(String)
    case bodyStreamOnStreamingResponse(String)
    case multipleResponseAnnotations(String, annotations: String)
    case bindingMissingSendConformance(binding: String, conformance: String)

    public var message: String {
        switch self {
        case .unannotatedParameter(let name):
            "handler parameter '\(name)' needs a binding annotation — one of @Path, @Query, @JSONBody, @Header"
        case .scopedBindingOnUnscopedController(let binding, let worker, let parameter, let seed):
            "'@\(binding) \(parameter)' resolves through '\(worker)', which is bound in @Scoped(seed: \(seed).self) — but this controller is not scoped, so its routes hold the controller directly and enter no scope, and there is nothing to construct '\(worker)' in. Mark the controller @Scoped(seed: \(seed).self)"
        case .routeOmittedFromClient(let route, let binding, let parameter):
            "'\(route)' is omitted from the generated client: '@\(binding) \(parameter)' resolves from the request scope, so a client has no value to send for it — the handler's parameter type is what the *scope* produced, not what the caller supplies. The route stays drivable through the untyped client"
        case .scopedBindingSeedMismatch(let binding, let worker, let workerSeed, let controllerSeed):
            "'@\(binding)' resolves through '\(worker)', which is bound in @Scoped(seed: \(workerSeed).self), but this controller is in @Scoped(seed: \(controllerSeed).self) — sibling seeded scopes are isolated by design, so the controller's scope entry constructs only its own. Bind '\(worker)' in @Scoped(seed: \(controllerSeed).self)"
        case .pathPlaceholderMissing(let name, let path):
            "@Path '\(name)' has no matching '{\(name)}' placeholder in the route path \"\(path)\""
        case .wildcardPathSegment(let path, let segment):
            "route path \"\(path)\" uses '\(segment)': the only wildcard WireMVC route templates express is the trailing catch-all, '{name*}'"
        case .catchAllNotLastSegment(let path, let segment):
            "route path \"\(path)\": '\(segment)' claims the rest of the path, so the segments after it can never match — a catch-all must be the last segment"
        case .missingResponseAnnotation(let route):
            "route '\(route)' needs exactly one response annotation — @JSONResponse or @HTMLResponse (returns a body), @ResponseStatus (Void), or any mode declared with @ResponseMode"
        case .responseModeOnVoid(let route, let annotation):
            "@\(annotation) on '\(route)' requires a returned value; use @ResponseStatus for a Void handler"
        case .responseStatusOnValue(let route):
            "@ResponseStatus on '\(route)' requires a Void handler; use @JSONResponse to encode the returned value"
        case .unsupportedRawParameter(let name, let type):
            "@RawRoute parameter '\(name)' has a type ('\(type)') that can't be inferred — a bare @RawRoute infers HTTPRequest, [String: Substring], the AsyncReader-constrained reader, and the HTTPResponseSender-constrained sender by type. For a transformed slot (a type a middleware produces, e.g. MultiPartSender<S>), name the roles explicitly: @RawRoute(.role, …), one role per parameter"
        case .rawRouteMissingSender(let route):
            "@RawRoute handler '\(route)' must take the response sender (a parameter generic over HTTPResponseSender, or bound via @RawRoute(.responseSender)) to write its response"
        case .rawRouteRoleCountMismatch(let route, let roles, let parameters):
            "@RawRoute(role, …) on '\(route)' lists \(roles) role(s) but the handler has \(parameters) parameter(s) — give exactly one role per parameter, in order"
        case .middlewareFactoryRequiresFactory:
            "@MiddlewareFactory requires @Factory on the same type — it supplies the box-role mapping for a factory template. Add @Factory(key) to make this a Wire factory template."
        case .errorResponseClosureNeedsTypedParameter:
            "@ErrorResponse closure needs a typed parameter — spell the error type, e.g. { (e: NotFound) in … }, so the mapping matches on it"
        case .errorResponseUnresolvedMapping(let reference):
            "@ErrorResponse named-function reference '\(reference)' is not supported yet — a reference to the controller's own method is a circular macro reference, and a separate type needs cross-module resolution. Use an inline typed-parameter closure: @ErrorResponse({ (e: SomeError) in … })"
        case .errorResponseDuplicateType(let type, let scope):
            "@ErrorResponse maps '\(type)' more than once at \(scope) scope — each error type needs a distinct mapping at a scope (a route entry overrides a controller entry for the same type)"
        case .errorResponseCatchAllNotLast(let scope):
            "the @ErrorResponse Swift.Error catch-all must be the last error entry at \(scope) scope — a mapping listed after it can never be reached"
        case .notFoundNotRaw(let name):
            "@NotFound handler '\(name)' must be @RawRoute — the fallback writes the response directly (no matched route to decode/encode against). Add @RawRoute and take the response sender."
        case .multipleTestingKeys(let reference, let first):
            "the keyed test harness serves one TestingKey per target, and '\(first)' is already this target's key — a suite passing '\(reference)' would be served '\(first)''s variant graph instead, silently. Move '\(reference)' to its own test target, or fold its @BindType markers into '\(first)'. (Serving several variants from one target is deferred — see swift-wire's PendingIssues/11.)"
        case .redundantCodingOverride(let reference, let scope):
            "@Coding(\(reference)) on this \(scope) names the binding the enclosing scope already selected, so it overrides nothing. Name a different binding — a BindingKey<WireMVCCoding> distinguishes several codings of the same type — or drop the annotation."
        case .responseTupleInvalidLabels(let route, let labels):
            "the response tuple returned by '\(route)' is labelled (\(labels)), which is not a response shape — write one of (headers:body:), (status:body:), (status:headers:body:), or (status:headers:) for a bodiless response. Returning a payload that is genuinely a tuple? Leave its elements unlabelled and it stays the body."
        case .responseHeaderDuplicateField(let field, let scope):
            "@ResponseHeader sets '\(field)' more than once at \(scope) scope, so which value was meant is undecidable. To *add* a value to a field that legitimately repeats (Set-Cookie, Vary), pass the verb: @ResponseHeader(\(field), \"…\", .append). To replace, keep one entry (a route entry already overrides a controller entry for the same field)."
        case .responseAnnotationOnSelfDescribingReturn(let route, let annotation):
            "@\(annotation) on '\(route)' declares nothing the return type does not already say — a (status:headers:) tuple carries no body and computes its own status, so the annotation would be read by nobody and could only go out of date. Remove it. (A route that returns a body still needs @JSONResponse: that names the codec.)"
        case .bodyStreamNeedsStreamType(let binding):
            "binding '\(binding)' is declared @RequestBinding(.bodyStream) but names no stream type — add stream: \"YourStream\", naming the type whose init takes (request:reader:). It cannot be a factory on the binding itself: a property wrapper is generic over the parameter's type, so a static method on it has no way to resolve that generic parameter"
        case .bodyStreamNeedsOwnership(let route, let parameter):
            "parameter '\(parameter)' on '\(route)' lends a request body stream, so it must be 'consuming' — the stream is used up once, through its 'withParts'-style entry point. 'inout' cannot work: calling a consuming method on an inout binding requires reinitialising it, and there is nothing to put back"
        case .multipleReaderBodyBindings(let route, let count):
            "route '\(route)' has \(count) bindings that stream the request body — a body can be streamed once, because reading it consumes the reader. Collect it instead (a @RequestBinding(.body) binding hands every parameter the same bytes), or stream it into one binding that produces what the others needed"
        case .readerBodyWithCollectedBody(let route):
            "route '\(route)' both streams and collects its request body — the reader cannot do both, since collecting consumes it. Use one or the other"
        case .bodyStreamOnStreamingResponse(let route):
            "route '\(route)' lends its request body stream to the handler on a streaming-response route — a duplex route, which is not supported yet. A typed handler returns before its response body is written, so it cannot still be holding the request stream; that needs the response to be a parameter rather than a return value, which is designed but blocked on a compiler bug (swiftlang/swift#91473). Use @RawRoute, which supports both directions today, or a binding that reduces the body instead of lending it (@RequestBinding(.readerBody)), which does combine with a streaming response"
        case .bodilessModeNeedsStatus(let route, let annotation):
            "@\(annotation) on '\(route)' names no status — a bodiless mode carries nothing but one, so it must say which. Write it as @\(annotation)(.noContent) or @\(annotation)(status: .noContent)"
        case .responseModeMissingCodec(let route, let annotation):
            "@\(annotation) on '\(route)' declares no codec — its @ResponseMode must name one, since a mode that encodes a body has to say what encodes it"
        case .bindingMissingSendConformance(let binding, let conformance):
            "binding '\(binding)' is declared @RequestBinding but does not conform to \(conformance), so the generated typed client cannot send it — add the conformance, or the client's call will fail to compile. (If it is declared in a module this build does not parse, ignore this.)"
        case .multipleResponseAnnotations(let route, let annotations):
            "route '\(route)' carries more than one response annotation (\(annotations)) — a route states its response mode exactly once"
        case .deadResponseStatusArgument(let route, let annotation):
            "the status on @\(annotation)(status:) for '\(route)' is never used — the response tuple returns a status, and a returned status wins. Drop the argument and keep the bare @\(annotation), which is what names the response mode."
        case .responseHeaderOnRawRoute(let route):
            "@ResponseHeader does not apply to the @RawRoute handler '\(route)' — a raw handler writes its own response head, so nothing here could set the field for it. Set it on the HTTPResponse the handler sends."
        case .globalMiddlewareUnsupportedArgument(let reference):
            "global @Middleware on a @WireMVCBootstrap root must be factory-form (@Middleware(Key), a generic-over-box @Factory @MiddlewareFactory) — a by-type or keyed-binding middleware ('\(reference)') is concrete over a fixed box and can't compose in the global chain (the router is fixed on its box type). Write it generic (factory-form), or scope it to a @Controller."
        }
    }

    /// Everything is an error except the send-conformance check, which is syntactic and cannot see a
    /// conformance declared in a module this build does not parse. A false error there would break a valid
    /// build; a false warning is merely noise.
    public var severity: DiagnosticSeverity {
        switch self {
        case .bindingMissingSendConformance: .warning
        // Omitting a route is a *choice* the generator makes, not a mistake the author made — the route
        // serves correctly and stays drivable untyped. Reported so the omission is visible (#87 is what a
        // silent one costs), at a severity that does not fail a build over a client nobody may want.
        case .routeOmittedFromClient: .warning
        default: .error
        }
    }

    public var diagnosticID: MessageID {
        let id: String
        switch self {
        case .unannotatedParameter: id = "unannotatedParameter"
        case .scopedBindingOnUnscopedController: id = "scopedBindingOnUnscopedController"
        case .scopedBindingSeedMismatch: id = "scopedBindingSeedMismatch"
        case .routeOmittedFromClient: id = "routeOmittedFromClient"
        case .pathPlaceholderMissing: id = "pathPlaceholderMissing"
        case .wildcardPathSegment: id = "wildcardPathSegment"
        case .catchAllNotLastSegment: id = "catchAllNotLastSegment"
        case .missingResponseAnnotation: id = "missingResponseAnnotation"
        case .responseModeOnVoid: id = "responseModeOnVoid"
        case .responseStatusOnValue: id = "responseStatusOnValue"
        case .unsupportedRawParameter: id = "unsupportedRawParameter"
        case .rawRouteMissingSender: id = "rawRouteMissingSender"
        case .rawRouteRoleCountMismatch: id = "rawRouteRoleCountMismatch"
        case .middlewareFactoryRequiresFactory: id = "middlewareFactoryRequiresFactory"
        case .errorResponseClosureNeedsTypedParameter: id = "errorResponseClosureNeedsTypedParameter"
        case .errorResponseUnresolvedMapping: id = "errorResponseUnresolvedMapping"
        case .errorResponseDuplicateType: id = "errorResponseDuplicateType"
        case .errorResponseCatchAllNotLast: id = "errorResponseCatchAllNotLast"
        case .notFoundNotRaw: id = "notFoundNotRaw"
        case .globalMiddlewareUnsupportedArgument: id = "globalMiddlewareUnsupportedArgument"
        case .multipleTestingKeys: id = "multipleTestingKeys"
        case .redundantCodingOverride: id = "redundantCodingOverride"
        case .responseTupleInvalidLabels: id = "responseTupleInvalidLabels"
        case .responseHeaderDuplicateField: id = "responseHeaderDuplicateField"
        case .responseHeaderOnRawRoute: id = "responseHeaderOnRawRoute"
        case .responseAnnotationOnSelfDescribingReturn: id = "responseAnnotationOnSelfDescribingReturn"
        case .deadResponseStatusArgument: id = "deadResponseStatusArgument"
        case .responseModeMissingCodec: id = "responseModeMissingCodec"
        case .bodilessModeNeedsStatus: id = "bodilessModeNeedsStatus"
        case .bodyStreamNeedsStreamType: id = "bodyStreamNeedsStreamType"
        case .bodyStreamNeedsOwnership: id = "bodyStreamNeedsOwnership"
        case .multipleReaderBodyBindings: id = "multipleReaderBodyBindings"
        case .readerBodyWithCollectedBody: id = "readerBodyWithCollectedBody"
        case .bodyStreamOnStreamingResponse: id = "bodyStreamOnStreamingResponse"
        case .multipleResponseAnnotations: id = "multipleResponseAnnotations"
        case .bindingMissingSendConformance: id = "bindingMissingSendConformance"
        }
        return MessageID(domain: "WireMVC", id: id)
    }
}

/// One route-codegen diagnostic captured against the syntax node it anchors to. The caller decides how
/// to surface it: the macro wraps it in a `SwiftDiagnostics.Diagnostic` for the expansion context; the
/// tool resolves the node's `SourceLocation` and prints a compiler-style line.
public struct RouteCodegenDiagnostic: Sendable {
    public let message: WireMVCDiagnostic
    public let node: Syntax

    public init(_ message: WireMVCDiagnostic, at node: some SyntaxProtocol) {
        self.message = message
        self.node = Syntax(node)
    }
}
