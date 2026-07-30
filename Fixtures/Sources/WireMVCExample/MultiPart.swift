import AsyncStreaming
import BasicContainers
import HTTPAPIs
import HTTPTypes
import Wire
import WireMVC

// M5.4R — a `@RawRoute(.responseSender)` handler whose sender type is *transformed* by a middleware. The
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
        try await input.withContents(
            pending: { request, requestContext, reader, responseSender in
                try await next(
                    .pending(
                        request: request,
                        requestContext: requestContext,
                        reader: reader,
                        responseSender: MultiPartSender(wrapping: responseSender)
                    )
                )
            },
            responded: { request in
                try await next(.responded(request: request))
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
