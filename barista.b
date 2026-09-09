// barista — the dependency-injection container for the Beans ecosystem.
//
// It was `espresso/di.b`, and it is here because a container is not a web
// framework's business: `latte` wants one for its pages and view-models, and a
// desktop toolkit would want the same one without taking an HTTP server with
// it. What moved is the whole container; what stayed behind in espresso is the
// one function that knew about `WebApplicationBuilder`.
//
// **This file imports `std.reflect` and nothing else, and must keep doing so.**
// latte's core is compiled for `wasm32-unknown-unknown` to hold the line that
// it imports no `std.fs`, `std.net` or `std.io`; a container latte's core
// depends on inherits that. `test.sh --wasm` holds it here too, so the failure
// lands in this repo rather than in a consumer's.
package barista

import std.reflect

/// Lifetime of a dependency registered in a barista container.
pub enum ServiceLifetime {
    transient
    scoped
    singleton
}

/// Marks a class for `add_services` discovery. The class registers as
/// itself and as each interface it directly implements, under the given
/// lifetime. Discovery is opt-in sugar over explicit registration —
/// the composition root stays the place to look when it matters.
///
/// The qualified name is `barista.service`, and `add_services` matches on
/// exactly that string. A consumer that used to write `@espresso.service`
/// writes `@barista.service` now; there is no alias, because two names for one
/// annotation is two things to keep in step.
@target(value: ["type"])
@retention(value: "runtime")
pub annotation service {
    lifetime: ServiceLifetime = ServiceLifetime.scoped
}

/// A service that owns something the garbage collector will not close.
///
/// `deinit` is the wrong place for it, and not as a matter of taste: a
/// destructor may not park, so anything that closes a socket is explicit
/// teardown (`spec/SYNTAX.md`), and — worse for a container specifically — an
/// object that dies **inside a reference cycle never runs its `deinit` at
/// all**. A service graph is exactly where cycles form. So a service with a
/// resource implements this, and the scope that made it calls `dispose` when
/// it closes, in reverse creation order.
///
/// `dispose` must be safe to call once. The container calls it exactly once
/// per instance per scope and then drops its reference.
pub interface Disposable {
    fn dispose()
}

/// Call `dispose` on a stored service if it wants one.
///
/// The downcast source is a `reflect.Value`, which is the lowering that copies
/// out by type name and handles an interface target; an ordinary object
/// downcast to an interface does not build natively at all
/// (beans-lang/beans#195). `tests/dispose.b` proves this path on both backends,
/// with a non-Disposable control beside it.
fn dispose_stored(value: reflect.Value) {
    match value as? Disposable {
        some(resource) => { resource.dispose() }
        none => {}
    }
}

class ServiceDescriptor {
    service_type: reflect.Type
    implementation_type: reflect.Type
    lifetime: ServiceLifetime
    factory: fn(ServiceProvider) -> Result<reflect.Value>

    fn init(service_type: reflect.Type,
            implementation_type: reflect.Type,
            lifetime: ServiceLifetime,
            factory: fn(ServiceProvider) -> Result<reflect.Value>) {
        self.service_type = service_type
        self.implementation_type = implementation_type
        self.lifetime = lifetime
        self.factory = factory
    }
}

/// Everything `activate` needs to know about one implementation type, worked
/// out once and kept.
///
/// The lookup this replaces was 137 ns of a 740 ns resolve, paid on **every**
/// activation, and `initializer.parameters()` with a `passing()` and a `type()`
/// per parameter was paid on top of it. None of that can change while a program
/// runs: a type's initializer, its visibility and its parameter list are fixed
/// at compile time.
///
/// A type that cannot be activated caches its reason too. Re-deriving the
/// message costs exactly the reflection the plan exists to avoid, and a type
/// that had no public initializer a moment ago will not have grown one.
class ActivationPlan {
    initializer: Option<reflect.Initializer> = none
    parameters: List<reflect.Type> = []
    fault: string = ""
    fault_kind: string = ""
    fn init() {}
}

