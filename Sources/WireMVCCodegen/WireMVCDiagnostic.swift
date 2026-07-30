public import SwiftDiagnostics
public import SwiftSyntax

/// The `@Controller` route-codegen diagnostics — node-anchored `error`s (M1 standard), each emitted at
/// the offending parameter or function so the fix-it location is precise. Shared by the `@Controller`
/// macro (which routes them to the expansion context) and the `WireMVCRouteGen` tool (which prints them
/// as `file:line:col: error:`).
public enum WireMVCDiagnostic: DiagnosticMessage, Sendable {
    case unannotatedParameter(String)
    case pathPlaceholderMissing(name: String, path: String)
    case missingResponseAnnotation(String)
    case jsonResponseOnVoid(String)
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

    public var message: String {
        switch self {
        case .unannotatedParameter(let name):
            "handler parameter '\(name)' needs a binding annotation — one of @Path, @Query, @JSONBody, @Header"
        case .pathPlaceholderMissing(let name, let path):
            "@Path '\(name)' has no matching '{\(name)}' placeholder in the route path \"\(path)\""
        case .missingResponseAnnotation(let route):
            "route '\(route)' needs exactly one response annotation — @JSONResponse (returns a body) or @ResponseStatus (Void)"
        case .jsonResponseOnVoid(let route):
            "@JSONResponse on '\(route)' requires a returned value; use @ResponseStatus for a Void handler"
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
        case .globalMiddlewareUnsupportedArgument(let reference):
            "global @Middleware on a @WireMVCBootstrap root must be factory-form (@Middleware(Key), a generic-over-box @Factory @MiddlewareFactory) — a by-type or keyed-binding middleware ('\(reference)') is concrete over a fixed box and can't compose in the global chain (the router is fixed on its box type). Write it generic (factory-form), or scope it to a @Controller."
        }
    }

    public var severity: DiagnosticSeverity { .error }

    public var diagnosticID: MessageID {
        let id: String
        switch self {
        case .unannotatedParameter: id = "unannotatedParameter"
        case .pathPlaceholderMissing: id = "pathPlaceholderMissing"
        case .missingResponseAnnotation: id = "missingResponseAnnotation"
        case .jsonResponseOnVoid: id = "jsonResponseOnVoid"
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
