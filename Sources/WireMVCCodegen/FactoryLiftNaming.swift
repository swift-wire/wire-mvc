/// The names the structural and domain halves of a `@Controller` must derive identically.
///
/// swift-wire's plugin emits the contributor proxy — its stored factory properties, its by-type and keyed
/// adapter-dependency fields — and this generator emits the witness that reads them. Neither sees the
/// other's output, so every one of these names is computed twice, once on each side, from the same input:
/// a `@Middleware` key, a type reference, a `@Coding` argument. They agree because both sides run the same
/// rule, which is why these live apart from the route blocks that happen to call them.

/// Derive the synthesised factory names from a `@Middleware(key)`'s canonical key text, using the same
/// sanitiser swift-wire's factory synthesis uses (any character outside `[A-Za-z0-9_]` → `_`). Both
/// sides must agree so the plugin's construction call resolves to the lifted property and the fold's
/// `create` names it.
public func sanitizedKeyFragment(_ key: String) -> String {
    String(key.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
}
public func factoryPropertyName(forKey key: String) -> String { "_wireFactory_" + sanitizedKeyFragment(key) }
public func factoryTypeName(forKey key: String) -> String { "_WireFactory_" + sanitizedKeyFragment(key) }

/// The proxy field an `@Middleware(T.self)` binding is read through — the same name swift-wire's
/// adapter-dependency pass gives the by-type injected field: `_wire` + the simple (generics- and
/// namespace-stripped) type name, upper-cameled (`Mod.RequireAdmin<…>` → `_wireRequireAdmin`). Both
/// sides derive it identically so the witness and the plugin-emitted struct meet on the field.
public func dependencyPropertyName(forType type: String) -> String {
    let withoutGenerics = type.prefix { $0 != "<" }
    let simple = withoutGenerics.split(separator: ".").last.map(String.init) ?? String(withoutGenerics)
    return "_wire" + simple.prefix(1).uppercased() + simple.dropFirst()
}

/// The proxy field an `@Middleware(key)` binding is read through when `key` is a graph binding key (not
/// a `@Factory` template) — `_wire` + the sanitised key, matching swift-wire's keyed adapter-dependency
/// field name.
public func dependencyPropertyName(forKey key: String) -> String { "_wire" + sanitizedKeyFragment(key) }

/// The proxy field a `@Coding(...)` argument is read through — the same two-way dispatch
/// `middlewareConstructions` does, because it is the same `.injectsFromGraph` pass on the other side.
/// `WireMVCCoding.self` selects the unkeyed binding by type; anything else is a `BindingKey` reference and
/// selects the binding it keys.
public func codingProxyField(for reference: String) -> String {
    reference.hasSuffix(".self")
        ? dependencyPropertyName(forType: String(reference.dropLast(".self".count)))
        : dependencyPropertyName(forKey: reference)
}
