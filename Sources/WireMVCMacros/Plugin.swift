// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct WireMVCMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [
        ControllerMacro.self, RouteMarkerMacro.self, BackgroundServiceMacro.self, MiddlewareFactoryMacro.self,
    ]
}
