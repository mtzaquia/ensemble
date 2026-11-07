# Source-backed data

Declare a managed source with `@ViewDataSource`. The macro owns the stable data instance, synchronous
seed, weak-owner callbacks, and a connection that lives with the model after startup. `AsyncContent`
requests connection automatically; other consumers use `connect()`. An optional `id` key path
selects when to rebind. This is unreleased v3 behavior on `zaquia/v3`.

## Declare the source once

```swift
@MainActor
@Observable
final class EntriesModel {
  let repository: EntriesRepository
  var selectedFilter = EntryFilter.all

  @ViewDataSource(
    id: \.selectedFilter,
    initial: { (model: Self) in model.repository.cachedAvailability },
    make: { model in model.repository.values(for: model.selectedFilter) },
    refresh: { model in await model.repository.reload(for: model.selectedFilter) }
  )
  @ObservationIgnored
  var entries: ViewData<[Entry]>

  init(repository: EntriesRepository) {
    self.repository = repository
  }
}
```

The declaration is the source configuration. The property must be a `var` explicitly typed as
`ViewData<Value>` on a main-actor class, with no property initializer. It becomes get-only; readers
always receive the same instance.

Use `(model: Self)` on `initial` or `make`; Swift infers the other callbacks' owner type, including
in generic models. Callbacks must be inline closures. The macro diagnoses direct instance `self`
and `super` captures; use the supplied parameter. Helpers and returned sequences remain responsible
for their own captures and cooperative cancellation.

In an `@Observable` model, put `@ObservationIgnored` after `@ViewDataSource` to prevent competing
accessor expansions. The containing model needs Observation when its mutable properties are source
inputs. A fixed source can live on an ordinary main-actor class, and inputs can also belong to an
observable collaborator read by the identity projection.

Each invocation must support a fresh subscription after cancellation. Create a new `AsyncStream`
per invocation, or return a reusable sequence whose iterator establishes an independent subscription.
Reusing one cancellation-sensitive stream does not satisfy that contract.

## Seed the first render

`initial` returns application-owned `ViewDataAvailability<Value>`. It runs synchronously once on the
first property read, before returning the data. Reading creates a dormant binding; it does not
start the producer. Omit it to start unavailable, or provide a fixed seed with
`initial: { _ in .available(cachedValue) }`.

The seed is not retained or reapplied after reset, reload, cancellation, or automatic rebinding.
Successful empty collections and optional `nil` are available successes. Caching policy and the
projection used to obtain the snapshot stay in the application or data layer.

For manually managed presentation or one-shot loads, ordinary `ViewData()` and
`ViewData(availability)` remain available. Do not assign those values to a macro property; supply
its seed through `initial:`.

## Rebind through connection identity

The key path above projects the `Equatable` `selectedFilter`. Changing it selects a new connection:

```swift
model.selectedFilter = .favorites
```

Keep mutable source-selection state on the main actor, including inputs on observable collaborators.

From connection until owner release, Ensemble tracks only the identity projection. When a tracked
input changes, it evaluates the identity again and compares outside the tracking scope. An equal
value preserves the connection, running requests, sinks, and retry while renewing the dependencies,
including conditional branches. A changed identity rejects obsolete callbacks and schedules a
replacement connection on the main actor. Identity is checked before accepting subsequent results,
sinks, retries, or reloads. Several synchronous changes can coalesce into one replacement.

`make` runs untracked, including synchronous reads and nested observation inside third-party
producers. Reads in `initial`, `refresh`, `receive`, and asynchronous iteration do not become
connection dependencies either. With no `id`, there is no automatic rebinding. Cold reloads and
retries invoke the latest factory; hot ones refresh the existing subscription, reconnecting if it
has completed.

The same `ViewData` and its latest successful value survive rebinding. Hot sources only subscribe;
rebinding does not invoke their refresh action. Cold producers may start work when subscribed.
A completed or failed sequence can rebind while its model remains alive.

Use a pure value identity containing every input that defines the subscription. For multiple inputs,
project a computed `Equatable` value:

```swift
struct ConnectionID: Equatable {
  let repository: ObjectIdentifier
  let filter: EntryFilter
}

var connectionID: ConnectionID {
  ConnectionID(repository: ObjectIdentifier(repository), filter: selectedFilter)
}
// On the declaration: id: \.connectionID
```

