# Source-backed data

Declare a managed source with `@ViewDataSource`. The macro owns the stable data instance, synchronous
seed, weak-owner callbacks, and a connection that lives with the model after startup. `AsyncContent`
requests connection automatically; other consumers use `connect()`. An optional `id` key path
selects when to rebind. This guide describes the v3 development branch.

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

For a `make:` declaration, the seed is the only application callback evaluated by a passive
first read. Keep it cheap by reading an already-held snapshot. A test assertion or derived property
can be that first reader, so install seed dependencies before accessing the property. See
[Testing source-backed models](testing.md) and [Dependency context](dependency-context.md).

An `initial:` seed runs only on first access.
Successful empty collections and optional `nil` are available successes. Caching policy and the
projection used to obtain the snapshot stay in the application or data layer.

For manually managed presentation or one-shot loads, ordinary `ViewData()` and
`ViewData(availability)` remain available. Do not assign those values to a macro property; supply
its seed through `initial:`.

## Loadable sources

Use `updates:` when one producer owns its cached value, stream, and loading policy.
The factory returns that producer for Ensemble to keep for the selected identity.

```swift
@ViewDataSource(
  id: \.cardID,
  updates: { (model: Self) in model.purchases(for: model.cardID) }
)
@ObservationIgnored
var purchases: ViewData<[Purchase]>
```

Omit `id` for a fixed producer. A `ViewDataLoadableSource<Value>` provides its already-held
`availability`, a sequence through `viewDataUpdates()`, and `load(_:)`. Each subscription
needs an independent iterator. Ensemble creates the iterator before requesting work. A producer
that registers asynchronously should buffer or replay updates until the subscription is ready.

| Moment | Behavior |
| --- | --- |
| First property read | Create the producer and read its availability once. The producer stays dormant. |
| Connection | `AsyncContent`, `connect()`, or a first `reload()` subscribes and requests `.initial`. |
| Reload | Join an in-flight initial request, or await `.reload` on the current producer. |
| Failure retry | Request `.reload` on the current producer, including when the initial request is still in flight. |
| Completed subscription | A new reload or retry creates another iterator on the same producer before loading. |
| Identity change | For a connected source, cancel old work, create the new producer, apply its availability, subscribe, and request `.initial`. A dormant source resolves the current identity at connection. |
| Owner release | Cancel the subscription and all in-flight loads. Late outcomes and old sinks are ignored. |

The new identity's cached value is more appropriate than the previous identity's retained
success. An unavailable seed clears that success. `initial:` belongs to the `make:`
initializer. The `updates:` initializer always seeds from the producer.

The default adapter applies `ViewDataUpdate.result` as a success or retained-value failure.
A `.reset` clears presentation. Provide `receive` to handle native elements and owner-side
effects. The override is responsible for applying the outcome to its sink. Reload returns when
the producer's load returns, and streamed results may still arrive afterward.

### Adapt a third-party producer

Put the conformance in one app integration file that imports both libraries. The associated
sequence can have its own element type. An existing `AsyncSequence` can use the default
`viewDataUpdates()` implementation that returns `self`. Producers whose elements already
have type `ViewDataUpdate<Value>` also get a default implementation of `viewDataUpdate(for:)`.

```swift
import Continuum
import Ensemble

extension Composition: @retroactive ViewDataLoadableSource {
  public var availability: ViewDataAvailability<Output> {
    if case .result(.success(let value)) = latest { return .available(value) }
    return .unavailable
  }

  public func viewDataUpdate(for element: Element) -> ViewDataUpdate<Output> {
    switch element {
    case .result(let result): .result(result)
    case .reset: .reset
    }
  }

  public func load(_ request: ViewDataLoadRequest) async {
    await load(using: request == .initial ? .cached : .remote)
  }
}
```

This conformance covers every `Composition<Output>`. The policy choice is app-owned.
A Continuum `BucketPartition` can use the same pattern with `Space.Snapshot` and its
throwing `load(using:)`, which reports outcomes through observation. An unpartitioned
`Bucket` can supply its own snapshot directly. For a partitioned bucket, return the selected
partition and include its key in `id`. Declare each retroactive conformance only once across the
app and its dependencies. [Swift Evolution SE-0364](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0364-retroactive-conformance-warning.md)

See the [loadable sources sample](../SampleApp/README.md#loadable-sources) for a producer
implemented entirely in the SampleApp.

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

The same `ViewData` survives rebinding. A `make:` source also retains its latest successful value.
Hot sources only subscribe on rebinding. Cold producers may start work when subscribed.
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

Rebinding a `make:` source preserves success. Clear presentation before switching accounts when
old content is no longer appropriate.

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

Use `allowsReload: false` on a `make:` declaration to disable programmatic reload and
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
  entries.connect()
  badge.connect()
  permissions.connect()
}
```

`data.connect()` is synchronous and idempotent. Startup is scheduled
outside the current call stack; returning does not mean data has arrived or an arbitrary producer
is ready. Connection starts cold and loadable work. Hot sources only subscribe. `reload()` ensures
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
