# Source-backed data

Declare a managed source with `@ViewDataSource`. The macro owns the stable data instance, synchronous
seed, weak-owner callbacks, and a connection that lives with the model after startup. `AsyncContent`
requests connection automatically; other consumers use `connect()`. An optional `id` key path
selects when to rebind. This guide describes the `3.0.0-beta.1` prerelease.

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

The seed is the only application callback evaluated by a passive first read. Keep it cheap: read
an already-held snapshot rather than starting work. A test assertion or derived property can be
that first reader, so install seed dependencies before accessing the property. See
[Testing source-backed models](testing.md) and [Dependency context](dependency-context.md).

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
connection even if its initial presentation is hidden. Connect explicitly whenever updates must
start before that `AsyncContent` renders:

| Consumer or requirement | Startup |
| --- | --- |
| An `AsyncContent` that renders immediately | Automatic, including initially hidden presentation |
| A badge or other `latestValue`/`phase`-only consumer | `connect()` from model startup |
| Content behind a condition derived from the source | Connect before evaluating the gate |
| A nested section that should load alongside its parent | Connect both from model startup |
| A conditional chart or section that only needs updates when shown | Automatic when its `AsyncContent` renders |
| Data needed before the first render | Connect from model startup, or await `reload()` when requesting work |
| A test exercising a stream without rendering | Connect explicitly and synchronize with the fixture |
| A test exercising only a seed or injected presentation | Leave the source dormant |

Nesting alone does not require eager connection. Choose it when waiting for the parent or a
conditional branch to render would delay required updates. A warm seed can look correct while
its source remains dormant; reading it does not guarantee freshness.

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

## Migrate from v2

- Replace `ViewDataContext.bind(...)` registrations with `@ViewDataSource` declarations. Remove
  the context property and the tasks that installed those registrations.
- Move source-backed seeds into `initial: { owner in ... }`. For unmanaged data, replace
  `ViewData(value)` with `ViewData(.available(value))`; use `.unavailable` or `ViewData()` for empty state.
- Project observable selection inputs through `id`; keep source construction in untracked `make`.
- Let `AsyncContent` request connection automatically, or use synchronous `connect()` from startup
  for updates needed before rendering. The owning model controls teardown; there is no context-level
  `cancel` or `cancelAll` registration API.
- Replace `await context.load(operation, to: data)` with `await data.load(operation)` and
  `context.reload(data)` with `await data.reload()`. Use `await Ensemble.reload(...)` for independent
  concurrent screen requests.
- Map `.resubscribe` to an omitted `refresh` argument, `.refresh(action)` to an owner-aware
  `refresh: { owner in await owner.reload() }`, and `.disabled` to `allowsReload: false` on the macro.
  Hot refresh closures should await the producer's actual work.
- Replace `transitionAnimation:` on `AsyncContent` with `.phaseAnimation(...)` on the instance or
  an enclosing view. Phase animation is now opt-in; same-phase content animation remains caller-owned.

The Source lifecycle sample changes an explicit source identity and lets Observation rebind it while rows
remain visible. Package tests cover dependency scope, input changes, stale callbacks, seeds, weak
owners, cancellation, reload, and hosted SwiftUI rendering.

Next: [Testing](testing.md) · [Dependency context](dependency-context.md) · [Sources and lifecycle](sources-and-lifecycle.md)
