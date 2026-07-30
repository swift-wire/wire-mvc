import BasicContainers
import HTTPAPIs
import HTTPTypes
import Wire
import WireMVC

// A WireMVC controller in its natural declarative shape. `@Singleton` makes it a graph
// binding; `@Controller` walks these routes and generates the `RouteContributor` witness
// (the extension is macro-generated), and its `@Contributes` alias collates the controller so
// `Wire.bootstrap()` + `WireMVC.router` register its routes onto the server.
@Singleton
@Controller("/users")
@Middleware(RequestLogMiddlewareKeys.factory)  // controller-scope, generic dep-free
@Middleware(SessionMiddlewareKeys.factory)  // controller-scope, generic-with-deps (factory-lifted by key)
@Middleware(AuditMiddlewareKeys.factory)  // controller-scope, generic-with-deps, non-canonical parameter order
// controller-scope @ErrorResponse: a thrown UserStore.NotFound → 404 + JSON body. An inline
// typed-parameter closure — folded into the generated terminal's `catch`, called when a route throws
// `UserStore.NotFound` (e.g. `getUser`'s `try store.find(id)` for an unknown id, which returned 500
// before M5.4E).
@ErrorResponse({ (_: UserStore.NotFound) in try .json(APIError(message: "user not found"), status: .notFound) })
struct UsersController: Sendable {
    @Inject var store: UserStore

    @Get("/{id}")
    @JSONResponse
    func getUser(@Path id: String) async throws -> User {
        try store.find(id)
    }

    @Post
    @JSONResponse(status: .created)
    func create(@JSONBody new: NewUser) async throws -> User {
        store.create(new)
    }

    @Delete("/{id}")
    @ResponseStatus(.noContent)
    @Middleware(RequireAdminKeys.factory)  // route-scope gate
    func delete(@Path id: String) async throws {
        store.delete(id)
    }

    @Get
    @JSONResponse
    func list(
        @Query limit: Int = 10,  // defaulted @Query
        @Query cursor: String?,  // optional @Query
        @Header("x-trace") trace: String?  // optional @Header
    ) async throws -> Listing {
        Listing(limit: limit, cursor: cursor, trace: trace, users: store.list(limit: limit))
    }

    // A raw (streaming) route: `@RawRoute` hands the handler the response sender verbatim — no decode,
    // no encode — and it writes the response itself. Generic over the sender (the builder's associated
    // type); takes only the sender it needs. The sender is `consuming` (not `consuming sending`) so the
    // handler can also be reached through a middleware fold, where it arrives from the box's
    // `withContents` as a plain `consuming` value.
    @Get("/events/stream")
    @RawRoute
    func events<Sender: HTTPResponseSender & ~Copyable & SendableMetatype>(
        responseSender: consuming Sender
    ) async throws where Sender.Writer: ~Copyable {
        var body = UniqueArray<UInt8>(copying: Array("data: hello\n\n".utf8))
        try await responseSender.sendAndFinish(HTTPResponse(status: .ok), buffer: &body)
    }
}
