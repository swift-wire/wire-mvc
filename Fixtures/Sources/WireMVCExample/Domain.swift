import Wire

struct User: Codable, Sendable, Equatable {
    let id: String
    let name: String
}

struct NewUser: Codable, Sendable {
    let name: String
}

/// The JSON body an `@ErrorResponse` mapping encodes for a domain failure — so the example can assert a
/// mapped error carries a real (decoded) body, not just a status.
struct APIError: Codable, Sendable, Equatable {
    let message: String
}

/// Echoes the bound query/header values back, so the example can assert they were actually
/// received (not just that their absence is tolerated).
struct Listing: Codable, Sendable, Equatable {
    let limit: Int
    let cursor: String?
    let trace: String?
    let users: [User]
}

/// Wire constructs this `@Singleton` and injects it into the controller. Canned so the
/// example stays focused on routing/codegen, not state.
@Singleton
struct UserStore: Sendable {
    struct NotFound: Error {}

    @Inject init() {}

    func find(_ id: String) throws -> User {
        guard id == "42" else { throw NotFound() }
        return User(id: id, name: "Ada")
    }

    func create(_ new: NewUser) -> User { User(id: "99", name: new.name) }
    func delete(_ id: String) {}
    func list(limit: Int) -> [User] {
        (0..<limit).map { User(id: "u\($0)", name: "user-\($0)") }
    }

    /// A canned *async* lookup, awaited by `RequestInfo`'s `@Inject init` — so the example verifies a
    /// request-scoped binding can be constructed through an `async` init (swift-wire emitting `await` in
    /// the scope-entry thunk), not only a synchronous one.
    func tag(for path: String) async -> String { "tag:\(path)" }
}
