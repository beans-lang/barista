// The negative control for the wasm leg.
//
// A check that silently skips when its input goes missing reads green for
// ever, even after what it was checking stops being true. Without this file,
// `_wasm_core.b` checking clean would prove nothing the day the freestanding
// refusal broke. This file imports exactly what `wasm32-unknown-unknown` must
// refuse, and the gate FAILS if it is accepted.
package main

import barista
import std.fs
import std.net

fn main() {
    let services: barista.ServiceCollection = new barista.ServiceCollection()
    let root: barista.ServiceProvider = services.build_provider()
    match fs.read("nothing") {
        ok(_) => {}
        err(_) => {}
    }
    let closed: Result<bool> = root.close()
}
