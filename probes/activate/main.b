// What one resolve costs, and where the time goes.
//
// This is latte's `probes/p5_activate`, brought into the repo whose code it
// measures. It is not a suite: it prints timings, so it has no golden and the
// gate does not run it. Run it by hand, on an idle machine, before and after a
// change to the resolve path.
//
//     beansc build probes/activate/main.b -o /tmp/activate && /tmp/activate
//
// Five interleaved passes and the minimum wins. One pass on a cold machine
// reads three times slow, and running each bench to completion in turn lets a
// load spike land inside one bench and not another — which is how a comparison
// between two of them stops meaning anything.
package main

import barista
import std.io
import std.reflect
import std.time

pub class Clock { pub fn init() {} pub fn now() -> int { return 1 } }
pub class Users { pub fn init() {} pub fn count() -> int { return 2 } }
pub class Theme { pub fn init() {} pub fn name() -> string { return "dark" } }

pub class Zero {
    pub label: string = ""
    pub fn init() {}
}

pub class One {
    pub label: string = ""
    clock: Clock
    pub fn init(clock: Clock) { self.clock = clock }
    pub fn tick() -> int { return self.clock.now() }
}

pub class Three {
    pub label: string = ""
    clock: Clock
    users: Users
    theme: Theme
    pub fn init(clock: Clock, users: Users, theme: Theme) {
        self.clock = clock
        self.users = users
        self.theme = theme
    }
    pub fn describe() -> string {
        return "{self.clock.now()}/{self.users.count()}/{self.theme.name()}"
    }
}

const ROUNDS: int = 1000
const PASSES: int = 5

class Best {
    pub plain: int = -1
    pub lookup: int = -1
    pub cached: int = -1
    pub zero: int = -1
    pub one: int = -1
    pub three: int = -1
    pub fn init() {}
}

fn keep(current: int, sample: int) -> int {
    if sample <= 0 { return current }
    if current < 0 { return sample }
    if sample < current { return sample }
    return current
}

fn bench_new(rounds: int) -> int {
    var kept: int = 0
    let t0: int = time.monotonic_nanos()
    for round: int in 0..rounds {
        let made: Zero = new Zero()
        made.label = "x"
        kept += 1
    }
    let spent: int = time.monotonic_nanos() - t0
    if kept != rounds { return -1 }
    return spent / rounds
}

/// What the container used to pay on every single activation.
fn bench_initializer_lookup(rounds: int) -> int {
    var found: int = 0
    let t0: int = time.monotonic_nanos()
    for round: int in 0..rounds {
        match type_of(Zero).initializer() {
            some(ctor) => { found += 1 }
            none => { return -1 }
        }
    }
    let spent: int = time.monotonic_nanos() - t0
    if found != rounds { return -1 }
    return spent / rounds
}

/// The floor: reflective construction with the lookup already hoisted. No
/// container can go below this.
fn bench_cached_initializer(rounds: int) -> int {
    match type_of(Zero).initializer() {
        some(ctor) => {
            var kept: int = 0
            let t0: int = time.monotonic_nanos()
            for round: int in 0..rounds {
                match ctor.call([]) {
                    ok(made) => {
                        match made as? Zero {
                            some(instance) => { instance.label = "x"; kept += 1 }
                            none => {}
                        }
                    }
                    err(e) => { return -1 }
                }
            }
            let spent: int = time.monotonic_nanos() - t0
            if kept != rounds { return -1 }
            return spent / rounds
        }
        none => { return -1 }
    }
}

fn bench_zero(scope: barista.ServiceProvider, rounds: int) -> int {
    var kept: int = 0
    let t0: int = time.monotonic_nanos()
    for round: int in 0..rounds {
        match scope.resolve<Zero>() {
            ok(made) => { made.label = "x"; kept += 1 }
            err(e) => { io.println("zero failed: {e.kind}: {e.msg}"); return -1 }
        }
    }
    let spent: int = time.monotonic_nanos() - t0
    if kept != rounds { return -1 }
    return spent / rounds
}

