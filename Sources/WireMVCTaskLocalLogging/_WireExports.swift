// Wire-aware opt-in marker. Its presence tells a consuming target's build plugin to re-parse this
// library's sources, so the app-scoped and request-scoped `Logger` bindings below compose into the
// consumer's graph. Presence-only.
