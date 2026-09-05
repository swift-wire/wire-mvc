// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

public import HTTPTypes

/// How a ``CORSMiddleware`` answers.
///
/// The knobs are the ones Hummingbird and Vapor both settled on, with two departures: methods and header
/// names are **typed** rather than pre-joined strings (WireMVC is already typed on those, and
/// `@ResponseHeader(.cacheControl, …)` deliberately avoided stringly-typed fields), and `maxAge` is a
/// `Duration`.
///
/// `Vary: Origin` is deliberately **not** a knob. It is derived from ``allowOrigin``, because a policy that
/// varies by origin and a response that does not advertise it poisons shared caches, and there is no sane
/// reason to want it off.
public struct CORSConfiguration: Sendable {
    /// What `Access-Control-Allow-Origin` answers with. The superset of the two frameworks' enums.
    public enum AllowOrigin: Sendable, Equatable {
        /// Send no origin at all.
        case none
        /// `*` — every origin. Cannot be combined with ``allowCredentials``.
        case all
        /// Echo the request's own `Origin`, so any origin is allowed but each response names one.
        case originBased
        /// Echo the request's `Origin` when it is in this list, else send none.
        case oneOf([String])
        /// A fixed origin.
        case custom(String)

        /// Whether the answer depends on the request's `Origin`, and therefore whether the response must
        /// say so in `Vary`.
        var variesByRequestOrigin: Bool {
            switch self {
            case .originBased, .oneOf: true
            case .none, .all, .custom: false
            }
        }

        /// The value to send for a request carrying `origin`, or `nil` to send the field at all.
        func value(for origin: String?) -> String? {
            switch self {
            case .none: nil
            case .all: "*"
            case .originBased: origin
            case .oneOf(let allowed): origin.flatMap { allowed.contains($0) ? $0 : nil }
            case .custom(let value): value
            }
        }
    }

    public let allowOrigin: AllowOrigin
    public let allowMethods: [HTTPRequest.Method]
    public let allowHeaders: [HTTPField.Name]
    public let allowCredentials: Bool
    public let exposedHeaders: [HTTPField.Name]
    public let maxAge: Duration?

    /// - Precondition: `allowCredentials` and `.all` are mutually exclusive.
    ///
    ///   `Access-Control-Allow-Origin: *` with `Access-Control-Allow-Credentials: true` is forbidden by the
    ///   Fetch standard, and a browser rejects the response rather than reporting anything useful — the
    ///   request simply fails, which is miserable to debug. Neither Hummingbird nor Vapor prevents the
    ///   combination; shipping this middleware means owning that, so it traps at construction where the
    ///   mistake is. Use `.originBased` to allow any origin *with* credentials: it echoes one origin per
    ///   response, which is what the standard requires.
    public init(
        allowOrigin: AllowOrigin = .originBased,
        allowMethods: [HTTPRequest.Method] = [.get, .post, .head, .options],
        allowHeaders: [HTTPField.Name] = [.accept, .authorization, .contentType, .origin],
        allowCredentials: Bool = false,
        exposedHeaders: [HTTPField.Name] = [],
        maxAge: Duration? = nil
    ) {
        precondition(
            !(allowCredentials && allowOrigin == .all),
            "CORS: allowCredentials cannot be combined with .all — the Fetch standard forbids "
                + "`Access-Control-Allow-Origin: *` alongside credentials, and browsers reject the response. "
                + "Use .originBased to allow any origin with credentials."
        )
        self.allowOrigin = allowOrigin
        self.allowMethods = allowMethods
        self.allowHeaders = allowHeaders
        self.allowCredentials = allowCredentials
        self.exposedHeaders = exposedHeaders
        self.maxAge = maxAge
    }
}
