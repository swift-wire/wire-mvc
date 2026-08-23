public import HTTPTypes

/// Where a **middleware** contributes response header fields. It rides the middleware box, so a middleware
/// reaches it off its `Input` before calling `next`; the route terminal drains it when it builds the
/// ``WireMVCOutcome``.
///
/// ## Why registration, not mutation after `next`
///
/// A middleware cannot set a header after `next` returns. The terminal writes the response *during* `next`
/// — that is forced by the proposal's `Middleware.intercept<Return>` shape, where the only value of type
/// `Return` is what `next` produces, so the response can only ever be a sender side-effect (see
/// Notes/WireMVCMiddleware.md, *Short-circuit & the box shape*). By the time an outer middleware resumes,
/// the bytes are gone.
///
/// So a contribution is **registered on the way in and evaluated on the way out**. ``add(_:)`` is for a
/// value the middleware already has; ``onSend(_:)`` is for one it cannot know yet — a session cookie
/// depends on what the *handler* did to the session, so the closure runs at drain time, after the handler
/// and before the response head exists. This is ASP.NET Core's `HttpResponse.OnStarting` shape, and it
/// exists for the same reason: headers stop being writable once the body starts.
///
/// ## Ordering
///
/// Drain applies **registration calls in reverse**, so the outermost middleware — which registers first,
/// on the way in — applies last and wins. That matches what a wrap-style stack does naturally
/// (Hummingbird and Vapor middleware mutate the response on the way out, outermost last), and it means a
/// policy header set at the app edge is not overridable by something nested inside it.
///
/// Order *within* one call is preserved: an `onSend` returning several contributions applies them in the
/// order it listed them. Only the calls are reversed, so a middleware never sees its own contributions
/// come out backwards.
///
/// Deliberately **not** `Sendable`, exactly as the box isn't: one request's registry is written by that
/// request's middleware and drained by its terminal, all in one region.
public final class ResponseHeaderRegistry {
    /// One registration, kept unevaluated so a deferred contributor runs at drain rather than at
    /// registration. A plain `add` is stored as an already-known list to keep one ordered sequence of
    /// calls — the thing the reverse applies to.
    private enum Registration {
        /// One contribution, stored inline. The overwhelmingly common shape — every contributor in this
        /// package and every one written against it so far adds a single field per call — and the case
        /// that keeps a registration off the heap entirely.
        case value(ResponseHeaderContribution)
        case values([ResponseHeaderContribution])
        case deferred(() async throws -> [ResponseHeaderContribution])
    }

    /// Registrations, the first ``inlineCapacity`` of them **without touching the heap**.
    ///
    /// A `[Registration]` grows on the first `add`, so a route with one contributing middleware paid an
    /// allocation for a single element. Almost every request registers a handful at most — a CORS header,
    /// a cache policy, a trace id — so the common case fits inline and the array is only built when it
    /// genuinely overflows.
    private static let inlineCapacity = 4
    private var inline: InlineArray<4, Registration?> = .init(repeating: nil)
    private var inlineCount = 0
    private var overflow: [Registration] = []

    private func append(_ registration: Registration) {
        if inlineCount < Self.inlineCapacity {
            inline[inlineCount] = registration
            inlineCount += 1
        } else {
            overflow.append(registration)
        }
    }

    /// The registration at `index` counting **backwards** from the newest — the order drain applies them
    /// in. Walking by index rather than materialising a reversed list keeps the inline storage inline;
    /// building an `Array` to reverse would give back the allocation this exists to avoid.
    private var registrationCount: Int { inlineCount + overflow.count }

    private func registration(fromNewest index: Int) -> Registration? {
        let forward = registrationCount - 1 - index
        if forward < inlineCount { return inline[forward] }
        return overflow[forward - inlineCount]
    }

    public init() {}

    /// Contribute one field the middleware already knows.
    ///
    /// Separate from the variadic overload rather than folded into it, because a variadic parameter builds
    /// an `Array` at the call site whatever it is passed: `add(.set(name, value))` allocated one array for
    /// the argument and boxed it into `.values`, two allocations to carry a single field. Swift prefers
    /// this overload for a one-argument call, so every existing caller gets it without changing.
    public func add(_ contribution: ResponseHeaderContribution) {
        append(.value(contribution))
    }

    /// Contribute several fields at once.
    public func add(_ contributions: ResponseHeaderContribution...) {
        append(.values(contributions))
    }

    /// Contribute fields that cannot be known until the handler has run — a session cookie, an ETag
    /// computed from what was written. The closure runs once, at drain, inside the terminal's `do`, so a
    /// throw from it maps through `@ErrorResponse` like any other route error.
    public func onSend(_ contribute: @escaping () async throws -> [ResponseHeaderContribution]) {
        append(.deferred(contribute))
    }

    /// Evaluate every registration straight into `fields`, outermost last — the same order ``drain()``
    /// produces, without the array in between.
    ///
    /// Every caller of ``drain()`` immediately iterates what it returns and applies each element, so the
    /// returned array exists only to cross a function boundary. This applies as it walks.
    public func drain(into fields: inout HTTPFields) async throws {
        for index in 0..<registrationCount {
            guard let registration = registration(fromNewest: index) else { continue }
            switch registration {
            case let .value(value):
                WireMVCResponseHeaders.apply(value, to: &fields)
            case let .values(values):
                for value in values { WireMVCResponseHeaders.apply(value, to: &fields) }
            case let .deferred(contribute):
                for value in try await contribute() { WireMVCResponseHeaders.apply(value, to: &fields) }
            }
        }
    }

    /// Evaluate every registration, outermost last. Called by the route terminal (and by
    /// ``RequestResponseMiddlewareBox/respondingWith(_:)`` on the gate path) — not by user code.
    public func drain() async throws -> [ResponseHeaderContribution] {
        var contributions: [ResponseHeaderContribution] = []
        for index in 0..<registrationCount {
            guard let registration = registration(fromNewest: index) else { continue }
            switch registration {
            case let .value(value): contributions.append(value)
            case let .values(values): contributions.append(contentsOf: values)
            case let .deferred(contribute): contributions.append(contentsOf: try await contribute())
            }
        }
        return contributions
    }
}
