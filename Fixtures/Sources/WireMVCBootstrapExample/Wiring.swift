// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

package import Synchronization
package import Wire

// The graph's plain bindings. `@Singleton`/`@Provides` make each a node `Wire.bootstrap()` constructs and
// injects — the controller injects `Greeter`, the composition root injects `ServerConfig`. Every
// participating declaration is `package` (with `package import Wire`) so a test target in this package can
// re-parse and re-compose these bindings — and supersede one with `@Replaces`.

/// The greeting contract the controller injects behind an `as:` key. A protocol (not a concrete type) so a
/// test target can supersede the app's real implementation with a fake via `@Replaces` — the
/// opaque-injection lift: the controller is generic over `G: Greeter`, resolved to whichever binding
/// produces the `Greeter` key.
package protocol Greeter: Sendable {
    func greet(_ name: String) -> String
}

/// The production greeter, bound under the `Greeter` key. `package` so a same-package test target can
/// re-compose (and replace) it across the module boundary.
@Singleton(as: Greeter.self)
package struct RealGreeter: Greeter {
    @Inject package init() {}
    package func greet(_ name: String) -> String { "Hello, \(name)!" }
}

/// The server bind config the composition root injects — read only by its `createServer()`, and so only on
/// the production path. `package` so a test target re-composing the app can still name it.
package struct ServerConfig: Sendable {
    package let host: String
    package let port: Int
    package init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

/// The graph's inputs — values built *before* construction and handed in by `AppBootstrap.prepare()`.
///
/// `ServerConfig` is the honest case for one: the port is a deployment fact, not something the graph can
/// derive, and reading it needs the environment rather than another binding. As an input it stays an
/// ordinary binding — `AppBootstrap` still writes `@Inject let config: ServerConfig` — but its value now
/// arrives from outside, and forgetting to supply it is a compile error at `Wire.bootstrap(inputs:)`
/// rather than a wrong default nobody notices.
@GraphInputs
package struct AppInputs: Sendable {
    package let serverConfig: ServerConfig
    /// A second input, keyed so it coexists with any other `String` binding — proving the keyed form
    /// reaches a consumer through `@Bind`.
    @Provides(AppInputKeys.releaseChannel) package let releaseChannel: String

    package init(serverConfig: ServerConfig, releaseChannel: String) {
        self.serverConfig = serverConfig
        self.releaseChannel = releaseChannel
    }
}

package enum AppInputKeys {
    package static let releaseChannel = BindingKey<String>()
}

/// Records that `prepare()` ran, and that it ran *before* any binding was constructed — the property that
/// makes a pre-step useful for `LoggingSystem.bootstrap`, which must precede the first log call.
package enum StartupProbe {
    package static let preparedCount = Atomic<Int>(0)
    /// Set by the first *binding* to be constructed. If `prepare()` ran first this is still 0 when it
    /// increments, which is what `preparedBeforeConstruction` records.
    package static let constructedCount = Atomic<Int>(0)
    package static let preparedBeforeConstruction = Atomic<Bool>(false)

    package static func recordPrepare() {
        preparedBeforeConstruction.store(constructedCount.load(ordering: .relaxed) == 0, ordering: .relaxed)
        preparedCount.add(1, ordering: .relaxed)
    }

    package static func recordConstruction() {
        constructedCount.add(1, ordering: .relaxed)
    }

    /// Plain reads, so a consumer needn't import Synchronization — and needn't touch a non-Copyable
    /// `Atomic` from inside a `#expect`, which cannot capture one.
    package static var prepareCount: Int { preparedCount.load(ordering: .relaxed) }
    package static var ranBeforeConstruction: Bool { preparedBeforeConstruction.load(ordering: .relaxed) }
}

/// What the graph's `StartupReport` binding ended up holding — recorded at construction so a test can
/// read it without reaching into the graph, which the suite trait owns and does not hand back.
package enum StartupSummary {
    private static let storage = Mutex<String>("")
    /// A plain read, for the same reason `StartupProbe`'s are.
    package static var value: String { storage.withLock { $0 } }
    static func record(_ summary: String) { storage.withLock { $0 = summary } }
}

/// A binding that consumes both inputs, so the route can report what actually reached the graph. Its init
/// bumps the construction probe, which is how the ordering assertion above gets its evidence.
@Singleton
package struct StartupReport: Sendable {
    package let summary: String

    @Inject package init(
        config: ServerConfig,
        @Bind(AppInputKeys.releaseChannel) releaseChannel: String
    ) {
        StartupProbe.recordConstruction()
        self.summary = "\(config.host):\(config.port)|\(releaseChannel)"
        StartupSummary.record(self.summary)
    }
}
