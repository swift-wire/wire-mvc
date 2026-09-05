// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

package import Wire
import WireMVC

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// A binding that reads the process environment at bootstrap — the shape `.wiremvc(environment:)` exists to
// configure. An app reading its configuration this way (12-factor) can only be pointed at a value a test
// discovers at runtime by that value being in the process environment when `Wire.bootstrap()` runs, which is
// what the suite factory's `environment:` closure arranges.

/// A value the graph reads from the environment at construction. Defaults when unset, so production and an
/// unconfigured suite both work.
package struct DeploymentSetting: Sendable {
    package let value: String
}

/// The environment name the fixture reads. Namespaced so a stray value in a developer's shell can't affect it.
package let deploymentSettingKey = "WIREMVC_FIXTURE_DEPLOYMENT_SETTING"

@Provides package func provideDeploymentSetting() -> DeploymentSetting {
    DeploymentSetting(value: ProcessInfo.processInfo.environment[deploymentSettingKey] ?? "unset")
}

/// Serves whatever the graph read at bootstrap, so a test can observe the value the environment supplied
/// rather than trusting that it was set.
@Singleton
@Controller("/deployment")
package struct DeploymentController: Sendable {
    @Inject var setting: DeploymentSetting

    @Get("/")
    @JSONResponse
    package func read() -> Note { Note(value: setting.value) }
}
