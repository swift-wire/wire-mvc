import HTTPTypes
import Testing

@testable import WireMVCRouter

/// The router's path-segment trie (`RouteTrie` → `FrozenRouteTrie`) tested without the proposal
/// server's request/response machinery. Pins the matching semantics: `{name}` parameters, query
/// stripping, segment-exact matching, **literal-before-parameter** precedence, first-registered-wins
/// per node, and binary-searched literal children after freeze. Further hardening (405-vs-404,
/// full precedence, trailing-slash policy, catch-all) is tracked in Documentation/Notes/WireMVCRouter.md.
/// 405-vs-404 has since shipped and is pinned below.
/// Case accessors, so a `.matched` assertion reads the way it did when `resolve` returned an optional
/// tuple. Deliberately not on the production type: the three outcomes are the point of the enum, and
/// flattening them back into optionals in shipping code would invite exactly the collapse this replaced.
extension RouteResolution {
    var index: Int? {
        if case let .matched(index, _) = self { return index }
        return nil
    }
    var parameters: [String: Substring]? {
        if case let .matched(_, parameters) = self { return parameters }
        return nil
    }
    var allowed: [HTTPRequest.Method]? {
        if case let .methodNotAllowed(allowed) = self { return allowed }
        return nil
    }
}

@Suite("RouteTrie — segment-trie matching")
struct RouteTrieTests {

    @Test func literalMatchBindsNoParameters() {
        var trie = RouteTrie()
        let index = trie.insert(method: .get, path: "/health")
        let match = trie.freeze().resolve(method: .get, path: "/health")
        #expect(match.index == index)
        #expect(match.parameters?.isEmpty == true)
    }

    @Test func pathParameterBinds() {
        var trie = RouteTrie()
        let index = trie.insert(method: .get, path: "/users/{id}")
        let match = trie.freeze().resolve(method: .get, path: "/users/42")
        #expect(match.index == index)
        #expect(match.parameters?["id"].map(String.init) == "42")
    }

    @Test func multipleParametersBind() {
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/a/{x}/b/{y}")
        let match = trie.freeze().resolve(method: .get, path: "/a/1/b/2")
        #expect(match.parameters?["x"].map(String.init) == "1")
        #expect(match.parameters?["y"].map(String.init) == "2")
    }

    @Test func noMatchReturnsNil() {
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/users/{id}")
        #expect(trie.freeze().resolve(method: .get, path: "/posts/1") == .notFound)
    }

    @Test func methodMismatchIsMethodNotAllowed() {
        // The path exists; the method does not. Previously indistinguishable from "no such path", which
        // told a client its URL was wrong when its URL was right.
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/users")
        #expect(trie.freeze().resolve(method: .post, path: "/users") == .methodNotAllowed(allowed: [.get]))
    }

    @Test func allowedMethodsAreDeduplicatedAndSorted() {
        // Two routes share the node under one method, and three methods are registered in a deliberately
        // unsorted order — the header must not depend on registration order, or on how many routes
        // happen to sit behind a method.
        var trie = RouteTrie()
        _ = trie.insert(method: .post, path: "/users")
        _ = trie.insert(method: .get, path: "/users")
        _ = trie.insert(method: .delete, path: "/users")
        #expect(trie.freeze().resolve(method: .put, path: "/users").allowed == [.delete, .get, .post])
    }

    @Test func anInteriorNodeIsNotFoundRatherThanMethodNotAllowed() {
        // `/users` is only a waypoint to `/users/{id}` — it carries no routes, so it names no resource
        // and there is nothing to report as allowed. A 405 here would claim a resource exists.
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/users/{id}")
        #expect(trie.freeze().resolve(method: .post, path: "/users") == .notFound)
    }

    @Test func methodNotAllowedIsReportedForTheNodeActuallyReached() {
        // The walk is greedy: `/users/me` takes the literal edge, so the allowed set is `me`'s, not the
        // union with `{id}`'s. Pinning it makes the no-backtracking semantics explicit rather than
        // incidental — a backtracking matcher would have to union across abandoned candidates.
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/users/me")
        _ = trie.insert(method: .delete, path: "/users/{id}")
        #expect(trie.freeze().resolve(method: .delete, path: "/users/me") == .methodNotAllowed(allowed: [.get]))
    }

    @Test func prefixWithoutRouteReturnsNil() {
        // "/users/{id}" registers a route at the {id} node, not the /users node — so GET /users has
        // no route and misses (segment-exact matching).
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/users/{id}")
        #expect(trie.freeze().resolve(method: .get, path: "/users") == .notFound)
    }

    @Test func queryStringIsIgnored() {
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/users/{id}")
        let match = trie.freeze().resolve(method: .get, path: "/users/42?trace=abc")
        #expect(match.parameters?["id"].map(String.init) == "42")
    }

    @Test func literalBeatsParameter() {
        // Static-before-param precedence: /users/me matches the literal even though /users/{id} exists.
        var trie = RouteTrie()
        let me = trie.insert(method: .get, path: "/users/me")
        let byId = trie.insert(method: .get, path: "/users/{id}")
        let frozen = trie.freeze()
        #expect(frozen.resolve(method: .get, path: "/users/me").index == me)
        let param = frozen.resolve(method: .get, path: "/users/42")
        #expect(param.index == byId)
        #expect(param.parameters?["id"].map(String.init) == "42")
    }

    @Test func distinctMethodsAtSameNodeDispatchSeparately() {
        var trie = RouteTrie()
        let get = trie.insert(method: .get, path: "/users/{id}")
        let delete = trie.insert(method: .delete, path: "/users/{id}")
        let frozen = trie.freeze()
        #expect(frozen.resolve(method: .get, path: "/users/9").index == get)
        #expect(frozen.resolve(method: .delete, path: "/users/9").index == delete)
    }

    @Test func binarySearchFindsAmongManyLiterals() {
        // Exercises the frozen node's sorted-array binary search across several literal siblings.
        var trie = RouteTrie()
        var indices: [String: Int] = [:]
        for name in ["alpha", "bravo", "charlie", "delta", "echo"] {
            indices[name] = trie.insert(method: .get, path: "/\(name)")
        }
        let frozen = trie.freeze()
        #expect(frozen.resolve(method: .get, path: "/charlie").index == indices["charlie"])
        #expect(frozen.resolve(method: .get, path: "/echo").index == indices["echo"])
        #expect(frozen.resolve(method: .get, path: "/foxtrot") == .notFound)
    }

    @Test func trailingSlashMatchesInV1() {
        // v1: empty path segments are omitted, so "/users/" and "/users" are equivalent. A
        // trailing-slash *policy* is a tracked hardening item.
        var trie = RouteTrie()
        let index = trie.insert(method: .get, path: "/users")
        #expect(trie.freeze().resolve(method: .get, path: "/users/").index == index)
    }
}
