# Changelog

## [0.1.1] — 2026-09-16

No library change. The README showed `import barista`, which is the spelling
that works only inside this checkout; a consumer who follows `pot add` writes
`import github.com/beans-lang/barista`, and the binding is `barista` either
way.

Tagged so espresso, latte and cortado can pin a release rather than a local
directory: each of them now reaches this container with a `require` row naming
this repository.

## [0.1.0] — 2026-09-10

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
- `ServiceProvider.provides(service_type)` — asks whether a service type is
  registered, without building it. Lets a host check a whole dependency graph
  at startup instead of discovering a missing registration when something
  tries to render.

### Changed
- `ServiceProvider.resolve_value` is now `pub fn resolve_type` — the
  runtime-typed counterpart to `resolve<T>()`, needed by any framework binding
  a parameter or activating a scanned type.
- `has_registrations` and `close_scope` are `pub` for the same reason: a host
  asks both once per incoming request or job, whether or not it ends up
  opening a scope.
- The annotation is `@barista.service`. There is no `@espresso.service` alias.
- `@service` on a type with no reflective initializer now names all three ways
  to get there — a `singleton class`, an abstract class, a closed generic.

### Performance
- `ActivationPlan` caches each implementation type's reflective initializer,
  parameter list, and activation fault once per provider graph instead of once
  per resolve. `resolve<Zero>()` (no dependencies) dropped from 740 ns to
  445 ns; `resolve<Three>()` (three dependencies) from 1974 ns to 1067 ns.
  Container overhead above the reflective-construction floor fell from 525 ns
  to 222 ns.
- "Last registration wins" is backed by a `Map` now, not a reverse scan over a
  `List` — same behavior, but a stated rule with a test instead of an accident
  of which way the loop ran.

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
