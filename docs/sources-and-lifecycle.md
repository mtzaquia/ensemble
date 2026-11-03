# Sources and lifecycle

Each `ViewData` owns one source binding. That binding holds the factory, refresh policy, active
subscription, and retry action. Consumers acquire observation leases; the last lease ending stops
the subscription while preserving successful presentation state and source configuration.

## Connect and observe

Use a source-aware initializer or the optional `@ViewDataSource` property macro:

```swift
let entries = ViewData(
  cachedAvailability,
  make: useCase.values,
  refresh: useCase.reload,
  initialRefresh: .whenUnavailable
)
```

The factory stays dormant during initialization. `AsyncContent(entries)` observes automatically.
For work outside rendered content, explicitly observe within a task:

```swift
.task {
  await model.entries.observe()
}
```

`observe()` waits until cancellation, even after a sequence completes, so a later reload can create
a fresh subscription. Multiple observers share one connection. Cancel each task to release its lease;
cancelling one does not interrupt the others. Plain data without a source returns immediately.

Automatic leases follow SwiftUI state lifetime rather than strict visibility. Offscreen views whose
state SwiftUI retains can continue observing. Releasing or rebinding the consumer's lifecycle storage
ends its lease.

## Reload hot and cold sources

With no refresh action, a reload cancels the previous subscription and invokes the factory again.
Use a cold request sequence that creates independent work for each subscription.

With a refresh action, reload keeps an active subscription and signals its producer. If the previous
sequence completed, Ensemble reconnects before calling the action. Hot factories must establish
observation synchronously or buffer events before iteration starts. The factory is invoked before
initial refresh, but Ensemble cannot await arbitrary upstream registration.

`initialRefresh` controls only the hot refresh action at each connection:

| Policy | Refresh on connection |
| --- | --- |
| `.always` | Always, including with successful retained data |
| `.whenUnavailable` | Only without a successful value |
| `.never` | Never; only register observation |

Successful empty collections and optional `nil` count as available. An idle hot source is not marked
loading unless a refresh is requested. Cold sources begin loading on connection. Explicit reload
marks the data loading and preserves its latest successful value.

## Adapt source-specific updates

Use the initializer's `receive` overload to translate other update types without erasing values:

```swift
enum EntriesUpdate {
  case result(Result<[Entry], EntryFailure>)
  case invalidate
}

let entries = ViewData<[Entry]>(
  cachedAvailability,
  make: useCase.updates,
  reload: .refresh(useCase.reload),
  initialRefresh: .whenUnavailable
) { update, sink in
  switch update {
  case .result(let result):
    sink.receive(result)
  case .invalidate:
    sink.reset()
  }
}
```

The handler runs on the main actor after the binding accepts the element. Its `ViewDataSink` is scoped
to that connection: retaining it does not let obsolete work update a replacement connection. Reset
clears presentation without stopping observation. A later source result can recover it.

Custom adapters use `ViewDataReloadBehavior`: `.resubscribe`, `.refresh(action)`, or `.disabled`.
Disabled sources expose no programmatic reload or failure retry action. Use the same `receive`
overload on `replaceSource` when changing an adapted producer.

## Replace a source

```swift
entries.replaceSource(make: replacement.values, refresh: replacement.reload)
```

Replacement cancels the old subscription, invalidates its sink and retry action, and reconnects active
observers immediately. Inactive data retains the new factory until observed. The original
`initialRefresh` policy remains fixed; replacement accepts neither a new seed nor a policy.

The successful value stays in the same `ViewData` and is visible to every consumer. Reserve
`reset()` for explicit invalidation, such as changing accounts. Replacing the `ViewData` instance
itself creates fresh presentation state; `AsyncContent` does not copy content between instances.

## Completion, errors, and cancellation

A failure element enters failure without ending observation, so a later success can recover it. A
thrown iteration error enters failure and completes the subscription. Producer cancellation is not
presented as a failure. Empty completion or cancellation settles loading to its preceding failure,
retained success, or empty state. A previously emitted result keeps its phase.

Reload can reconnect a completed subscription while consumers retain their observation leases.
Cancelling the last lease removes its retry action and settles only that connection's loading
transition. Connection revisions reject obsolete producer updates and retained retries or sinks.
Cancellation is cooperative with upstream work; producers must handle their own cleanup.

## Load one value

```swift
await entries.load {
  try await useCase.fetch()
}
```

A load runs in the caller's task and leaves any source subscription intact. A returned value becomes
the latest success; an error enters failure while preserving successful data. Loads and source results
apply in arrival order. Loading tokens ensure cancellation of an older operation cannot clear a
later operation's loading state or replace a newer result. A load does not install a retry action.

`reset()` changes presentation only. Cancel explicit observation tasks to stop their subscriptions,
and cancel the task awaiting `load` to stop its operation.

Next: [Source-backed data and macros](source-backed-data.md) · [Diagnostics](diagnostics.md)
