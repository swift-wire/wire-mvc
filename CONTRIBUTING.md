# Contributing

## Building and testing

Two packages, and both need running:

```sh
swift test                   # the core: codegen, router, testing runtime
cd Fixtures && swift test    # the runnable examples and their integration suites
```

`Fixtures/` is a separate package with a path dependency on the root (`.package(path: "..")`). It
exists because its targets serve on `NIOHTTPServer`, and it is **the only place
`WireMVCBuildPlugin` actually runs** — no root target applies it. A change to the plugin, or to
what the two codegen tools emit, is unverified until the fixtures build.
`WireMVCBootstrapExampleBindTests` is the one that exercises the keyed `TestingKey` harness end to
end.

Both packages are tools-version 6.4, so they need a 6.4 toolchain. The pinned snapshot is in
`.swift-version`, and CI installs exactly that one.

## The plugin type-check trap

**`swift build --target WireMVCBuildPlugin` does not type-check the plugin.** SwiftPM compiles a
build-tool plugin only when some target applies it, and the flag no-ops silently rather than
erroring — so a type error in the plugin passes that command and then fails in CI on the
fixtures.

To check it directly:

```sh
xcrun swiftc -typecheck -parse-as-library -swift-version 6 \
  -I "$(xcrun --show-sdk-platform-path)/../../Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/PluginAPI" \
  -Xfrontend -disable-availability-checking \
  Plugins/WireMVCBuildPlugin/WireMVCBuildPlugin.swift
```

## Documentation

User-facing documentation is the DocC catalog at `Sources/WireMVC/WireMVC.docc`. Build it with:

```sh
swift package generate-documentation --target WireMVC --warnings-as-errors
```

CI runs exactly that. `--warnings-as-errors` is the point of it: the articles reference symbols by
name, so a renamed or removed macro breaks a link rather than a build — silently, and only for a
reader. A doc comment that names a symbol which no longer exists fails the same way.

Design notes under `Documentation/Notes/` are a different thing: they record *why* a design is
what it is, and are not part of the published documentation.
