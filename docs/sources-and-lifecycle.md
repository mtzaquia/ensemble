# Sources and lifecycle

A `@ViewDataSource` declaration owns stable presentation state and a source connection for its
model's lifetime. First access activates it. Views, badges, and derived conditions read the same
data without subscription tasks, observation modifiers, or consumer leases.

## Activate on first access

```swift
@ViewDataSource(
  initial: { (model: Self) in model.useCase.cachedAvailability },
  make: { model in model.useCase.values() },
  refresh: { model in await model.useCase.reload() }
)
@ObservationIgnored
var entries: ViewData<[Entry]>
```

Constructing the model starts no work. The first property access evaluates the seed synchronously
and schedules source activation after the getter returns, outside view-body evaluation. The factory
must return promptly; expensive work belongs to its producer. An immediate `reload()` coordinates
with that activation. Every later read returns the same data and shares the same connection.

A badge can read `model.entries.latestValue` directly. A condition derived from that value activates
the source even when the condition prevents `AsyncContent` from being constructed. `AsyncContent`
controls rendering, loading policy, and failure policy; it has no source-lifecycle responsibilities.

## Model lifetime and reset

After activation, hiding a section, navigating away, or finishing a reload does not disconnect its
source while the model is retained. Choose model scope deliberately: a retained tab model or an
application-wide model keeps its accessed sources running. Entering the background does not release
that model. Producer-specific suspension and background execution remain application concerns.

Releasing the model cancels its subscription and retry work and invalidates pending factory-input
callbacks. This also happens when another object retains its `ViewData`, sink, or retry action.
The retained data keeps its presentation, but source reload becomes inert. Models released before
scheduled activation runs start no source work.

Callbacks receive a weakly held owner and temporarily retain it while running, including an awaited
refresh. A task invoking an async model method can also keep that model alive until it returns.
Factories and returned sequences must avoid retaining their model for an endless subscription.
Cancellation is cooperative with the producer.

`reset()` clears presentation while leaving the model-owned source connected. Later updates may
replace the empty state. Successful empty collections and optional `nil` count as available values.

## Reload hot and cold sources

Without a refresh action, activation starts the cold sequence. The first explicit reload joins a
pending initial load that has not yet produced an update. Later reloads cancel the previous
subscription, invoke the factory again, and await sequence completion. A completed initial sequence
is ready for a new request; repeated property reads alone never restart it. Cold sources that fetch
on activation need no extra startup reload merely to obtain their first value.

With a refresh action, activation only subscribes. Reload keeps that subscription and awaits the
producer's action. If the sequence has completed, Ensemble reconnects before calling the action.
Hot factories must register their observation synchronously or buffer updates so an immediate
refresh cannot lose its result. Connections remain alive after the action returns, so queued and
ongoing updates continue to reach the data while its model lives. Action completion does not imply
that every streamed outcome has already been processed.

Connecting or rebinding never invokes a hot source's refresh action. Initial requests, caching,
and replay policy belong to the application or data layer. The synchronous seed guarantees
first-paint content independently of stream timing. Idle hot sources are not marked loading until
an explicit refresh; cold sources begin loading on activation. Reload preserves successful content.

## Reload several sources together

```swift
await Ensemble.reload(model.profile, model.activity, model.notifications)
```

The sources can hold different value types. This convenience calls each source's `reload()`
concurrently through a task group and awaits all actions, with the same behavior as individual
calls. Each source applies its own results, failures, and resets. A failure does not cancel its
siblings or throw from the batch; retry remains local. Completion means the actions finished,
not that every source succeeded or every stream outcome has been processed.

Cancellation propagates to outstanding actions and cold requests. It does not end the owning
models' lifetimes. Plain data, reload-disabled sources, an empty batch, and already-cancelled calls
perform no reload work. Accessing a reload-disabled property still activates its source normally.
Duplicate instances in one batch reload once.

### Overlapping requests

Separate reload calls do not coalesce after the pending initial cold load has been joined.
Hot sources may run their refresh action more than once; their producer decides how overlapping
work is handled. A later cold reload cancels and replaces the earlier request. Awaiting that earlier
request can finish while the newer request continues. Finishing one request does not stop another.

## Adapt source-specific updates

Use the macro's `receive` adapter to translate application-defined update types:

```swift
enum EntriesUpdate {
  case result(Result<[Entry], EntryFailure>)
  case invalidate
}

@ViewDataSource(
  make: { (model: Self) in model.useCase.updates() },
  refresh: { model in await model.useCase.reload() },
  receive: { _, update, sink in
    switch update {
    case .result(let result): sink.receive(result)
    case .invalidate: sink.reset()
    }
  }
)
@ObservationIgnored
var entries: ViewData<[Entry]>
```

The handler runs on the main actor after the binding accepts the element. Its `ViewDataSink` is scoped
to that connection: retaining it does not let obsolete work update a replacement connection. Reset
clears presentation without stopping the source. A later source result can recover it.

Adapters receive the owner, element, and sink. Use `_` for an unused owner. Sink changes apply
synchronously, and reads made by the adapter do not become source-selection dependencies.
Set `allowsReload: false` on the macro to suppress programmatic reload and failure retry while
keeping activation and automatic rebinding.

## Track source-selection inputs

Changing observable properties read synchronously by the factory invalidates old results, sinks,
and retries immediately. Ensemble then rebuilds the subscription on the main actor using the
latest inputs. Several synchronous changes coalesce. The same data and successful content survive;
hot sources reconnect without invoking refresh.

Dependency tracking is renewed on every connection, including conditional branches. Completed
sequences still track input changes while their model lives. Unread declarations stay dormant;
a first access selects the current inputs. Owner teardown disarms pending callbacks and prevents
further connections.

Use `reset()` before changing an account or another domain identity if the old value is no longer
appropriate. Seeds run once and are never reapplied on rebinding. See
[Source-backed data](source-backed-data.md#rebind-through-observable-inputs).

## Completion, errors, and cancellation

A failure element enters failure without ending the subscription, so a later success can recover
it. A thrown iteration error enters failure and completes the subscription. Producer cancellation
is not presented as a failure. Empty completion or cancellation settles loading to its preceding
failure, retained success, or empty state. A previously emitted result keeps its phase.

Reload can reconnect a completed sequence. Cancelling an awaited cold reload stops that request
and rejects its retained sinks; factory-input tracking remains active for future input changes.
Cancelling a hot refresh leaves its model-owned subscription intact. Owner teardown removes retry
and settles only that connection's loading transition. Connection revisions reject obsolete updates
without settling a newer one-shot load or replacement request.

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

`reset()` changes presentation only. Releasing the owning model stops its sources. Cancel the task
awaiting `load` to stop that one-shot operation.

Next: [Source-backed data and macros](source-backed-data.md) · [Diagnostics](diagnostics.md)
