import Wire
import WireMVC

// M5.5 Phase 2 — the terminal owns the 500. `boom` throws an *unmapped* error: `Boom` is not a
// `WireMVCBindingError`, and this controller declares no `@ErrorResponse`, so it falls through the
// terminal's catch chain to the built-in 500. Before Phase 2 an unmapped throw was re-thrown out of the
// chain and the proposal server aborted the connection (no HTTP response); now the terminal writes a
// clean `500`.

@Singleton
@Controller("/boom")
struct BoomController {
    struct Boom: Error {}

    @Get
    @JSONResponse
    func boom() throws -> BoomResponse {
        throw Boom()
    }
}

struct BoomResponse: Codable, Sendable {
    let ok: Bool
}