/// The registrations, and the reflection cache that hangs off them.
///
/// **Last registration wins**, and that is now a rule rather than an accident.
/// It used to fall out of a reverse linear scan over a `List` — the same answer,
/// arrived at in O(n) string comparisons per resolve, and true only for as long
/// as nobody changed the direction of the loop.
///
/// One registry is shared by the root provider and every scope it makes
/// (`create_scope` passes this reference along), so the cache below is filled
/// once for the whole graph rather than once per request.
class ServiceRegistry {
    by_name: Map<string, ServiceDescriptor> = {}
    plans: Map<string, ActivationPlan> = {}

    fn add(descriptor: ServiceDescriptor) {
        self.by_name[descriptor.service_type.qualified_name()] = descriptor
    }

    fn find(name: string) -> Option<ServiceDescriptor> {
        return self.by_name.get(name)
    }

    fn count() -> int { return self.by_name.len() }

    /// The plan for one implementation type, computed on first use.
    fn plan_for(implementation: reflect.Type) -> ActivationPlan {
        let name: string = implementation.qualified_name()
        match self.plans.get(name) {
            some(found) => { return found }
            none => {}
        }
        var plan: ActivationPlan = new ActivationPlan()
        match implementation.initializer() {
            none => {
                plan.fault = "service {name} has no initializer"
                plan.fault_kind = "service_constructor"
            }
            some(found) => {
                if !found.is_public() {
                    plan.fault = "service {name} initializer is not public"
                    plan.fault_kind = "service_constructor"
                } else {
                    for parameter: reflect.Parameter in found.parameters() {
                        if plan.fault != "" { continue }
                        if parameter.passing() != reflect.Passing.borrowed {
                            plan.fault =
                                "service constructor parameter {parameter.name()} must be borrowed"
                            plan.fault_kind = "service_constructor"
                        } else {
                            plan.parameters.push(parameter.type())
                        }
                    }
                    if plan.fault == "" { plan.initializer = some(found) }
                }
            }
        }
        self.plans[name] = plan
        return plan
    }
}

class SingletonStore {
    values: Map<string, reflect.Value> = {}
    creation_order: List<string> = []

    fn put(name: string, value: reflect.Value) {
        if !self.values.contains_key(name) {
            self.creation_order.push(name)
        }
        self.values[name] = value
    }

    fn close() {
        var index: int = self.creation_order.len()
        for index > 0 {
            index -= 1
            let name: string = self.creation_order[index]
            match self.values.get(name) {
                some(value) => { dispose_stored(value) }
                none => {}
            }
            self.values.remove(name)
        }
        self.creation_order.clear()
    }
}

/// Registrations collected while an Espresso application is built.
pub class ServiceCollection {
    registry: ServiceRegistry = new ServiceRegistry()
    built: bool = false

    pub fn init() {}

    fn add_descriptor(descriptor: ServiceDescriptor) -> Result<bool> {
        if self.built {
            return err("services cannot be changed after the provider is built", "services_built")
        }
        if !descriptor.service_type.is_assignable_from(
                descriptor.implementation_type) {
            return err(
                "{descriptor.implementation_type.qualified_name()} cannot be used as {descriptor.service_type.qualified_name()}",
                "service_type")
        }
        self.registry.add(descriptor)
        return ok(true)
    }

    /// Registers a concrete implementation for a service type. Constructor
    /// parameters are resolved from the same provider when the service is made.
    pub fn add(service_type: reflect.Type,
               implementation_type: reflect.Type,
               lifetime: ServiceLifetime) -> Result<bool> {
        let factory: fn(ServiceProvider) -> Result<reflect.Value> =
            fn(provider: ServiceProvider) -> Result<reflect.Value> {
                return provider.activate(implementation_type)
            }
        return self.add_descriptor(new ServiceDescriptor(
            service_type, implementation_type, lifetime, factory))
    }

    /// Registers I as the implementation of S:
    /// `services.add_transient<Clock, SystemClock>()`. The runtime-typed
    /// `add` stays as the escape hatch for types only known at runtime —
    /// which is what the controller scanner itself uses.
    pub fn add_transient<S, I>() -> Result<bool> {
        return self.add(type_of(S), type_of(I),
                        ServiceLifetime.transient)
    }

