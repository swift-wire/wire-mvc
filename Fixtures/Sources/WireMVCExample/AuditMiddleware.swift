import Synchronization
import Wire
import WireMVC

/// A global probe the audit middleware bumps, so the self-test can observe it ran.
let auditProbe = Atomic<Int>(0)

/// A concrete dependency the audit middleware injects — an ordinary Wire binding.
@Singleton
struct AuditLog: Sendable {
    func record() { auditProbe.add(1, ordering: .relaxed) }
}

/// Factory-key namespace for the audit middleware.
enum AuditMiddlewareKeys {
    static let factory = FactoryKey()
}

/// A generic-with-deps middleware whose box-role parameters are declared in a **non-canonical order** —
/// `<Sender, Reader, Ctx>` rather than `<Ctx, Reader, Sender>`. `@MiddlewareFactory(.responseSender,
/// .reader, .requestContext)` maps them positionally so the plugin still orders the synthesised `create`
/// to the canonical triple the `@Controller` witness calls with. Exercises the 3.2 role-mapping reorder
/// path end-to-end; behaviourally it's a dep-carrying observer that counts each request and passes the
/// box through.
@Factory(AuditMiddlewareKeys.factory)
@MiddlewareFactory(.responseSender, .reader, .requestContext)
struct AuditMiddleware<
    Sender: HTTPResponseSender & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Ctx: HTTPServerCapability.RequestContext & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    @Inject var log: AuditLog

    typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    typealias NextInput = Input

    func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        log.record()
        return try await next(input)
    }
}