fn bench_one(scope: barista.ServiceProvider, rounds: int) -> int {
    var total: int = 0
    let t0: int = time.monotonic_nanos()
    for round: int in 0..rounds {
        match scope.resolve<One>() {
            ok(made) => { total += made.tick() }
            err(e) => { io.println("one failed: {e.kind}: {e.msg}"); return -1 }
        }
    }
    let spent: int = time.monotonic_nanos() - t0
    if total != rounds { return -1 }
    return spent / rounds
}

fn bench_three(scope: barista.ServiceProvider, rounds: int) -> int {
    var kept: int = 0
    let t0: int = time.monotonic_nanos()
    for round: int in 0..rounds {
        match scope.resolve<Three>() {
            ok(made) => {
                if made.describe() == "1/2/dark" { kept += 1 }
            }
            err(e) => { io.println("three failed: {e.kind}: {e.msg}"); return -1 }
        }
    }
    let spent: int = time.monotonic_nanos() - t0
    if kept != rounds { return -1 }
    return spent / rounds
}

fn passes(scope: barista.ServiceProvider, rounds: int) -> Best {
    let best: Best = new Best()
    for pass: int in 0..PASSES {
        best.plain = keep(best.plain, bench_new(rounds))
        best.lookup = keep(best.lookup, bench_initializer_lookup(rounds))
        best.cached = keep(best.cached, bench_cached_initializer(rounds))
        best.zero = keep(best.zero, bench_zero(scope, rounds))
        best.one = keep(best.one, bench_one(scope, rounds))
        best.three = keep(best.three, bench_three(scope, rounds))
    }
    return best
}

fn run(scope: barista.ServiceProvider) {
    // A whole discarded pass first: the process needs to be warm, and a
    // twenty-round warm-up is not long enough for the ramp.
    let w1: int = bench_new(ROUNDS)
    let w2: int = bench_initializer_lookup(ROUNDS)
    let w3: int = bench_cached_initializer(ROUNDS)
    let w4: int = bench_zero(scope, ROUNDS)
    let w5: int = bench_one(scope, ROUNDS)
    let w6: int = bench_three(scope, ROUNDS)

    let best: Best = passes(scope, ROUNDS)
    io.println("ns per activation, best of {PASSES} interleaved passes of {ROUNDS} rounds:")
    io.println("  new Zero()                 {best.plain}")
    io.println("  Type.initializer() lookup  {best.lookup}")
    io.println("  a cached Initializer.call  {best.cached}   <- the floor")
    io.println("  resolve<Zero>()  0 deps    {best.zero}")
    io.println("  resolve<One>()   1 dep     {best.one}")
    io.println("  resolve<Three>() 3 deps    {best.three}")
    io.println("a 200-component page: {best.zero * 200 / 1000} us with no deps, {best.three * 200 / 1000} us with three")
    io.println("container overhead above the floor: {best.zero - best.cached} ns")
    let sane: bool = w4 > 0 && w5 > 0 && w6 > 0 &&
        best.plain > 0 && best.lookup > 0 && best.cached > 0 &&
        best.zero > 0 && best.one > 0 && best.three > 0 &&
        best.three > best.zero
    if sane { io.println("probe activate: ok") }
    else { io.println("probe activate: FAILED") }
}

fn main() {
    let services: barista.ServiceCollection = new barista.ServiceCollection()
    services.scoped<Clock>().expect("clock")
    services.scoped<Users>().expect("users")
    services.scoped<Theme>().expect("theme")
    services.transient<Zero>().expect("zero")
    services.transient<One>().expect("one")
    services.transient<Three>().expect("three")
    let root: barista.ServiceProvider = services.build_provider()
    match root.create_scope() {
        ok(scope) => {
            run(scope)
            let closed: Result<bool> = scope.close()
        }
        err(e) => { io.println("no scope: {e.kind}") }
    }
    let closed_root: Result<bool> = root.close()
}