    pub fn add_scoped<S, I>() -> Result<bool> {
        return self.add(type_of(S), type_of(I),
                        ServiceLifetime.scoped)
    }

    pub fn add_singleton<S, I>() -> Result<bool> {
        return self.add(type_of(S), type_of(I),
                        ServiceLifetime.singleton)
    }

    /// Registers a concrete type as itself:
    /// `services.transient<Greeter>()`.
    pub fn transient<T>() -> Result<bool> {
        return self.add(type_of(T), type_of(T),
                        ServiceLifetime.transient)
    }

    pub fn scoped<T>() -> Result<bool> {
        return self.add(type_of(T), type_of(T),
                        ServiceLifetime.scoped)
    }

    pub fn singleton<T>() -> Result<bool> {
        return self.add(type_of(T), type_of(T),
                        ServiceLifetime.singleton)
    }

    /// Register `service_type` so that resolving it resolves
    /// `implementation_type` instead — one instance shared across every name
    /// it answers to.
    ///
    /// This is what an interface registration is: `Clock` and `SystemClock`
    /// name the same instance in one scope, rather than two instances that
    /// happen to have the same fields. `add_services` builds every interface
    /// row this way, and it is `pub` so a host writing its own scanner does
    /// not need `ServiceDescriptor` — which is the only reason that class
    /// would ever have had to leave this file.
    pub fn add_forwarded(service_type: reflect.Type,
                         implementation_type: reflect.Type,
                         lifetime: ServiceLifetime) -> Result<bool> {
        let concrete: reflect.Type = implementation_type
        return self.add_descriptor(new ServiceDescriptor(
            service_type, implementation_type, lifetime,
            fn(provider: ServiceProvider) -> Result<reflect.Value> {
                return provider.resolve_type(concrete)
            }))
    }

    /// Freezes registrations and creates the root provider.
    ///
    /// **Singletons stay lazy, and that is a decision.** Building them here
    /// would move every construction failure to startup, which is the shape
    /// the rest of this ecosystem prefers — but it would also change what
    /// `singleton service cannot capture scoped service` means, from an error
    /// at the resolve that asked for it to an error at the line that built the
    /// provider, and `tests/container.b` asserts the first. The usual argument
    /// for eager construction is a lock-free first use across threads, and
    /// that is already answered by ownership rather than by timing: espresso
    /// gives every worker its own graph (`serve_workers.b`), so a "singleton"
    /// is per graph, and two threads never race one `SingletonStore`. If a
    /// host ever shares one graph across threads, this is the line to revisit
    /// — and it needs a lock, not just eagerness.
    pub fn build_provider(validate_scopes: bool = true) -> ServiceProvider {
        self.built = true
        return new ServiceProvider(
            self.registry, new SingletonStore(), true, validate_scopes)
    }
}

/// One dependency-injection scope. Create one child scope per HTTP request.
pub class ServiceProvider {
    registry: ServiceRegistry
    singletons: SingletonStore
    scoped_values: Map<string, reflect.Value> = {}
    scoped_order: List<string> = []
    resolving: List<string> = []
    root: bool
    validate_scopes: bool
    singleton_depth: int = 0
    closed: bool = false

    fn init(registry: ServiceRegistry,
            singletons: SingletonStore,
            root: bool,
            validate_scopes: bool) {
        self.registry = registry
        self.singletons = singletons
        self.root = root
        self.validate_scopes = validate_scopes
    }

    pub fn create_scope() -> Result<ServiceProvider> {
        if self.closed { return err("the service provider is closed", "closed") }
        return ok(new ServiceProvider(
            self.registry, self.singletons, false, self.validate_scopes))
    }

    /// Whether anything is registered at all.
    ///
    /// `pub` because a host asks it per request: espresso skips opening a
    /// scope entirely for an application that registered no services, and that
    /// guard is the difference between a DI-free app allocating a scope per
    /// request and allocating none.
    pub fn has_registrations() -> bool {
        return self.registry.count() != 0
    }

