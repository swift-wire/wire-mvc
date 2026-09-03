import SwiftSyntax
import SwiftSyntaxMacros

/// `@Controller(_ path: String)` / `@Controller()` — a **marker**. It expands to nothing: the
/// controller's route-contributor proxy is generated under plugin orchestration in the consumer module,
/// not by this macro. WireGen emits the proxy's *structural* half (the `struct` — subject + factory
/// fields + init, from `.contributesProxy`), and the `WireMVCRouteGen` tool emits the *witness* as an
/// `extension` (from the shared `WireMVCCodegen` route codegen). `@Controller` survives only so the
/// attribute is legal syntax carrying the path prefix — WireGen reads it (via `wireMVCControllerAlias`)
/// as the proxy-contribution directive, and the tool reads its path when generating the witness.
///
/// The route-shape diagnostics (unannotated parameter, path mismatch, raw-route roles, …) are emitted
/// by the tool at build time, anchored at their source locations — see `WireMVCCodegen`.
public struct ControllerMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
