// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

public import WireMVC

/// Why ``DroppedBoxGuard`` refused: it has no other reason to exist.
public struct DroppedBoxRefusal: Error {}

/// A link-time regression guard, not a route's middleware: nothing applies it. It throws before calling
/// `next`, so it drops the box — destroys it here, in a module other than WireMVC — which is the shape
/// that failed to link in an optimised build while the box's internal storage was not exported
/// (wire-mvc#251). Debug builds export internal symbols for testing, so only the CI job's release build
/// of this package exercises it; a regression fails that build's link rather than any test.
///
/// Public, in a library that `ReleaseLinkCheck` links, because that is the shape that reaches the
/// linker: an internal type nothing uses is removed by the optimiser before its code is emitted, and a
/// library nothing links is never linked at all.
public struct DroppedBoxGuard<
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Sender: HTTPResponseSender & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    public typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    public typealias NextInput = Input

    public let refuse: Bool

    public init(refuse: Bool) {
        self.refuse = refuse
    }

    public func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        if refuse { throw DroppedBoxRefusal() }
        return try await next(input)
    }
}