    /// Close this provider if it is a scope; do nothing if it is the root.
    ///
    /// `pub` because a host releases a request scope from code that does not
    /// know whether one was opened — espresso's `HttpContext.close()` is
    /// called on the normal path, the error path and the contained-panic path
    /// alike, and closing the root there would tear the application down.
    pub fn close_scope() -> Result<bool> {
        if self.root { return ok(true) }
        return self.close()
    }

    fn resolving_contains(name: string) -> bool {
        for active: string in self.resolving {
            if active == name { return true }
        }
        return false
    }

    fn cache_scoped(name: string, value: reflect.Value) {
        if !self.scoped_values.contains_key(name) {
            self.scoped_order.push(name)
        }
        self.scoped_values[name] = value
    }

    // Undoes the `resolving` push and `singleton_depth` bump that resolve_type
    // made around the factory call. It runs from a defer, so it fires on the
    // normal return, on a `?` error, and on a contained-panic unwind alike; the
    // length guard keeps a would-be empty-list remove from turning that unwind
    // into a fatal second panic.
    fn leave_resolving(is_singleton: bool) {
        if self.resolving.len() > 0 {
            self.resolving.remove(self.resolving.len() - 1)
        }
        if is_singleton { self.singleton_depth -= 1 }
    }

    fn descriptor(name: string) -> Result<ServiceDescriptor> {
        match self.registry.find(name) {
            some(found) => { return ok(found) }
            none => {
                return err("service {name} is not registered", "service_missing")
            }
        }
    }

    /// Whether anything is registered under this service type.
    ///
    /// A registry lookup and nothing else — it does not construct, resolve, or
    /// validate a scope. It exists so a framework can check a whole graph of
    /// declared dependencies **at startup**, and refuse there, instead of
    /// discovering at render time that a field it was going to fill has no
    /// answer. A question that has to build the object to be asked is not a
    /// question you can ask about two hundred components.
    pub fn provides(service_type: reflect.Type) -> bool {
        return self.registry.find(service_type.qualified_name()).is_some()
    }

    /// Resolve a service named by a runtime `reflect.Type`, boxed.
    ///
    /// `pub`, and the runtime-typed counterpart to `resolve<T>()` — the same
    /// escape hatch `add` is to `add_scoped<S, I>()`. A framework that binds a
    /// handler parameter, or activates a type it scanned, holds a
    /// `reflect.Type` and no static `T` to name; without this it could not ask
    /// at all. Downcast the answer with `as?`.
    pub fn resolve_type(service_type: reflect.Type) -> Result<reflect.Value> {
        if self.closed { return err("the service provider is closed", "closed") }
        let name: string = service_type.qualified_name()
        let descriptor: ServiceDescriptor = self.descriptor(name)?

        match descriptor.lifetime {
            singleton => {
                match self.singletons.values.get(name) {
                    some(value) => { return ok(value) }
                    none => {}
                }
            }
            scoped => {
                if self.root && self.validate_scopes {
                    return err("scoped service {name} cannot be resolved from the root provider", "scope")
                }
                if self.singleton_depth > 0 && self.validate_scopes {
                    return err("singleton service cannot capture scoped service {name}", "scope")
                }
                match self.scoped_values.get(name) {
                    some(value) => { return ok(value) }
                    none => {}
                }
            }
            transient => {}
        }

        if self.resolving_contains(name) {
            return err("dependency cycle while resolving {name}", "service_cycle")
        }

        self.resolving.push(name)
        let is_singleton: bool =
            descriptor.lifetime == ServiceLifetime.singleton
        if is_singleton { self.singleton_depth += 1 }
        // `descriptor.factory` runs a user constructor, which can panic; the
        // espresso server brews every handler, so that panic is contained and
        // unwinds this frame. Release the resolve bookkeeping in a defer rather
        // than straight-line after the call — otherwise a stranded name in
        // `resolving` makes the next resolve a false "dependency cycle", and a
        // stuck `singleton_depth` makes the next scoped resolve a false
        // "singleton cannot capture scoped". The defer fires on the normal
        // return, on the `?` error path, and on the unwind, all three.
        defer self.leave_resolving(is_singleton)

        let value: reflect.Value = descriptor.factory(self)?
        match descriptor.lifetime {
            singleton => { self.singletons.put(name, value) }
            scoped => { self.cache_scoped(name, value) }
            transient => {}
        }
        return ok(value)
    }

