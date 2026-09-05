// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import HTTPTypes
import Testing

@testable import WireMVCRouter

/// The router's path-segment trie (`RouteTrie` → `FrozenRouteTrie`) tested without the proposal
/// server's request/response machinery. Pins the matching semantics: `{name}` parameters, query
/// stripping, segment-exact matching, **literal-before-parameter** precedence, first-registered-wins
/// per node, and binary-searched literal children after freeze. The further hardening —
/// 405-vs-404, full precedence, trailing-slash policy, catch-all params, duplicate-route
/// diagnostics — has since shipped and is pinned below; `Documentation/Notes/WireMVCRouter.md`
/// records what each decided.
/// Case accessors, so a `.matched` assertion reads the way it did when `resolve` returned an optional
/// tuple. Deliberately not on the production type: the three outcomes are the point of the enum, and
/// flattening them back into optionals in shipping code would invite exactly the collapse this replaced.
extension RouteInsertion {
    var index: Int? {
        if case let .inserted(index) = self { return index }
        return nil
    }
    var duplicateOf: String? {
        if case let .duplicate(existing) = self { return existing }
        return nil
    }
}

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
        let index = trie.insert(method: .get, path: "/health").index
        let match = trie.freeze().resolve(method: .get, path: "/health")
        #expect(match.index == index)
        #expect(match.parameters?.isEmpty == true)
    }

    @Test func pathParameterBinds() {
        var trie = RouteTrie()
        let index = trie.insert(method: .get, path: "/users/{id}").index
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
        let me = trie.insert(method: .get, path: "/users/me").index
        let byId = trie.insert(method: .get, path: "/users/{id}").index
        let frozen = trie.freeze()
        #expect(frozen.resolve(method: .get, path: "/users/me").index == me)
        let param = frozen.resolve(method: .get, path: "/users/42")
        #expect(param.index == byId)
        #expect(param.parameters?["id"].map(String.init) == "42")
    }

    @Test func distinctMethodsAtSameNodeDispatchSeparately() {
        var trie = RouteTrie()
        let get = trie.insert(method: .get, path: "/users/{id}").index
        let delete = trie.insert(method: .delete, path: "/users/{id}").index
        let frozen = trie.freeze()
        #expect(frozen.resolve(method: .get, path: "/users/9").index == get)
        #expect(frozen.resolve(method: .delete, path: "/users/9").index == delete)
    }

    @Test func binarySearchFindsAmongManyLiterals() {
        // Exercises the frozen node's sorted-array binary search across several literal siblings.
        var trie = RouteTrie()
        var indices: [String: Int] = [:]
        for name in ["alpha", "bravo", "charlie", "delta", "echo"] {
            indices[name] = trie.insert(method: .get, path: "/\(name)").index
        }
        let frozen = trie.freeze()
        #expect(frozen.resolve(method: .get, path: "/charlie").index == indices["charlie"])
        #expect(frozen.resolve(method: .get, path: "/echo").index == indices["echo"])
        #expect(frozen.resolve(method: .get, path: "/foxtrot") == .notFound)
    }

    // MARK: - Catch-all

    @Test func aCatchAllBindsTheRemainder() {
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/files/{path*}")
        let frozen = trie.freeze()
        #expect(frozen.resolve(method: .get, path: "/files/a").parameters?["path"].map(String.init) == "a")
        #expect(
            frozen.resolve(method: .get, path: "/files/a/b/c.css").parameters?["path"].map(String.init)
                == "a/b/c.css"
        )
    }

    @Test func literalAndParameterBothBeatACatchAll() {
        // Precedence is not coded — the catch-all is only consulted when the walk cannot advance, so
        // literal > parameter > catch-all falls out of the order the edges are tried in.
        var trie = RouteTrie()
        let catchAll = trie.insert(method: .get, path: "/files/{path*}").index
        let parameter = trie.insert(method: .get, path: "/files/{name}").index
        let literal = trie.insert(method: .get, path: "/files/readme").index
        let frozen = trie.freeze()
        #expect(frozen.resolve(method: .get, path: "/files/readme").index == literal)
        #expect(frozen.resolve(method: .get, path: "/files/other").index == parameter)
        #expect(frozen.resolve(method: .get, path: "/files/a/b").index == catchAll)
    }

    @Test func aCatchAllRemainderIsNotDecoded() {
        // Deliberate, and the one place this router does *not* decode. A single segment has no structure
        // to lose; a remainder spans separators, so decoding it would turn `%2F` into a real path boundary
        // — handed straight to whatever resolves it against a filesystem or a bucket.
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/files/{path*}")
        let match = trie.freeze().resolve(method: .get, path: "/files/a%2Fb/c")
        #expect(match.parameters?["path"].map(String.init) == "a%2Fb/c")
    }

    @Test func earlierParametersStillBindAlongsideACatchAll() {
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/u/{id}/files/{path*}")
        let match = trie.freeze().resolve(method: .get, path: "/u/9/files/a/b")
        #expect(match.parameters?["id"].map(String.init) == "9")
        #expect(match.parameters?["path"].map(String.init) == "a/b")
    }

    @Test func aCatchAllMatchesOneOrMoreSegments() {
        // Not zero: `/files` is a different resource, and a zero-length remainder pushes `""` handling
        // into every handler. Register `/files` as well if it should serve.
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/files/{path*}")
        #expect(trie.freeze().resolve(method: .get, path: "/files") == .notFound)
    }

    @Test func aCatchAllMustBeTheLastSegment() {
        // Anything after it can never match, so it is rejected rather than silently unreachable — the same
        // call RoutingKit makes.
        var trie = RouteTrie()
        #expect(trie.insert(method: .get, path: "/files/{path*}/edit") == .catchAllNotLast("{path*}"))
    }

    @Test func otherWildcardShapesAreStillRejected() {
        // Hummingbird's bare `*`, prefix and suffix forms have no meaning here, and read as ordinary
        // parameters if unchecked. Only the trailing catch-all is expressible.
        var trie = RouteTrie()
        #expect(trie.insert(method: .get, path: "/files/*") == .unsupportedSegment("*"))
        #expect(trie.insert(method: .get, path: "/files/**") == .unsupportedSegment("**"))
    }

    @Test func twoCatchAllsAtOneNodeAreADuplicate() {
        var trie = RouteTrie()
        #expect(trie.insert(method: .get, path: "/files/{path*}").index == 0)
        #expect(trie.insert(method: .get, path: "/files/{rest*}").duplicateOf == "/files/{path*}")
    }

    @Test func ordinaryParametersAreUnaffected() {
        var trie = RouteTrie()
        #expect(trie.insert(method: .get, path: "/files/{path}").index == 0)
        #expect(trie.insert(method: .post, path: "/a/{x}/b/{y}").index == 1)
    }

    // MARK: - Precedence and ordering

    /// Each route names the values it matched, however *it* spelled them.
    ///
    /// The node has one parameter edge, so a name stored on the edge would be whichever route registered
    /// first — and before this, `DELETE /users/{userId}` bound its value under `"id"`, silently. A
    /// `@Path userId` binding would look up `"userId"`, find nothing, and fail somewhere unrelated to the
    /// registration order that caused it.
    @Test func eachRouteNamesItsOwnParameters() {
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/users/{id}")
        _ = trie.insert(method: .delete, path: "/users/{userId}")
        let frozen = trie.freeze()
        #expect(frozen.resolve(method: .get, path: "/users/9").parameters?["id"].map(String.init) == "9")
        #expect(
            frozen.resolve(method: .delete, path: "/users/9").parameters?["userId"].map(String.init) == "9"
        )
    }

    /// The same, with the registration order reversed — which is the actual claim: the outcome does not
    /// depend on who registered first.
    @Test func parameterNamingIsIndependentOfRegistrationOrder() {
        var forward = RouteTrie()
        _ = forward.insert(method: .get, path: "/users/{id}")
        _ = forward.insert(method: .delete, path: "/users/{userId}")

        var reversed = RouteTrie()
        _ = reversed.insert(method: .delete, path: "/users/{userId}")
        _ = reversed.insert(method: .get, path: "/users/{id}")

        for frozen in [forward.freeze(), reversed.freeze()] {
            #expect(frozen.resolve(method: .get, path: "/users/9").parameters?.keys.sorted() == ["id"])
            #expect(
                frozen.resolve(method: .delete, path: "/users/9").parameters?.keys.sorted() == ["userId"]
            )
        }
    }

    /// Several parameters on one path keep their positions, so names cannot slide onto the wrong value.
    @Test func multipleParametersAreNamedPositionally() {
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/a/{x}/b/{y}")
        _ = trie.insert(method: .post, path: "/a/{first}/b/{second}")
        let frozen = trie.freeze()

        let get = frozen.resolve(method: .get, path: "/a/1/b/2")
        #expect(get.parameters?["x"].map(String.init) == "1")
        #expect(get.parameters?["y"].map(String.init) == "2")

        let post = frozen.resolve(method: .post, path: "/a/1/b/2")
        #expect(post.parameters?["first"].map(String.init) == "1")
        #expect(post.parameters?["second"].map(String.init) == "2")
    }

    /// Literal-beats-parameter was already order-independent — it is decided by structure, not by which
    /// route arrived first. Pinned both ways round so it stays that way.
    @Test func literalBeatsParameterWhicheverRegistersFirst() {
        var literalFirst = RouteTrie()
        let me1 = literalFirst.insert(method: .get, path: "/users/me").index
        _ = literalFirst.insert(method: .get, path: "/users/{id}")

        var parameterFirst = RouteTrie()
        _ = parameterFirst.insert(method: .get, path: "/users/{id}")
        let me2 = parameterFirst.insert(method: .get, path: "/users/me").index

        #expect(literalFirst.freeze().resolve(method: .get, path: "/users/me").index == me1)
        #expect(parameterFirst.freeze().resolve(method: .get, path: "/users/me").index == me2)
    }

    // MARK: - Duplicate routes

    @Test func registeringTheSameMethodAndPathTwiceIsADuplicate() {
        // Previously accepted in silence: `resolve` takes the first match, so the second registration was
        // unreachable and its controller's route was simply dead.
        var trie = RouteTrie()
        #expect(trie.insert(method: .get, path: "/users").index == 0)
        #expect(trie.insert(method: .get, path: "/users").duplicateOf == "/users")
    }

    @Test func differentMethodsOnOnePathAreNotDuplicates() {
        var trie = RouteTrie()
        #expect(trie.insert(method: .get, path: "/users").index == 0)
        #expect(trie.insert(method: .post, path: "/users").index == 1)
        #expect(trie.insert(method: .delete, path: "/users").index == 2)
    }

    /// The case a string comparison of templates would miss entirely.
    ///
    /// A node carries **one** parameter edge and the first name wins, so `/users/{id}` and
    /// `/users/{name}` are the same node — the second is unreachable however it is spelled. Reporting the
    /// template that claimed it is what turns "why is my route 404ing" into an answer.
    @Test func parameterNamesThatDifferOnlyInSpellingStillCollide() {
        var trie = RouteTrie()
        #expect(trie.insert(method: .get, path: "/users/{id}").index == 0)
        #expect(trie.insert(method: .get, path: "/users/{name}").duplicateOf == "/users/{id}")
    }

    @Test func aDuplicateConsumesNoRouteIndex() {
        // The rejected insert must not advance the index, or the trie and the handler array drift — the
        // thing the builder's other precondition exists to catch.
        var trie = RouteTrie()
        #expect(trie.insert(method: .get, path: "/a").index == 0)
        #expect(trie.insert(method: .get, path: "/a").duplicateOf != nil)
        #expect(trie.insert(method: .get, path: "/b").index == 1)
    }

    @Test func aRejectedDuplicateLeavesTheFirstRouteServing() {
        var trie = RouteTrie()
        let first = trie.insert(method: .get, path: "/users").index
        _ = trie.insert(method: .get, path: "/users")
        #expect(trie.freeze().resolve(method: .get, path: "/users").index == first)
    }

    @Test func distinctPathsSharingAPrefixAreNotDuplicates() {
        var trie = RouteTrie()
        #expect(trie.insert(method: .get, path: "/users/me").index == 0)
        #expect(trie.insert(method: .get, path: "/users/{id}").index == 1)
        #expect(trie.insert(method: .get, path: "/users").index == 2)
    }

    // MARK: - Percent-decoding

    @Test func aPercentEscapeInAParameterIsDecoded() {
        // The item this closes: before, a handler received `a%20b` and could not tell it had been given
        // undecoded input — the only router gap that produced a silently *wrong value* rather than a wrong
        // status or an absent feature.
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/users/{name}")
        let match = trie.freeze().resolve(method: .get, path: "/users/a%20b")
        #expect(match.parameters?["name"].map(String.init) == "a b")
    }

    @Test func anEncodedSlashStaysInsideOneParameter() {
        // Decoding runs *after* splitting on `/`, so `%2F` cannot reintroduce a path boundary: this is one
        // segment binding one parameter whose value happens to contain a slash.
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/files/{path}")
        let match = trie.freeze().resolve(method: .get, path: "/files/a%2Fb")
        #expect(match.parameters?["path"].map(String.init) == "a/b")
        #expect(match.parameters?.count == 1)
    }

    @Test func multiByteUTF8Decodes() {
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/greet/{word}")
        let match = trie.freeze().resolve(method: .get, path: "/greet/h%C3%A9llo")
        #expect(match.parameters?["word"].map(String.init) == "héllo")
    }

    @Test func lowerAndUpperCaseHexBothDecode() {
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/x/{v}")
        let frozen = trie.freeze()
        #expect(frozen.resolve(method: .get, path: "/x/%2f").parameters?["v"].map(String.init) == "/")
        #expect(frozen.resolve(method: .get, path: "/x/%2F").parameters?["v"].map(String.init) == "/")
    }

    @Test func plusIsNotASpaceInAPath() {
        // `+` means space in application/x-www-form-urlencoded, which is a *query* convention. In a path
        // segment it is an ordinary character, and translating it would corrupt any identifier with one.
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/users/{name}")
        let match = trie.freeze().resolve(method: .get, path: "/users/a+b")
        #expect(match.parameters?["name"].map(String.init) == "a+b")
    }

    @Test func malformedEscapesAreLeftAlone() {
        // Lenient, like Vapor's `removingPercentEncoding ?? $0`: a malformed URI stays a routing question
        // rather than becoming a 400 the router invented. A truncated escape at the end, a non-hex digit,
        // and a bare `%` all survive verbatim.
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/x/{v}")
        let frozen = trie.freeze()
        #expect(frozen.resolve(method: .get, path: "/x/a%").parameters?["v"].map(String.init) == "a%")
        #expect(frozen.resolve(method: .get, path: "/x/a%2").parameters?["v"].map(String.init) == "a%2")
        #expect(frozen.resolve(method: .get, path: "/x/a%zz").parameters?["v"].map(String.init) == "a%zz")
    }

    @Test func bytesThatAreNotUTF8LeaveTheSegmentRaw() {
        // `%FF` decodes to a byte that begins no valid UTF-8 sequence. Falling back to the raw segment is
        // deliberate: a corrupted identifier that still looks like a string — which `String(decoding:)`
        // would produce, with replacement characters — is worse than an undecoded one.
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/x/{v}")
        let match = trie.freeze().resolve(method: .get, path: "/x/%FF")
        #expect(match.parameters?["v"].map(String.init) == "%FF")
    }

    @Test func aSegmentWithoutEscapesIsUntouched() {
        // The fast path: no `%`, so no allocation and no copy — the parameter is still a slice of the
        // request path.
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/users/{id}")
        let match = trie.freeze().resolve(method: .get, path: "/users/42")
        #expect(match.parameters?["id"].map(String.init) == "42")
    }

    // MARK: - Segment walking

    @Test func repeatedSeparatorsCollapseToOneSegment() {
        // The walk skips runs of "/" where `split(omittingEmptySubsequences:)` dropped the empty
        // subsequences it would otherwise have produced. Untested while it was `split`'s parameter — it
        // was the library's behaviour to get right, and is now this router's. Without it an empty segment
        // becomes a node the trie has no edge for, and every one of these is a 404.
        var trie = RouteTrie()
        let index = trie.insert(method: .get, path: "/a/b").index
        let frozen = trie.freeze()
        #expect(frozen.resolve(method: .get, path: "//a/b").index == index)
        #expect(frozen.resolve(method: .get, path: "/a//b").index == index)
        #expect(frozen.resolve(method: .get, path: "/a/b//").index == index)
    }

    @Test func aParameterBindsAcrossRepeatedSeparators() {
        // The same collapse, but on the edge that binds: the value must be the segment, not an empty
        // string picked up from the run of separators before it.
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/users/{id}")
        let match = trie.freeze().resolve(method: .get, path: "/users//42")
        #expect(match.parameters?["id"].map(String.init) == "42")
    }

    @Test func aCatchAllRemainderStartsAtTheSegmentItClaims() {
        // The remainder is rebuilt as `path[segment.startIndex...]`, so it is a slice of the request path
        // rather than of anything the walk produced. Pins that the walk's segments keep indices into the
        // original — a segment copied out of a materialised array would make this remainder wrong.
        var trie = RouteTrie()
        let index = trie.insert(method: .get, path: "/files/{path*}").index
        let match = trie.freeze().resolve(method: .get, path: "/files/a/b/c")
        #expect(match.index == index)
        #expect(match.parameters?["path"].map(String.init) == "a/b/c")
    }

    // MARK: - Trailing-slash policy

    @Test func lenientTreatsATrailingSlashAsTheSameResource() {
        // The default, and what both Hummingbird and Vapor do. Previously this fell out of omitting empty
        // segments rather than being chosen.
        var trie = RouteTrie()
        let index = trie.insert(method: .get, path: "/users").index
        #expect(trie.freeze(trailingSlash: .lenient).resolve(method: .get, path: "/users/").index == index)
    }

    @Test func strictRejectsATrailingSlash() {
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/users")
        let frozen = trie.freeze(trailingSlash: .strict)
        #expect(frozen.resolve(method: .get, path: "/users").index == 0)
        #expect(frozen.resolve(method: .get, path: "/users/") == .notFound)
    }

    @Test func strictStillServesTheRoot() {
        // `/` is the root, not a trailing slash on something — there is no shorter form to prefer, and
        // rejecting it would make the root unreachable.
        var trie = RouteTrie()
        let index = trie.insert(method: .get, path: "/").index
        #expect(trie.freeze(trailingSlash: .strict).resolve(method: .get, path: "/").index == index)
    }

    @Test func strictAppliesBeforeTheQueryIsConsidered() {
        // The slash is judged on the path, not on the raw target: `/users/?x=1` has a trailing slash and
        // `/users?x=1` does not.
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/users")
        let frozen = trie.freeze(trailingSlash: .strict)
        #expect(frozen.resolve(method: .get, path: "/users?x=1").index == 0)
        #expect(frozen.resolve(method: .get, path: "/users/?x=1") == .notFound)
    }

    @Test func aTemplateWrittenWithATrailingSlashNormalises() {
        // Registration splits the same way, so `/users/` and `/users` are one node. Under `.strict` the
        // canonical request form is therefore always slash-free, whichever way the route was written —
        // which is why the policy governs requests only.
        var trie = RouteTrie()
        #expect(trie.insert(method: .get, path: "/users/").index == 0)
        #expect(trie.insert(method: .get, path: "/users").duplicateOf == "/users/")
    }

    @Test func strictDoesNotAffectAnUnmatchedPath() {
        var trie = RouteTrie()
        _ = trie.insert(method: .get, path: "/users")
        #expect(trie.freeze(trailingSlash: .strict).resolve(method: .get, path: "/nope") == .notFound)
    }
}
