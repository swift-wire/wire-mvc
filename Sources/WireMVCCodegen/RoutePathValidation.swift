import SwiftSyntax

// Route-template validation that is knowable from the template text alone, kept out of `RouteCodegen` so
// that file's length stays about route *generation*.

extension RouteBlockGenerator {
    /// Record a diagnostic if `path` contains a wildcard segment, and report whether it did.
    ///
    /// Wildcards are not expressible in WireMVC route templates, and left unchecked one reads as an
    /// ordinary parameter: `{path*}` binds a single segment under the literal name `"path*"` and answers
    /// 404 to exactly the multi-segment requests it was written for. The bridged runtimes mangle it
    /// differently again — Hummingbird as a single-segment capture named `path*`, Vapor as a literal
    /// segment — so three silent wrong answers become one build error.
    ///
    /// Diagnosed here rather than only at the router's startup precondition because a route template is a
    /// literal in the source. `RouteTrie.isWildcard` is the backstop for builders that never pass through
    /// codegen; the two recognise the same spellings deliberately.
    ///
    /// Whether this becomes expressible — and on the bridged runtimes, which *do* have wildcards — is what
    /// `Documentation/Notes/CatchAllMountingProbe.md` proposes measuring.
    mutating func recordWildcardSegment(in path: String, at token: TokenSyntax) -> Bool {
        guard let wildcard = Self.wildcardSegment(in: path) else { return false }
        // `record` rather than appending: the storage keeps its `private(set)` setter, and this is the
        // one way in.
        record(RouteCodegenDiagnostic(.wildcardPathSegment(path: path, segment: wildcard), at: token))
        return true
    }

    /// The first wildcard segment in a route template, or `nil`.
    ///
    /// Recognises more spellings than the one convention WireMVC would eventually adopt — `{path*}`, a bare
    /// `*`, and `**` — so someone arriving from Hummingbird or Vapor meets the diagnostic rather than a
    /// mis-route. The cost of over-recognising is one rejected parameter name ending in an asterisk, which
    /// is not a name anyone writes.
    static func wildcardSegment(in path: String) -> String? {
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            if segment == "*" || segment == "**" { return String(segment) }
            if segment.hasPrefix("{"), segment.hasSuffix("}"), segment.dropLast().hasSuffix("*") {
                return String(segment)
            }
        }
        return nil
    }
}
