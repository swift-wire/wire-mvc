// Wire-aware opt-in marker. Its presence tells a consuming target's build plugin to re-parse this
// library's sources, which is how the `@Factory` template behind `CORSMiddlewareKeys.factory` becomes
// visible: without it the plugin never sees the template, and `@Middleware(CORSMiddlewareKeys.factory)`
// is diagnosed as a non-factory key. Presence-only — any module shipping a `@Factory` template needs it.
