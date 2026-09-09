// The container: lifetimes, constructor injection, scope rules, cycles, and
// the close protocol.
//
// This is espresso's `tests/di.b`, ported — and changed in one way that
// matters. The original asked `first == second` to tell one instance from
// another, and **reference equality on two class references does not build
// natively** (`beansc build` refuses it; the checker and the interpreter both
// accept it — beans-lang/beans `test/emitter_gaps.tsv:92`). So that suite ran
// under the interpreter and only the interpreter, for its whole life: the
// container has never been exercised on the native backend, which is the half
// where reflection metadata is emitted rather than shared.
//
// Identity here is a minted int instead: every marker class stamps itself from
// a static counter in `init`, and the suite compares tags. Both backends run
// it, and the assertions are strictly stronger — "the same instance" rather
// than "an instance that compares equal".
package main

import barista
import std.io

pub interface Clock {
    fn value() -> int
}

pub class FixedClock implements Clock {
    pub fn init() {}
    pub fn value() -> int { return 42 }
}

pub class Greeter {
    clock: Clock

    pub fn init(clock: Clock) {
        self.clock = clock
    }

    pub fn message() -> string { return "hello {self.clock.value()}" }
}

/// One instance, tagged. `made` counts constructions, so a test can also ask
/// how many there were and not only whether two are the same one.
pub class RequestMarker {
    static made: int = 0
    pub tag: int = 0
    pub fn init() {
        RequestMarker.made += 1
        self.tag = RequestMarker.made
    }
}

pub class TransientMarker {
    static made: int = 0
    pub tag: int = 0
    pub fn init() {
        TransientMarker.made += 1
        self.tag = TransientMarker.made
    }
}

pub class FactoryMarker {
    static made: int = 0
    pub tag: int = 0
    pub fn init() {
        FactoryMarker.made += 1
        self.tag = FactoryMarker.made
    }
}

pub class CycleA {
    pub fn init(value: CycleB) {}
}

pub class CycleB {
    pub fn init(value: CycleA) {}
}

pub class BadSingleton {
    pub fn init(marker: RequestMarker) {}
}

fn make_factory(provider: barista.ServiceProvider) -> Result<FactoryMarker> {
    return ok(new FactoryMarker())
}

fn main() {
    let services: barista.ServiceCollection = new barista.ServiceCollection()
    services.add_singleton<Clock, FixedClock>().expect("clock")
    services.transient<Greeter>().expect("greeter")
    services.scoped<RequestMarker>().expect("marker")
    services.transient<TransientMarker>().expect("transient")
    services.transient<CycleA>().expect("cycle a")
    services.transient<CycleB>().expect("cycle b")
    services.singleton<BadSingleton>().expect("bad singleton")
    barista.add_singleton_factory(services, make_factory).expect("factory")

    let root: barista.ServiceProvider = services.build_provider()
    let scope: barista.ServiceProvider = root.create_scope().expect("scope")
    let greeter: Greeter = scope.resolve<Greeter>().expect("resolve greeter")
    let first: RequestMarker = scope.resolve<RequestMarker>().expect("first marker")
    let second: RequestMarker = scope.resolve<RequestMarker>().expect("second marker")
    let transient_first: TransientMarker = scope.resolve<TransientMarker>().expect("transient one")
    let transient_second: TransientMarker = scope.resolve<TransientMarker>().expect("transient two")
    let factory_first: FactoryMarker = scope.resolve<FactoryMarker>().expect("factory one")

    let other_scope: barista.ServiceProvider = root.create_scope().expect("other scope")
    let other_marker: RequestMarker = other_scope.resolve<RequestMarker>().expect("other marker")
    let factory_second: FactoryMarker = other_scope.resolve<FactoryMarker>().expect("factory two")

    io.println(greeter.message())
    io.println("scoped same {first.tag == second.tag}")
    io.println("scoped split {first.tag != other_marker.tag}")
    io.println("transient split {transient_first.tag != transient_second.tag}")
    io.println("singleton same {factory_first.tag == factory_second.tag}")
    // The counters, which the reference comparison could not say: a scoped
    // service is built once per scope and a singleton once per graph, so two
    // scopes asking twice each is two markers and one factory value.
    io.println("scoped built {RequestMarker.made} for 3 resolves in 2 scopes")
    io.println("transient built {TransientMarker.made} for 2 resolves")
    io.println("singleton built {FactoryMarker.made} for 2 resolves in 2 scopes")
    match root.resolve<RequestMarker>() {
        ok(_) => io.println("root scope accepted"),
        err(error) => io.println("root scope {error.kind}"),
    }
    match scope.resolve<CycleA>() {
        ok(_) => io.println("cycle accepted"),
        err(error) => io.println("cycle {error.kind}"),
    }
    match scope.resolve<BadSingleton>() {
        ok(_) => io.println("captive scope accepted"),
        err(error) => io.println("captive scope {error.kind}"),
    }
    other_scope.close().expect("close other scope")
    scope.close().expect("close scope")
    root.close().expect("close root")
    match root.create_scope() {
        ok(_) => io.println("closed root accepted"),
        err(error) => io.println("closed root {error.kind}"),
    }
}
