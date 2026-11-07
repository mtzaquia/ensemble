# Source-backed data

Declare a managed source with `@ViewDataSource`. The macro owns the stable data instance, synchronous
seed, weak-owner callbacks, and a connection that activates on first access and lives with the model. Observable inputs read by the factory automatically
select and rebind the source. This is unreleased v3 behavior on `zaquia/v3`.

## Declare the source once

```swift
@MainActor
@Observable
final class EntriesModel {
  let repository: EntriesRepository
  var selectedFilter = EntryFilter.all

  @ViewDataSource(
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
observable collaborator read by the factory.

Each invocation must support a fresh subscription after cancellation. Create a new `AsyncStream`
per invocation, or return a reusable sequence whose iterator establishes an independent subscription.
Reusing one cancellation-sensitive stream does not satisfy that contract.

## Seed the first render

`initial` returns application-owned `ViewDataAvailability<Value>`. It runs synchronously once on the
first property read, before returning the data. Source activation is scheduled after the getter
returns, so it does not publish presentation changes during view-body evaluation. Omit it to
start unavailable, or provide a fixed seed with `initial: { _ in .available(cachedValue) }`.

The seed is not retained or reapplied after reset, reload, cancellation, or automatic rebinding.
Successful empty collections and optional `nil` are available successes. Caching policy and the
projection used to obtain the snapshot stay in the application or data layer.

For manually managed presentation or one-shot loads, ordinary `ViewData()` and
`ViewData(availability)` remain available. Do not assign those values to a macro property; supply
its seed through `initial:`.

## Rebind through observable inputs

The factory above reads `selectedFilter`. Changing it is the complete rebinding action:

```swift
model.selectedFilter = .favorites
```

Keep mutable source-selection state on the main actor, including inputs on observable collaborators.

From activation until owner release, Ensemble tracks every observable property read synchronously
by `make`, including reads through computed properties and helper methods. An input mutation
immediately invalidates old results, retained sinks, and retries. A main-actor task then cancels the
old subscription and invokes the same factory with the completed, current inputs. Several changes
before that task runs share one rebind. Conditional factories track the branch they actually read
and establish a new dependency set on every connection.

The same `ViewData` and its latest successful value survive rebinding. Hot sources only subscribe;
rebinding does not invoke their refresh action. Cold producers may start work when subscribed.
A completed or failed sequence can rebind while its model remains alive.

Only synchronous factory reads establish dependencies. Reads in `initial`, `refresh`, `receive`, or
later asynchronous iteration do not. Read source-selection inputs in `make` before returning the
sequence. Ordinary properties and `@ObservationIgnored` inputs do not trigger rebinding. Keep
subscription bookkeeping and producer-internal state out of observable reads used by the factory.

Unread declarations start no work when their inputs change. After first access, tracking continues
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

The factory must read the observable `selectedAccountID`. The seed is not reapplied to the new
account; its producer can replay an appropriate snapshot on subscription. Environment-dependent
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
failure retry. Its first-access activation and input-driven rebinding still work.

## Migrate to macro-owned sources

- Replace source-aware `ViewData` initializers with `@ViewDataSource` declarations.
- Move seed assignments and `initialValue:` macro arguments into `initial: { owner in ... }`.
- Keep source selection in observable inputs read by `make`; remove `replaceSource` calls and
  duplicated configuration. There is no public reconnect method.
- Remove `ViewDataContext` registration, startup binding tasks, explicit `observe()` calls, and
  consumer observation modifiers. Ordinary property reads activate the source; the owning model
  controls teardown. `AsyncContent` only renders presentation state.
- Keep `await data.load(...)` for one-shot operations and `await Ensemble.reload(...)` for
  independent screen requests. These operations do not change source declarations.
- Replace reload-disabled initializer configuration with `allowsReload: false` on the macro.

The Source lifecycle sample changes a selected source and lets Observation rebind it while rows
remain visible. Package tests cover dependency scope, input changes, stale callbacks, seeds, weak
owners, cancellation, reload, and hosted SwiftUI rendering.

Next: [Sources and lifecycle](sources-and-lifecycle.md) · [Presentation policies](presentation-policies.md)
