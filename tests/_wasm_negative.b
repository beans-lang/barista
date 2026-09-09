// The negative control for the wasm leg.
//
// Without it, `_wasm_core.b` checking clean proves nothing the day the
// freestanding refusal stops working — the leg would go green and stay green
// for ever (RULES.md 5). This file imports exactly what
// `wasm32-unknown-unknown` must refuse, and the gate FAILS if it is accepted.
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
