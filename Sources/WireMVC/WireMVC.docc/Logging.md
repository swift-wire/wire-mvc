# Logging

A per-request logger, and two ways to get one.

## Overview

WireMVC ships request logging as two interchangeable targets. Both bind an app-scoped `Logger`
and a request-scoped one, so a request-scoped type's bare `@Inject var logger: Logger` resolves
to the per-request logger without naming a key. They differ in where the request's identity comes
from.

Pick one. They bind the same slots, so taking both is a duplicate-binding error.

## `WireMVCLogging`

Mints a correlation id per request and folds it into the request-scoped logger's metadata. The
app-scoped binding is a plain labelled logger. This is the self-contained option: nothing outside
WireMVC has to cooperate.

## `WireMVCTaskLocalLogging`

Adopts swift-log's task-local logger instead. The request-scoped logger's base is
`Logger.current`, snapshotted during the request, so whatever id the runtime already put on it is
there under the runtime's own key — which means the framework's own log lines and yours share an
id rather than carrying two.

Take this one when the surrounding runtime already establishes a task-local logger you want to
inherit. It requires swift-log 1.14 or later outright, since that is where the task-local API
lands.

## Replacing the app logger

Either target's app-scoped logger is an ordinary binding, so control it the way you control any
other — by superseding it:

```swift
@Provides(WireMVCApplication.logger)
@Replaces
func appLogger() -> Logger { Logger(label: "my-app") }
```

## The ordering rule worth knowing

swift-log captures the unbound default handler at *first access* and reuses it for the process
lifetime. So `LoggingSystem.bootstrap(_:)` has to run before the graph is built — after it, every
binding constructed so far is holding a logger that ignores your configuration.

That is precisely what `prepare()` on the composition root is for: it runs before any binding
exists. See <doc:TheCompositionRoot>.

## Adding fields

Contributed log metadata folds onto the request-scoped logger in both targets, so an
application's own `@Contributes` log fields work unchanged whichever one is in use.
