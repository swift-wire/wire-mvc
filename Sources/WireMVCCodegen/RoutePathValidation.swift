// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

import SwiftSyntax

// Route-template validation that is knowable from the template text alone, kept out of `RouteCodegen` so
// that file's length stays about route *generation*.

extension RouteBlockGenerator {
    /// Record a diagnostic if `path` uses a wildcard shape no route template expresses, and report
    /// whether it did.
    ///
    /// The trailing catch-all `{name*}` is **not** diagnosed here: it is a supported template, and whether
    /// a controller can use one depends on the runtime it is served on — which codegen cannot know, since
    /// a controller in a shared package does not know its host. The native router supports it; the
    /// `ServerTransport` bridge refuses it at registration, where the runtime *is* known.
    ///
    /// What is diagnosed is the shapes that are never expressible anywhere: a bare `*`, and Hummingbird's
    /// prefix/suffix forms. Left unchecked they read as ordinary parameters, which is a mis-route rather
    /// than an error. So is a catch-all that is not the last segment, since everything after it is
    /// unreachable.
    mutating func recordWildcardSegment(in path: String, at token: TokenSyntax) -> Bool {
        if let misplaced = Self.misplacedCatchAll(in: path) {
            record(RouteCodegenDiagnostic(.catchAllNotLastSegment(path: path, segment: misplaced), at: token))
            return true
        }
        guard let wildcard = Self.wildcardSegment(in: path) else { return false }
        // `record` rather than appending: the storage keeps its `private(set)` setter, and this is the
        // one way in.
        record(RouteCodegenDiagnostic(.wildcardPathSegment(path: path, segment: wildcard), at: token))
        return true
    }

    /// The first wildcard segment that is *not* the supported trailing catch-all, or `nil`.
    ///
    /// Recognises the neighbours' spellings — a bare `*`, and `**` — so someone arriving from Hummingbird
    /// or Vapor meets the diagnostic rather than a mis-route.
    static func wildcardSegment(in path: String) -> String? {
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            if segment == "*" || segment == "**" { return String(segment) }
        }
        return nil
    }

    /// A `{name*}` that is not the final segment, or `nil` — everything after one is unreachable.
    static func misplacedCatchAll(in path: String) -> String? {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        return segments.dropLast()
            .first { $0.hasPrefix("{") && $0.hasSuffix("}") && $0.dropLast().hasSuffix("*") }
            .map(String.init)
    }
}