    /// Constructs `implementation` by calling its public initializer with
    /// every parameter resolved from this provider. The type itself needs no
    /// registration — only its constructor's parameters do — so a framework
    /// that mounts caller-written types (a page component, a handler object)
    /// gets constructor injection without turning every one of them into a
    /// service. The result is boxed; downcast it with `as?`.
    ///
    /// Every constructor parameter must be borrowed, and the initializer must
    /// be public; either failure is reported here rather than at the call.
    pub fn activate(implementation: reflect.Type) -> Result<reflect.Value> {
        let plan: ActivationPlan = self.registry.plan_for(implementation)
        if plan.fault != "" { return err(plan.fault, plan.fault_kind) }
        var arguments: List<reflect.Value> = []
        for parameter_type: reflect.Type in plan.parameters {
            arguments.push(self.resolve_type(parameter_type)?)
        }
        match plan.initializer {
            some(initializer) => {
                match initializer.call(move arguments) {
                    ok(value) => { return ok(value) }
                    err(problem) => {
                        return err(
                            "cannot construct {implementation.qualified_name()}: {problem.message()}",
                            "service_constructor")
                    }
                }
            }
            // Unreachable: a plan with no initializer carries a fault, and the
            // line above returned on it. Named rather than left to fall off the
            // end, so a future edit that adds a third plan state fails here
            // instead of silently answering something else.
            none => {
                return err(
                    "service {implementation.qualified_name()} has no initializer",
                    "service_constructor")
            }
        }
    }

    /// Resolves one service by its registered type:
    /// `let store: Store = context.services.resolve<Store>()?`.
    pub fn resolve<T>() -> Result<T> {
        let boxed: reflect.Value = self.resolve_type(type_of(T))?
        match boxed as? T {
            some(value) => { return ok(value) }
            none => {
                return err(
                    "registered service cannot be converted to {type_of(T).qualified_name()}",
                    "service_type")
            }
        }
    }

    /// Releases scoped services in reverse creation order. Closing the root
    /// provider also releases singleton services in reverse creation order.
    ///
    /// A service that implements `Disposable` has `dispose()` called before it
    /// is dropped — in that same reverse order, so a service can still use
    /// something it was built from while it closes.
    pub fn close() -> Result<bool> {
        if self.closed { return err("the service provider is closed", "closed") }
        var index: int = self.scoped_order.len()
        for index > 0 {
            index -= 1
            let name: string = self.scoped_order[index]
            match self.scoped_values.get(name) {
                some(value) => { dispose_stored(value) }
                none => {}
            }
            self.scoped_values.remove(name)
        }
        self.scoped_order.clear()
        if self.root { self.singletons.close() }
        self.closed = true
        return ok(true)
    }
}

/// Registers a factory. T is inferred from the factory's declared result type.
pub fn add_factory<T>(services: ServiceCollection,
                      lifetime: ServiceLifetime,
                      factory: fn(ServiceProvider) -> Result<T>) -> Result<bool> {
    let service_type: reflect.Type = type_of(T)
    let erased: fn(ServiceProvider) -> Result<reflect.Value> =
        fn(provider: ServiceProvider) -> Result<reflect.Value> {
            let made: T = factory(provider)?
            return ok(reflect.value(move made))
        }
    return services.add_descriptor(new ServiceDescriptor(
        service_type, service_type, lifetime, erased))
}

pub fn add_transient_factory<T>(services: ServiceCollection,
                                factory: fn(ServiceProvider) -> Result<T>) -> Result<bool> {
    return add_factory(services, ServiceLifetime.transient, factory)
}

pub fn add_scoped_factory<T>(services: ServiceCollection,
                             factory: fn(ServiceProvider) -> Result<T>) -> Result<bool> {
    return add_factory(services, ServiceLifetime.scoped, factory)
}

pub fn add_singleton_factory<T>(services: ServiceCollection,
                                factory: fn(ServiceProvider) -> Result<T>) -> Result<bool> {
    return add_factory(services, ServiceLifetime.singleton, factory)
}

