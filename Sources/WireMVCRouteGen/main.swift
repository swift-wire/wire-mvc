import Foundation
import WireMVCCodegen

// `WireMVCRouteGen` — the WireMVC route-codegen tool (the domain half of Phase A). A thin CLI over
// `WireMVCCodegen.generateRouteContributors`: it parses the consumer's controller sources and emits a
// `_WireRoutes.swift` of `RouteContributor` extensions on the plugin-emitted structural proxies (the
// witness body referencing `_wireSubject` / `_wireFactory_<key>`). The build plugin runs it alongside
// WireGen (which emits the structs) — the two tools, one module, the field-name handshake. Until the A3
// cutover wires it into a build, it stands alone (spike-23 proved the two-tool orchestration).
//
// CLI: WireMVCRouteGen <output-path> [--test-entry] [--import <Module>]... [--module <Name>] <source-files...>
//
// `--module <Name>` attributes the source paths that follow it to that module, until the next `--module`.
// Paths passed with no preceding `--module` carry no attribution, so the older flat form still works. The
// keyed harness is the only reader: it reconstructs the served `TestingKey`'s `#fileID` (`Module/File.swift`)
// to assert that a suite passes the key this target actually serves.
//
// `--test-entry` marks a test consumer (one depending on the `WireMVCTesting` product): the generated
// `@WireMVCBootstrap` entry becomes the `.wiremvc(_:)` suite-trait factory (plus `import WireMVCTesting` and
// `import Testing`) instead of the `@main`, which can't live in a test bundle. `--import <Module>` names a
// module the generated content depends on — a Wire-aware dependency re-parsed into this consumer, so the
// generated extensions can name its `package`/`public` types (a test target re-composing the app), or a
// test transport whose retroactive `WireMVCTestServer` conformance the generated factory needs in scope.
// Both are optional; absent, the tool emits the `@main` and no extra imports (the plain program-consumer path).
//
// On any route-shape diagnostic it prints compiler-style `file:line:col: error:` lines and exits
// non-zero, writing no output — the build plugin treats a missing output as a failed generation step.

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(
        Data(
            "usage: WireMVCRouteGen <output-path> [--test-entry] [--import <Module>]... <source-files...>\n".utf8
        )
    )
    exit(1)
}
let outputPath = arguments[1]

var testEntry = false
var extraImports: [String] = []
var sourcePaths: [String] = []
// Path → owning module, for the source paths that followed a `--module <Name>`. Only the keyed harness reads
// it (to reconstruct the served `TestingKey`'s `#fileID`); paths passed with no preceding `--module` are
// simply absent, which is why the flat form still works.
var sourceModules: [String: String] = [:]
var currentModule: String?
let remaining = Array(arguments.dropFirst(2))
var index = remaining.startIndex
while index < remaining.endIndex {
    let argument = remaining[index]
    switch argument {
    case "--test-entry":
        testEntry = true
    case "--import":
        let next = remaining.index(after: index)
        guard next < remaining.endIndex else {
            FileHandle.standardError.write(Data("error: --import requires a module name\n".utf8))
            exit(1)
        }
        extraImports.append(remaining[next])
        index = next
    case "--module":
        let next = remaining.index(after: index)
        guard next < remaining.endIndex else {
            FileHandle.standardError.write(Data("error: --module requires a module name\n".utf8))
            exit(1)
        }
        currentModule = remaining[next]
        index = next
    default:
        sourcePaths.append(argument)
        if let currentModule { sourceModules[argument] = currentModule }
    }
    index = remaining.index(after: index)
}

var files: [(path: String, source: String)] = []
for path in sourcePaths {
    do {
        files.append((path, try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)))
    } catch {
        FileHandle.standardError.write(Data("error: failed to read \(path): \(error)\n".utf8))
        exit(1)
    }
}

let result = generateRouteContributors(
    files: files,
    testEntry: testEntry,
    extraImports: extraImports,
    sourceModules: sourceModules
)

if !result.diagnostics.isEmpty {
    for diagnostic in result.diagnostics {
        let location = "\(diagnostic.location.file):\(diagnostic.location.line):\(diagnostic.location.column)"
        FileHandle.standardError.write(Data("\(location): error: \(diagnostic.message.message)\n".utf8))
    }
    exit(1)
}

do {
    try result.source.write(toFile: outputPath, atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("error: failed to write \(outputPath): \(error)\n".utf8))
    exit(1)
}
