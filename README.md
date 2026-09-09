# barista

A dependency-injection container for [Beans](https://github.com/beans-lang/beans),
in the shape of `Microsoft.Extensions.DependencyInjection`: three lifetimes,
constructor injection through reflection, per-scope resolution, and annotation
discovery.

It imports `std.reflect` and nothing else. No HTTP, no I/O, no C.

```beans
import barista

pub interface Clock { fn value() -> int }

pub class SystemClock implements Clock {
    pub fn init() {}
    pub fn value() -> int { return 7 }
}

pub class Greeter {
    clock: Clock
    pub fn init(clock: Clock) { self.clock = clock }
    pub fn message() -> string { return "hello {self.clock.value()}" }
}

fn main() {
    let services: barista.ServiceCollection = new barista.ServiceCollection()
    services.add_singleton<Clock, SystemClock>().expect("clock")
    services.transient<Greeter>().expect("greeter")

    let root: barista.ServiceProvider = services.build_provider()
    let scope: barista.ServiceProvider = root.create_scope().expect("scope")
    let greeter: Greeter = scope.resolve<Greeter>().expect("greeter")
    // ... greeter.message()
    scope.close().expect("close")
    root.close().expect("close root")
}
```

## Where it came from

This was `espresso/di.b`. It moved because a container is not a web framework's
business: `latte` wants one for its pages and view-models, and a desktop
toolkit would want the same one without taking an HTTP server with it. The one
function that knew about `WebApplicationBuilder` stayed in espresso.

## Registering

| | |
|---|---|
| `services.transient<T>()` / `scoped<T>()` / `singleton<T>()` | a concrete type as itself |
| `services.add_transient<S, I>()` / `add_scoped` / `add_singleton` | `I` as the implementation of `S` |
| `services.add(service_type, implementation_type, lifetime)` | the same, for types known only at run time |
| `services.add_forwarded(service_type, concrete, lifetime)` | resolving one name resolves another — one instance under both |
| `barista.add_transient_factory(services, fn)` / `add_scoped_factory` / `add_singleton_factory` | a value you build yourself |
| `barista.add_services(services)` | every `@barista.service` class in the executable |

Registration is frozen by `build_provider()`; adding after it is an error, not
a silent no-op.

## Resolving

`scope.resolve<T>()` for a static type; `scope.resolve_type(t)` for a
`reflect.Type` a framework holds at run time, answering a boxed
`reflect.Value` you downcast with `as?`.

Constructor parameters are resolved from the same provider.
`provider.activate(type)` constructs a type that is **not** registered — a page
component, a handler object — resolving only its constructor's parameters, so a
framework can mount caller-written types without turning each into a service.

## Lifetimes and scopes

`transient` is built per resolve. `scoped` is built once per scope. `singleton`
is built once per **provider graph** — which is per worker in a server that
gives each worker its own graph, not once per process. That distinction is
real; say "per graph" and you will not be surprised.

Two rules are enforced rather than documented: a `scoped` service cannot be
resolved from the root provider, and a `singleton` cannot capture a `scoped`
one. Both answer an error naming the service. Dependency cycles are detected at
resolve, not by hanging.

## Closing

`scope.close()` releases what that scope built, in reverse creation order.
Closing the root also releases singletons. A service that implements
`Disposable` gets `dispose()` called before it is dropped.

`Disposable` exists because ARC is not enough: `deinit` may not park, so
anything that closes a socket is explicit teardown — and an object that dies
inside a reference cycle never runs its `deinit` at all. A service graph is
exactly where cycles form.

A **transient is never disposed**: the container hands it over and keeps no
reference to it. If a transient owns a resource, its caller owns closing it.

## What it does not do

No instance registration (wrap it in a factory), no `try_add`, no
multi-registration, no keyed services, no open generics, no decoration, no
options binding.

Two limits come from the language and are worth knowing before they surprise
you:

- **A closed generic, an abstract class and a `singleton class` have no
  reflective initializer**, so none of them can be container-activated. Register
  them through a factory. The `@service` scan refuses them by name at scan
  time rather than at first resolve.
- **`type.interfaces()` answers only directly declared interfaces**, and the
  runtime's assignability walk does not climb from one interface to another it
  extends. `class C implements Named`, where `interface Named extends Shape`,
  registers under `C` and `Named` and not under `Shape`. Add that one with
  `add_forwarded`.

## Testing

```bash
./test.sh            # both backends, every suite
./test.sh --interp   # the interpreter only, for the edit loop
./test.sh dispose    # one suite, both backends
./test.sh --wasm     # the no-OS leg, with its negative control
```

Every suite runs under the tree interpreter *and* as a native binary, and both
must print the golden byte for byte. That matters here more than usual:
espresso's DI suite compared instances with `==` on class references, which
does not build natively, so the container ran under the interpreter and only
the interpreter for its whole life. Identity is a minted integer now, and both
backends run everything.