fn scanned_service_annotation(
    type: reflect.Type) -> Option<reflect.Annotation> {
    for annotation: reflect.Annotation in type.annotations() {
        if annotation.qualified_name() == "barista.service" {
            return some(annotation)
        }
    }
    return none
}

fn scanned_service_lifetime(
    annotation: reflect.Annotation) -> Result<ServiceLifetime> {
    match annotation.argument("lifetime") {
        some(argument) => {
            let name: string = argument.value().text()
            if name == "transient" {
                return ok(ServiceLifetime.transient)
            }
            if name == "scoped" { return ok(ServiceLifetime.scoped) }
            if name == "singleton" {
                return ok(ServiceLifetime.singleton)
            }
            return err("unknown service lifetime '{name}'", "service")
        }
        none => { return ok(ServiceLifetime.scoped) }
    }
}

/// Registers every linked `@service` class: as itself, and as each interface
/// it directly implements, forwarded so one scope shares one instance across
/// all of its names.
///
/// Two `@service` classes claiming the same service type is an error here, not
/// a silent override — drop `@service` from one and register your choice
/// explicitly. Call before the provider is built.
///
/// **What it will not see.** `type.interfaces()` answers the interfaces a
/// class *directly declares*, and the runtime's assignability walk does not
/// climb from one interface to another it extends. So a
/// `class C implements Named`, where `interface Named extends Shape`,
/// registers under `C` and `Named` and **not** under `Shape`. Register that
/// one by hand with `add_forwarded` if you need it. This is a limit of the
/// runtime's interface registry, not a choice made here, and it is stated
/// rather than papered over because the symptom otherwise is a resolve that
/// fails at startup naming a type the author can see is implemented.
pub fn add_services(services: ServiceCollection) -> Result<int> {
    return add_services_except(
        services, fn(type: reflect.Type) -> Option<string> { return none })
}

/// `add_services`, with a veto.
///
/// `reject` is asked about every `@service` type before it is registered and
/// answers `some(reason)` to refuse it. It exists because a host may already
/// treat some classes as services by another route and needs the double
/// registration to be an error rather than a surprise — espresso refuses
/// `@service` on a `@controller` for exactly that reason. barista itself knows
/// about no such category, which is why the knob is a closure and not a list.
pub fn add_services_except(
        services: ServiceCollection,
        reject: fn(reflect.Type) -> Option<string>) -> Result<int> {
    var count: int = 0
    var claimed: Map<string, string> = {}
    for type: reflect.Type in reflect.types() {
        match scanned_service_annotation(type) {
            none => {}
            some(marker) => {
                let shown: string = type.qualified_name()
                if type.kind() != reflect.Kind.class_type {
                    return err(
                        "@service can only mark a class, got {shown}",
                        "service")
                }
                match reject(type) {
                    some(reason) => { return err(reason, "service") }
                    none => {}
                }
                if type.initializer().is_none() {
                    return err(
                        "@service class {shown} has no public initializer the container can call — a `singleton class`, an abstract class or a closed generic is one way to get here, and each registers through a factory (add_singleton_factory) instead",
                        "service")
                }
                let lifetime: ServiceLifetime =
                    scanned_service_lifetime(marker)?
                var surfaces: List<reflect.Type> = [type]
                for implemented: reflect.Type in type.interfaces() {
                    surfaces.push(implemented)
                }
                for surface: reflect.Type in surfaces {
                    let name: string = surface.qualified_name()
                    match claimed.get(name) {
                        some(owner) => {
                            return err(
                                "service {name} is provided by both {owner} and {shown} — drop @service from one and register your choice explicitly",
                                "service_conflict")
                        }
                        none => {}
                    }
                    claimed[name] = shown
                    if name == shown {
                        services.add(surface, type, lifetime)?
                    } else {
                        // Interface names forward to the concrete
                        // registration, so a scope resolves the same
                        // instance under every name.
                        services.add_forwarded(surface, type, lifetime)?
                    }
                }
                count += 1
            }
        }
    }
    return ok(count)
}
