// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

import AsyncStreaming
import BasicContainers
import HTTPAPIs
import HTTPTypes
import Wire
import WireMVC

// A `@RawRoute(.responseSender)` handler whose sender type is *transformed* by a middleware. The
// middleware wraps the real response sender in a `MultiPartSender<S>`; the raw handler receives that
// concrete-wrapped type (which constraint inference can't name) and calls its richer `sendParts` API.
// Removing the middleware makes the handler's parameter type unsatisfiable — the compile-time coupling.

/// A transformed response sender — wraps the real sender `S` and grants the handler a `sendParts` API that
/// frames a `multipart/mixed` body. It reuses the wrapped writer (the framing is assembled and written in
/// one call), so no custom `Writer` is needed. `~Copyable`, like every response sender.
struct MultiPartSender<Wrapped: HTTPResponseSender & ~Copyable>: HTTPResponseSender, ~Copyable
where Wrapped.Writer: ~Copyable {
    typealias Writer = Wrapped.Writer
    var wrapped: Wrapped

    init(wrapping wrapped: consuming Wrapped) { self.wrapped = wrapped }

    mutating func sendInformational(_ response: HTTPResponse) async throws {
        try await wrapped.sendInformational(response)
    }

    consuming func send(_ response: HTTPResponse) async throws -> Wrapped.Writer {
        try await wrapped.send(response)
    }

    /// The richer API the sender-transform grants the raw handler: assemble the parts into a
    /// `multipart/mixed` body and send it in one call.
    consuming func sendParts(_ parts: [(name: String, body: String)]) async throws {
        let boundary = "wireboundary"
        var text = ""
        for part in parts {
            text += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(part.name)\"\r\n\r\n\(part.body)\r\n"
        }
        text += "--\(boundary)--\r\n"
        var fields = HTTPFields()
        fields[.contentType] = "multipart/mixed; boundary=\(boundary)"
        var buffer = UniqueArray<UInt8>(copying: Array(text.utf8))
        try await wrapped.sendAndFinish(HTTPResponse(status: .ok, headerFields: fields), buffer: &buffer, trailer: nil)
    }
}

/// Factory-key namespace for the sender-transforming middleware.
enum MultiPartMiddlewareKeys {
    static let factory = FactoryKey()
}

/// A **sender-transforming** middleware: `Box<Ctx, R, S>` → `Box<Ctx, R, MultiPartSender<S>>`. It wraps the
/// response sender so the downstream `@RawRoute(.responseSender)` handler receives a `MultiPartSender<S>`.
@Factory(MultiPartMiddlewareKeys.factory)
@MiddlewareFactory  // bare → positional: <Ctx, Reader, Sender> map to the roles in order (canonical)
struct MultiPartMiddleware<
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Sender: HTTPResponseSender & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    typealias NextInput = RequestResponseMiddlewareBox<Ctx, Reader, MultiPartSender<Sender>>

    func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        // The registry and the route come out of the `pending` destructure and are threaded into the
        // rebuilt box. Both are required parameters precisely so this can't be forgotten: a rebuild that
        // dropped the registry would discard every header field contributed upstream, and one that dropped
        // the route would unname the route for everything further in — silently, and only at runtime.
        // Taking the registry from the destructure rather than off the box beforehand is also what keeps it
        // disconnected — a captured local would be task-isolated, and the rebuilt box could not then be
        // handed on.
        return try await input.withContents(
            pending: { request, requestContext, route, reader, responseSender, responseHeaders in
                try await next(
                    .pending(
                        request: request,
                        requestContext: requestContext,
                        route: route,
                        reader: reader,
                        responseSender: MultiPartSender(wrapping: responseSender),
                        responseHeaders: responseHeaders
                    )
                )
            },
            responded: { request, route in
                // The registry is the one thing not threaded: a `responded` box carries none, because the
                // response is already written and nothing would ever drain one. The route is, for the same
                // reason the request is — an observer further in still wants to know what was gated.
                try await next(.responded(request: request, route: route))
            }
        )
    }
}

/// A controller with one raw route whose sender is transformed by `MultiPartMiddleware`. Isolated from
/// `UsersController` so the transform is the only middleware in the fold.
@Singleton
@Controller("/uploads")
struct UploadsController: Sendable {
    @Get("/parts")
    @RawRoute(.responseSender)  // bind the (transformed) sender by role — its type isn't inferable
    @Middleware(MultiPartMiddlewareKeys.factory)  // route-scope: wraps the sender into MultiPartSender<S>
    func parts<Sender: HTTPResponseSender & ~Copyable & SendableMetatype>(
        responseSender: consuming MultiPartSender<Sender>
    ) async throws where Sender.Writer: ~Copyable {
        try await responseSender.sendParts([("greeting", "hello"), ("name", "wire")])
    }
}
