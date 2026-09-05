# Contributing

**The contribution policy — what may go straight to a pull request, what needs a proposal first, and
where AI assistance sits — is the family-wide one at
[swift-wire/.github](https://github.com/swift-wire/.github/blob/main/CONTRIBUTING.md).** Read that
first.

This file covers what is specific to building and testing *this* package. It exists separately
because GitHub serves a repository's own `CONTRIBUTING.md` instead of the organisation default, not
because the policy differs here.

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
swift package generate-documentation --target WireMVC --diagnostics-file /tmp/docc.json
python3 Scripts/docc-gate.py /tmp/docc.json
```

CI runs exactly that, and the gate is the point of it: the articles reference symbols by name, so a
renamed or removed macro breaks a link rather than a build — silently, and only for a reader. A doc
comment that names a symbol which no longer exists fails the same way.

> **Building the documentation rewrites `Package.resolved`.** The DocC plugin resolves the graph
> with every trait enabled, so `swift-http-server` and `elementary` are pinned back into the
> lockfile — which is exactly what the *Verify the core graph resolves no concrete server* job
> exists to catch. Run `swift package resolve` and commit that result, not the one a docs build
> left behind.

It is two commands rather than `--warnings-as-errors` because `WireMVC` re-exports `AsyncStreaming`
through a `public import`. On Linux the symbol graph carries those types into `/WireMVC/…`, so DocC
reports unresolved links in a dependency's doc comments — diagnostics this package cannot fix, and
which do not appear on macOS at all. The script filters the structured diagnostics down to files in
this repository.

Design notes under `Documentation/Notes/` are a different thing: they record *why* a design is
what it is, and are not part of the published documentation.