Include producer identity when the producer can be replaced. Ordinary or `@ObservationIgnored`
properties do not notify Observation. The projection must read the observable inputs that should
trigger reevaluation. For an upstream `ViewData`, project its domain ID rather than its phase:
loading, retained success, failure, and payload changes with the same ID then preserve the child
connection. An optional ID works when unavailable data has no selection.

Unconnected declarations start no work when their inputs change. After connection, tracking continues
through hidden UI and completed sequences. Releasing the model cancels the subscription and makes
pending callbacks inert, even if another object retains its `ViewData`. Ordinary reads never restart
a completed sequence.

## Change domain identity deliberately

Rebinding preserves success. Clear presentation before switching accounts when old content is no
longer appropriate:

```swift
func selectAccount(_ accountID: Account.ID) {
  entries.reset()
  selectedAccountID = accountID
}
```

The identity projection must read the observable `selectedAccountID`. The seed is not reapplied to
the new account; its producer can replay an appropriate snapshot on subscription. Environment-dependent
collaborators can be assigned to observable model inputs from an installation action. Do not
publish model mutations from a view's `body`.

## Adapt source-specific updates

Result streams need no adapter. For application-defined update types, translate them with the owner
and a connection-scoped sink:

```swift
@ViewDataSource(
  make: { (model: Self) in model.displayUser.updates() },
  refresh: { model in await model.displayUser.reload() },
  receive: { model, update, sink in
    switch update {
    case .result(let result):
      sink.receive(result)
      model.updateActions()
    case .reset:
      sink.reset()
    }
  }
)
@ObservationIgnored
var user: ViewData<DisplayUser>
```

Sink updates apply synchronously, so subsequent model methods can read the new `latestValue`.
Use `_` for unused parameters. Callbacks are skipped after owner release, and a skipped refresh
leaves presentation unchanged. Retaining a sink or retry does not let obsolete work update a new
connection. An iteration error enters failure; a failure element can recover through later results.

Use `allowsReload: false` for a passive source that should expose neither programmatic reload nor
failure retry. Connection and identity-driven rebinding still work.

## Connect without rendering

Plain property, phase, and latest-value reads stay passive. Rendering `AsyncContent` requests
connection even if its initial presentation is hidden. A condition that prevents `AsyncContent`
from being constructed needs startup elsewhere:

```swift
func start() {
  Ensemble.connect(entries, badge, permissions)
}
```

`data.connect()` and the batch convenience are synchronous and idempotent. Startup is scheduled
outside the current call stack; returning does not mean data has arrived or an arbitrary producer
is ready. Connection starts cold work but never invokes a hot refresh action. `reload()` ensures
connection itself when a request is needed before rendering.

Once connected, the source lives with the model. No consumer leases or view disappearance hooks
are needed. Repeated reads or connection requests do not restart a completed sequence.

Use `.onChange(of: data.latestValue)` for view-local reactions to `Equatable` state changes.
It does not connect the source and may coalesce updates. Use `receive` for each accepted source
event and model effects.

## Migrate to macro-owned sources

- Replace source-aware `ViewData` initializers with `@ViewDataSource` declarations.
- Move seed assignments and `initialValue:` macro arguments into `initial: { owner in ... }`.
- Project observable selection inputs through `id`; keep source construction in untracked `make`.
  Remove `replaceSource` calls and duplicated configuration. There is no public reconnect method.
- Remove `ViewDataContext` registration, startup binding tasks, explicit `observe()` calls, and
  consumer observation modifiers. `AsyncContent` requests connection automatically. Use synchronous
  `connect()` from startup for badges and conditional gates; the owning model controls teardown.
- Keep `await data.load(...)` for one-shot operations and `await Ensemble.reload(...)` for
  independent screen requests. These operations do not change source declarations.
- Replace reload-disabled initializer configuration with `allowsReload: false` on the macro.

The Source lifecycle sample changes an explicit source identity and lets Observation rebind it while rows
remain visible. Package tests cover dependency scope, input changes, stale callbacks, seeds, weak
owners, cancellation, reload, and hosted SwiftUI rendering.

Next: [Sources and lifecycle](sources-and-lifecycle.md) · [Presentation policies](presentation-policies.md)
