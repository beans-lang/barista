// Two `@service` classes claiming the same interface is an error at scan time,
// never a silent last-wins.
package main

import barista
import std.io

pub interface Mailer {
    fn send() -> string
}

@barista.service
pub class SmtpMailer implements Mailer {
    pub fn init() {}
    pub fn send() -> string { return "smtp" }
}

@barista.service
pub class LogMailer implements Mailer {
    pub fn init() {}
    pub fn send() -> string { return "log" }
}

fn main() {
    let services: barista.ServiceCollection = new barista.ServiceCollection()
    match barista.add_services(services) {
        ok(_) => { io.println("scan accepted") }
        err(problem) => { io.println("scan {problem.kind}: {problem.msg}") }
    }
}
