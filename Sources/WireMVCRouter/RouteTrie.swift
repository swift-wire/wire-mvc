public import HTTPTypes

// The router's path-segment trie — the routing algorithm, factored out of the generic
// `TrieRouteBuilder`/`FrozenTrieRouter` so it is testable without the proposal server's `~Copyable`
// request/response machinery. It maps `(method, path template)` → a registration index; the generic
// types hold the parallel handler array and look it up by that index.
//
// Build → freeze → serve: `RouteTrie` inserts routes into a mutable trie (flat node array, literal
// children in a dictionary); `freeze()` compacts it into `FrozenRouteTrie`, whose literal children are
// segment-sorted for binary search (no per-request hashing). Production hardening — 405-vs-404,
// static > param > catch-all precedence beyond literal-first, trailing-slash policy, catch-all params,
// duplicate-route diagnostics — is tracked in [Notes/WireMVCRouter.md].

/// A `{name}` parameter edge out of a trie node: the segment name and the child node it leads to.
struct ParameterEdge: Sendable, Equatable {
    let name: String
    let child: Int
}

/// Build phase (non-generic): insert path templates into a segment trie. Nodes live in a flat array
/// (indices, not pointers).
struct RouteTrie {
    struct BuildNode {
        var literalChildren: [String: Int] = [:]
        var parameterChild: ParameterEdge?
        var routes: [(method: HTTPRequest.Method, index: Int)] = []
    }

    private var nodes: [BuildNode] = [BuildNode()]
    private var routeCount = 0

    /// Insert `method` + `path`; returns the route index (the caller stores the handler at the same
    /// index in a parallel array). Literal segments share nodes; a `{name}` segment takes the node's
    /// single parameter edge (first name wins for a shared prefix).
    mutating func insert(method: HTTPRequest.Method, path: String) -> Int {
        var current = 0
        for segment in Self.segments(path) {
            if segment.hasPrefix("{"), segment.hasSuffix("}") {
                let name = String(segment.dropFirst().dropLast())
                if let existing = nodes[current].parameterChild {
                    current = existing.child
                } else {
                    nodes.append(BuildNode())
                    let child = nodes.count - 1
                    nodes[current].parameterChild = ParameterEdge(name: name, child: child)
                    current = child
                }
            } else if let child = nodes[current].literalChildren[String(segment)] {
                current = child
            } else {
                nodes.append(BuildNode())
                let child = nodes.count - 1
                nodes[current].literalChildren[String(segment)] = child
                current = child
            }
        }
        let index = routeCount
        routeCount += 1
        nodes[current].routes.append((method, index))
        return index
    }

    /// Compact into the immutable trie: each node's literal children become a segment-sorted array
    /// (binary-searchable, no per-lookup hashing).
    consuming func freeze() -> FrozenRouteTrie {
        FrozenRouteTrie(
            nodes: nodes.map { node in
                FrozenRouteTrie.Node(
                    literalChildren: node.literalChildren
                        .sorted { $0.key < $1.key }
                        .map { (segment: $0.key, child: $0.value) },
                    parameterChild: node.parameterChild,
                    routes: node.routes
                )
            }
        )
    }

    static func segments(_ path: String) -> [Substring] {
        path.split(separator: "/", omittingEmptySubsequences: true)
    }
}

/// What resolving a request against the trie concluded.
///
/// Three outcomes rather than an optional, because "no such path" and "not that method on this path" are
/// different answers and HTTP has different status codes for them. Collapsing both to `nil` meant every
/// wrong-method request was a `404`, which tells a client its URL is wrong when its URL is right.
enum RouteResolution: Sendable, Equatable {
    /// A route matched: its registration index, and the `{name}` parameters bound along the way.
    case matched(index: Int, parameters: [String: Substring])
    /// The path named a node carrying routes, but none for this method. Answered `405` with `Allow`.
    ///
    /// `allowed` is deduplicated and sorted, so the header is deterministic for a given registration set
    /// rather than dependent on the order routes happened to be registered in.
    case methodNotAllowed(allowed: [HTTPRequest.Method])
    /// Nothing matched the path at all. Answered `404`.
    case notFound
}

/// Serve phase (non-generic): the immutable trie. `resolve` walks the request path, collecting
/// `{name}` parameters, and reports one of the three ``RouteResolution`` outcomes. Literal children are
/// matched by binary search; a literal match beats the parameter edge (static-before-param precedence).
struct FrozenRouteTrie: Sendable {
    struct Node: Sendable {
        let literalChildren: [(segment: String, child: Int)]  // sorted by segment
        let parameterChild: ParameterEdge?
        let routes: [(method: HTTPRequest.Method, index: Int)]
    }

    let nodes: [Node]

    func resolve(method: HTTPRequest.Method, path: String) -> RouteResolution {
        var current = 0
        var parameters: [String: Substring] = [:]
        for segment in Self.stripQuery(path).split(separator: "/", omittingEmptySubsequences: true) {
            let node = nodes[current]
            if let child = Self.literalChild(of: node, segment: String(segment)) {
                current = child
            } else if let edge = node.parameterChild {
                parameters[edge.name] = segment
                current = edge.child
            } else {
                return .notFound
            }
        }
        let routes = nodes[current].routes
        if let route = routes.first(where: { $0.method == method }) {
            return .matched(index: route.index, parameters: parameters)
        }
        // A node reached but carrying no routes is an *interior* node — `/users` when only
        // `/users/{id}` was registered. The path names nothing, so that is a 404, not "the wrong method
        // on a real resource". Only a node with routes can be a 405.
        guard !routes.isEmpty else { return .notFound }
        return .methodNotAllowed(allowed: Self.allowedMethods(of: routes))
    }

    /// The distinct methods registered at a node, in a stable order.
    ///
    /// The walk is greedy and does not backtrack — a literal child wins over the parameter edge and the
    /// search never returns — so these are the methods of the node the path actually reached, which is
    /// the same node a matching request would have been dispatched from. A future backtracking matcher
    /// would need to union across the candidates it abandoned.
    private static func allowedMethods(
        of routes: [(method: HTTPRequest.Method, index: Int)]
    )
        -> [HTTPRequest.Method]
    {
        var seen = Set<HTTPRequest.Method>()
        var allowed: [HTTPRequest.Method] = []
        for route in routes where seen.insert(route.method).inserted {
            allowed.append(route.method)
        }
        return allowed.sorted { $0.rawValue < $1.rawValue }
    }

    private static func literalChild(of node: Node, segment: String) -> Int? {
        var low = 0
        var high = node.literalChildren.count
        while low < high {
            let mid = (low + high) / 2
            let candidate = node.literalChildren[mid].segment
            if candidate == segment {
                return node.literalChildren[mid].child
            } else if candidate < segment {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return nil
    }

    private static func stripQuery(_ path: String) -> Substring {
        if let index = path.firstIndex(of: "?") { return path[..<index] }
        return path[...]
    }
}
