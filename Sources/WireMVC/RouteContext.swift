/// Which route a request matched: the registered path *template* and the parameters the router pulled
/// out of it. Carried on ``RequestResponseMiddlewareBox`` so a route-scope middleware can tell what it
/// is folded onto, which the fold otherwise never learns — the match happens in the router and the
/// generated register closure kept both values to itself.
///
/// **The template, not just the parameters.** `["id": "notes"]` gives the values but not the identity:
/// `/documents/{id}` and `/things/{id}` are indistinguishable from parameters alone. `template` is the
/// `path:` argument the route was registered under — compile-time text the codegen already holds — so a
/// middleware can key policy on the route rather than on a re-parse of `request.path`, which a route
/// with parameters cannot be compared against literally anyway.
///
/// > Important: `pathParameters` holds `Substring`s sliced out of the *request's* path storage, so this
/// > value is only meaningful for as long as that request is. It rides on the box, which also carries
/// > the request, so within a fold that is guaranteed by construction; storing one beyond the request is
/// > not what it is for.
public struct RouteContext: Sendable, Equatable {
    /// The path template the route was registered under — `/documents/{id}`, not `/documents/notes`.
    public let template: String

    /// The parameters the router matched out of the template. Empty for a route that declares none,
    /// which is a *different* thing from having no route at all — see ``RequestResponseMiddlewareBox/peekedRoute``.
    public let pathParameters: [String: Substring]

    public init(template: String, pathParameters: [String: Substring]) {
        self.template = template
        self.pathParameters = pathParameters
    }

    /// The matched value for `name`, as a `String`.
    public subscript(_ name: String) -> String? {
        pathParameters[name].map(String.init)
    }
}
