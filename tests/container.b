// The container: lifetimes, constructor injection, scope rules, cycles, and
// the close protocol.
//
// The original version of this suite told one instance from another with
// `first == second`, and **reference equality on two class references does
// not build natively** (`beansc build` refuses it; the checker and the
// interpreter both accept it — beans-lang/beans `test/emitter_gaps.tsv:92`).
// So it ran under the interpreter and only the interpreter: the container was
// never exercised on the native backend, which is the half where reflection
// metadata is emitted rather than shared.
//
// Identity here is a minted int instead: every marker class stamps itself from
// a static counter in `init`, and the suite compares tags. Both backends run
// it, and the assertions are strictly stronger — "the same instance" rather
// than "an instance that compares equal".
package main

import barista
import std.io
import std.reflect

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

// ---- last registration wins, and add_forwarded ------------------------
//
// Both of these were true before and neither was tested. "Last wins" used to
// fall out of a reverse linear scan over a List — the same answer, true only
// while nobody changed the direction of the loop. It is a Map now and the rule
// is stated, so it gets a case.

pub interface Sink {
    fn label() -> string
}

pub class FirstSink implements Sink {
    pub fn init() {}
    pub fn label() -> string { return "first" }
}

pub class SecondSink implements Sink {
    pub fn init() {}
    pub fn label() -> string { return "second" }
}

pub interface Alias {
    fn tag_of() -> int
}

pub class Forwarded implements Alias {
    static made: int = 0
    pub tag: int = 0
    pub fn init() {
        Forwarded.made += 1
        self.tag = Forwarded.made
    }
    pub fn tag_of() -> int { return self.tag }
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
    // Registered twice for the same service type. The second must win.
    services.add_scoped<Sink, FirstSink>().expect("first sink")
    services.add_scoped<Sink, SecondSink>().expect("second sink")
    // One concrete service reachable under a second name, sharing one instance
    // per scope — which is what an interface registration is.
    services.scoped<Forwarded>().expect("forwarded")
    services.add_forwarded(type_of(Alias), type_of(Forwarded),
                           barista.ServiceLifetime.scoped).expect("alias")

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
    let sink: Sink = scope.resolve<Sink>().expect("sink")
    io.println("last registration wins {sink.label()}")
    // The forwarded name and the concrete name are the SAME instance in one
    // scope, and a different one in the next — which is the whole point of
    // forwarding rather than registering the type twice.
    let direct: Forwarded = scope.resolve<Forwarded>().expect("direct")
    let aliased: reflect.Value =
        scope.resolve_type(type_of(Alias)).expect("aliased")
    var aliased_tag: int = -1
    match aliased as? Forwarded {
        some(concrete) => { aliased_tag = concrete.tag }
        none => {}
    }
    let elsewhere: Forwarded = other_scope.resolve<Forwarded>().expect("elsewhere")
    io.println("forwarded same instance {direct.tag == aliased_tag}")
    io.println("forwarded per scope {direct.tag != elsewhere.tag}")
    io.println("forwarded built {Forwarded.made} for 3 resolves in 2 scopes")

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
