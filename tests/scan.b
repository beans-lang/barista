// `@service` discovery: lifetimes from the enum, registration as self and as
// each directly implemented interface, forwarding so every name shares one
// instance per scope, and constructor injection between scanned services.
//
// Ported from espresso's `tests/di_scan.b`, with identity minted rather than
// compared by reference — see `tests/container.b` for why that suite could
// never run natively, and this one now can.
package main

import barista
import std.io

pub interface Clock {
    fn value() -> int
}

@barista.service(lifetime: barista.ServiceLifetime.singleton)
pub class SystemClock implements Clock {
    static made: int = 0
    pub tag: int = 0
    pub fn init() {
        SystemClock.made += 1
        self.tag = SystemClock.made
    }
    pub fn value() -> int { return 7 }
}

pub interface Store {
    fn label() -> string
    fn stamp() -> int
}

// default lifetime: scoped; injected with another scanned service
@barista.service
pub class MemoryStore implements Store {
    static made: int = 0
    clock: Clock
    pub tag: int = 0

    pub fn init(clock: Clock) {
        self.clock = clock
        MemoryStore.made += 1
        self.tag = MemoryStore.made
    }
    pub fn label() -> string { return "store@{self.clock.value()}" }
    pub fn stamp() -> int { return self.tag }
}

@barista.service(lifetime: barista.ServiceLifetime.transient)
pub class Widget {
    static made: int = 0
    pub tag: int = 0
    pub fn init() {
        Widget.made += 1
        self.tag = Widget.made
    }
}

fn tag_of(clock: Clock) -> int {
    match clock as? SystemClock {
        some(concrete) => { return concrete.tag }
        none => { return -1 }
    }
}

fn main() {
    let services: barista.ServiceCollection = new barista.ServiceCollection()
    let found: int = barista.add_services(services).expect("scan")
    io.println("scanned {found}")

    let root: barista.ServiceProvider = services.build_provider()
    let scope: barista.ServiceProvider = root.create_scope().expect("scope")
    let other: barista.ServiceProvider = root.create_scope().expect("other scope")

    // a singleton is one instance under both of its names, everywhere
    let by_interface: Clock = scope.resolve<Clock>().expect("clock")
    let by_class: Clock = scope.resolve<SystemClock>().expect("system clock")
    let elsewhere: Clock = other.resolve<Clock>().expect("other clock")
    io.println("singleton names {tag_of(by_interface) == tag_of(by_class)}")
    io.println("singleton scopes {tag_of(by_interface) == tag_of(elsewhere)}")
    io.println("singleton built {SystemClock.made} for 3 resolves in 2 scopes")

    // a scoped service is one instance per scope across its names
    let store_a: Store = scope.resolve<Store>().expect("store")
    let store_b: Store = scope.resolve<MemoryStore>().expect("memory store")
    let store_c: Store = other.resolve<Store>().expect("other store")
    io.println("scoped names {store_a.stamp() == store_b.stamp()}")
    io.println("scoped split {store_a.stamp() != store_c.stamp()}")
    io.println("scoped built {MemoryStore.made} for 3 resolves in 2 scopes")
    io.println("injected {store_a.label()}")

    // a transient is fresh every time
    let widget_a: Widget = scope.resolve<Widget>().expect("widget a")
    let widget_b: Widget = scope.resolve<Widget>().expect("widget b")
    io.println("transient split {widget_a.tag != widget_b.tag}")

    other.close().expect("close other")
    scope.close().expect("close scope")
    root.close().expect("close root")
}
