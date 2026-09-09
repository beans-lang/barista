# Changelog

## [0.1.0] — unreleased

The first release: `espresso/di.b`, extracted.

### Added
- `Disposable`, and disposal on scope close in reverse creation order. ARC does
  not close a socket, `deinit` may not park, and an object that dies inside a
  reference cycle never runs its `deinit` — which is what a service graph is
  full of.
- `ServiceCollection.add_forwarded(service_type, concrete, lifetime)` — resolve
  one name by resolving another. `add_services` builds every interface row with
  it, and it is what lets a host write its own scanner without needing
  `ServiceDescriptor`.
- `barista.add_services(services)` and `add_services_except(services, reject)`.
  The scan no longer takes a `WebApplicationBuilder`; a host that wants to veto
  a scanned type passes a closure.

### Changed
- `ServiceProvider.resolve_value` is now `pub fn resolve_type` — the
  runtime-typed counterpart to `resolve<T>()`, needed by any framework binding
  a parameter or activating a scanned type.
- `has_registrations` and `close_scope` are `pub` for the same reason: a host
  asks both per request.
- The annotation is `@barista.service`. There is no `@espresso.service` alias.
- `@service` on a type with no reflective initializer now names all three ways
  to get there — a `singleton class`, an abstract class, a closed generic.

### Not changed, on purpose
- **Singletons stay lazy.** Building them at `build_provider()` would move
  construction failures to startup, which reads better — and would change what
  "a singleton cannot capture a scoped service" means, from an error at the
  resolve that asked to an error at the line that built the provider. The
  thread-safety argument for eagerness is already answered by ownership: a host
  gives each worker its own graph, so two threads never race one store.

### Testing
- Six suites, twelve legs. Every suite runs on both backends and both must
  print the golden byte for byte.
- **The container now runs natively.** Espresso's `tests/di.b` compared
  instances with `==` on class references, which the native emitter refuses
  (`beans/test/emitter_gaps.tsv:92`), so that suite was interpreter-only for
  its whole life — and reflection metadata is emitted per backend, which is
  exactly what a container leans on. Identity is a minted integer now.
- A wasm leg with a negative control, so the "no OS capability" claim cannot go
  quietly green.
