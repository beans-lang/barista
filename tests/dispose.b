// `Disposable`: who gets closed, in what order, how many times, and — the part
// that is easiest to assume wrong — who does *not*.
//
// Why the container closes at all. ARC frees memory; it does not close a
// socket, and `deinit` is not the place for one either: a destructor may not
// park, and an object that dies inside a reference cycle **never runs its
// `deinit`**. A service graph is exactly where cycles form. So a service that
// owns a resource implements `Disposable` and the scope that built it calls
// `dispose()`.
//
// Three services and not two in the ordering case, deliberately. Reverse order
// over two elements is one coin flip away from passing by accident.
package main

import barista
import std.io

/// The log every case writes to. A `static` field because a module in Beans
/// has no mutable state of its own, and one process-wide slot is exactly right
/// for a single-threaded suite.
pub class Log {
    static line: string = ""
    static fn note(what: string) {
        if Log.line == "" { Log.line = what }
        else { Log.line = "{Log.line} {what}" }
    }
    static fn drain() -> string {
        let held: string = Log.line
        Log.line = ""
        return held
    }
}

// ---- three scoped services, built in a known order -----------------------

pub class Alpha implements barista.Disposable {
    pub fn init() { Log.note("+a") }
    pub fn dispose() { Log.note("-a") }
}

pub class Beta implements barista.Disposable {
    // Beta depends on Alpha, so Alpha is always constructed first and must
    // therefore be disposed last.
    alpha: Alpha
    pub fn init(alpha: Alpha) { self.alpha = alpha; Log.note("+b") }
    pub fn dispose() { Log.note("-b") }
}

pub class Gamma implements barista.Disposable {
    beta: Beta
    pub fn init(beta: Beta) { self.beta = beta; Log.note("+c") }
    pub fn dispose() { Log.note("-c") }
}

/// The control that makes the assertions above mean something: a service the
/// container stores exactly the same way, which does NOT implement
/// `Disposable`. If closing a scope tripped over it, or disposed it anyway,
/// the ordering cases could not tell "disposed the right ones" from "disposed
/// everything it could reach".
pub class Plain {
    pub fn init() { Log.note("+p") }
}

// ---- a singleton, whose lifetime is the graph and not the scope ----------

pub class Pool implements barista.Disposable {
    static disposals: int = 0
    pub fn init() { Log.note("+pool") }
    pub fn dispose() {
        Pool.disposals += 1
        Log.note("-pool")
    }
}

/// A transient. The container hands one out and keeps no reference, so it
/// cannot dispose it — and a reader who assumes otherwise leaks a handle per
/// resolve. Asserted, not left to be discovered.
pub class Fleeting implements barista.Disposable {
    pub fn init() { Log.note("+f") }
    pub fn dispose() { Log.note("-f") }
}

fn report(what: string, got: string, want: string) {
    if got == want { io.println("ok   {what}: {got}") }
    else { io.println("FAIL {what}: got [{got}], want [{want}]") }
}

fn main() {
    let services: barista.ServiceCollection = new barista.ServiceCollection()
    services.scoped<Alpha>().expect("alpha")
    services.scoped<Beta>().expect("beta")
    services.scoped<Gamma>().expect("gamma")
    services.scoped<Plain>().expect("plain")
    services.transient<Fleeting>().expect("fleeting")
    services.singleton<Pool>().expect("pool")
    let root: barista.ServiceProvider = services.build_provider()

    // -- 1. reverse creation order, with a non-Disposable in the middle -----
    io.println("== 1. a scope disposes what it built, newest first ==")
    let one: barista.ServiceProvider = root.create_scope().expect("scope one")
    let _g: Gamma = one.resolve<Gamma>().expect("gamma")   // builds a, b, c
    let _p: Plain = one.resolve<Plain>().expect("plain")   // builds p, no dispose
    report("construction order", Log.drain(), "+a +b +c +p")
    one.close().expect("close one")
    report("disposal order, and Plain silently skipped", Log.drain(), "-c -b -a")

    // -- 2. a second scope is its own set ----------------------------------
    io.println("")
    io.println("== 2. a second scope builds and closes its own ==")
    let two: barista.ServiceProvider = root.create_scope().expect("scope two")
    let _b: Beta = two.resolve<Beta>().expect("beta")      // builds a, b only
    report("a scope builds only what it is asked for", Log.drain(), "+a +b")
    two.close().expect("close two")
    report("and closes only those", Log.drain(), "-b -a")

    // -- 3. a transient is never disposed, because it is never kept --------
    io.println("")
    io.println("== 3. a transient is handed over, not held ==")
    let three: barista.ServiceProvider = root.create_scope().expect("scope three")
    let _f1: Fleeting = three.resolve<Fleeting>().expect("fleeting one")
    let _f2: Fleeting = three.resolve<Fleeting>().expect("fleeting two")
    report("two transients built", Log.drain(), "+f +f")
    three.close().expect("close three")
    report("and the scope disposes neither — it kept no reference", Log.drain(), "")

    // -- 4. a singleton belongs to the graph, not to a scope ---------------
    io.println("")
    io.println("== 4. a singleton outlives every scope ==")
    let four: barista.ServiceProvider = root.create_scope().expect("scope four")
    let _pool: Pool = four.resolve<Pool>().expect("pool")
    report("built once, on first use", Log.drain(), "+pool")
    four.close().expect("close four")
    report("closing a scope does NOT dispose it", Log.drain(), "")
    let five: barista.ServiceProvider = root.create_scope().expect("scope five")
    let _pool2: Pool = five.resolve<Pool>().expect("pool again")
    report("a later scope gets the same one, unbuilt", Log.drain(), "")
    five.close().expect("close five")

    root.close().expect("close root")
    report("closing the root disposes it", Log.drain(), "-pool")
    report("exactly once", "{Pool.disposals}", "1")
}
