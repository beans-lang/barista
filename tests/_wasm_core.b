// The wasm probe: an entry that imports barista and nothing else, checked for
// `wasm32-unknown-unknown` against the freestanding runtime.
//
// It is not testing wasm. It is testing that barista needs no operating
// system — no filesystem, no sockets, no poller, no processes, no threads —
// because latte's core depends on it and latte's core is built for that target
// to hold the same line. A container that grew an import of std.fs would break
// latte's wasm leg, in latte's repo, for a reason that lives here. This leg
// makes the failure land where the cause is.
//
// `tests/_wasm_negative.b` is the control: it imports the things this must
// refuse, and the leg is worthless if that one is ever accepted.
package main

import barista

pub class Probe { pub fn init() {} }

fn main() {
    let services: barista.ServiceCollection = new barista.ServiceCollection()
    let added: Result<bool> = services.transient<Probe>()
    let root: barista.ServiceProvider = services.build_provider()
    let closed: Result<bool> = root.close()
}
