import ServiceLifecycle
import Wire
import WireMVC

// A trivial app-scoped `ServiceLifecycle` service, collated via `@BackgroundService` on a `@Provides`
// function — the provider form, for a type constructed by the graph rather than a `@Singleton` type.
// The marker adds no conformance (`Heartbeat` states `: Service` itself); Wire reads it as
// `@Contributes(to: WireMVCKeys.services)`, so `graph.services` (and `WireMVC.apply`'s return) includes
// it. The example asserts that collation; a real app would hand it to a `ServiceGroup` to run.
@Provides
@BackgroundService
func makeHeartbeat() -> Heartbeat { Heartbeat() }

final class Heartbeat: Service {
    func run() async throws { try? await gracefulShutdown() }
}
