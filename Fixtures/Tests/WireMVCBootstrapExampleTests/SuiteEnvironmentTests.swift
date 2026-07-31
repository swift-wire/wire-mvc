import Testing
import WireMVCTesting

@testable import WireMVCBootstrapExample

// The suite factory's `environment:` closure — the seam an integration suite uses to point an
// environment-reading graph at something it discovers at runtime, a container's assigned host and port being
// the motivating case.
//
// The closure is evaluated at *suite entry*, after the traits listed before `.wiremvc(…)` have scoped, and
// applied before `Wire.bootstrap()` runs. That ordering is structural — the harness wraps its own bootstrap —
// rather than something the suite has to arrange by trait order, which is what a hand-written `SuiteTrait`
// doing the same job can only express as a comment.
//
// There is deliberately no sibling suite here asserting the *absence* of the value. The environment is process
// global and swift-testing runs suites concurrently, so such a suite would observe whatever this one had
// applied at the time — it fails, and no trait can order two suites against each other. Apply-and-restore is
// pinned deterministically by `TestEnvironmentTests` in the framework's own target instead.

@Suite(.wiremvc(.inProcess, environment: { [deploymentSettingKey: "from-the-suite"] }))
struct SuiteEnvironmentTests {
    /// The value reaches the graph: `provideDeploymentSetting` read it while `Wire.bootstrap()` ran, so the
    /// route serves it. Reading it back over the transport — rather than checking the variable — is what
    /// proves the ordering, since a value applied after the bootstrap would leave the binding on its default.
    @Test func suppliedEnvironmentReachesTheBootstrap() async throws {
        try await withClient(for: DeploymentControllerClient.self) { deployment in
            let setting = try await deployment.read()
            #expect(setting.value == "from-the-suite")
        }
    }
}
