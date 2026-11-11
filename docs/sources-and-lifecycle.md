# Sources and lifecycle

A `@ViewDataSource` declaration owns stable presentation state and a source connection for its
model's lifetime once connected. Views, badges, and derived conditions read the same
data without subscription tasks, observation modifiers, or consumer leases.

## Connect when needed

```swift
@ViewDataSource(
  initial: { (model: Self) in model.useCase.cachedAvailability },
  make: { model in model.useCase.values() },
  refresh: { model, _ in await model.useCase.reload() }
)
@ObservationIgnored
var entries: ViewData<[Entry]>
```

Constructing the model starts no work. The first property access evaluates the seed synchronously
and creates dormant data. `AsyncContent` requests connection when its body renders, including when
the initial presentation is hidden. The factory must return promptly; expensive work belongs to
its producer. Every later read returns the same data.

A badge can read `model.entries.latestValue` directly without starting work. For badges or conditions
that prevent `AsyncContent` from being constructed, call `connect()` on each needed `ViewData`
from model startup. This schedules startup outside the current call stack. Repeated calls share
one connection without awaiting initial data or invoking hot refresh. `reload()` ensures startup
itself before requesting work.

Connect explicitly for any source that needs updates before its `AsyncContent` renders, including
nested sections starting alongside a parent and tests without a view. See the
[startup table](source-backed-data.md#connect-without-rendering). Callback execution does not restore
the model's creation environment; see [Dependency context](dependency-context.md).

## Model lifetime and reset

Once connected, hiding a section, navigating away, or finishing a reload does not disconnect its
source while the model is retained. Choose model scope deliberately: a retained tab model or an
application-wide model keeps its connected sources running. Entering the background does not release
that model. Producer-specific suspension and background execution remain application concerns.

Releasing the model cancels its subscription and retry work and invalidates pending identity
callbacks. This also happens when another object retains its `ViewData`, sink, or retry action.
The retained data keeps its presentation, but source reload becomes inert. Models released before
scheduled activation runs start no source work.

Callbacks receive a weakly held owner and temporarily retain it while running, including an awaited
refresh. A task invoking an async model method can also keep that model alive until it returns.
Factories and returned sequences must avoid retaining their model for an endless subscription.
Cancellation is cooperative with the producer.

`reset()` clears presentation while leaving the model-owned source connected. Later updates may
replace the empty state. Successful empty collections and optional `nil` count as available values.

## Reload sources

For a `make:` declaration without a refresh action, activation starts the cold sequence. The first explicit reload joins a
pending initial load that has not yet produced an update. Later reloads cancel the previous
subscription, invoke the factory again, and await sequence completion. A completed initial sequence
is ready for a new request; repeated property reads alone never restart it. Cold sources that fetch
on activation need no extra startup reload merely to obtain their first value.

With a refresh action, activation only subscribes. Reload keeps that subscription and awaits the
producer's action. If the sequence has completed, Ensemble reconnects before calling the action.
Hot factories must register their observation synchronously or buffer updates so an immediate
refresh cannot lose its result. If the action returns while its request is still loading,
Ensemble restores the preceding failure, retained success, or empty state. Queued and ongoing
updates continue to reach the data through the same subscription. Await the actual work in
`refresh:` to keep the loading phase active while the producer works.

Connecting or rebinding never invokes a hot source's refresh action. Initial requests, caching,
and replay policy belong to the application or data layer. The synchronous seed guarantees
first-paint content independently of stream timing. Idle hot sources are not marked loading until
an explicit refresh; cold sources begin loading on activation. Reload preserves successful content.

A [loadable producer](source-backed-data.md#loadable-sources) supplies its availability on first
read. On connection, Ensemble subscribes and requests `.initial`. A bare reload joins that request
while it is running. Later reloads and retries reuse the producer, resubscribing if needed.
Reload waits for the load action, and the stream stays active.

### Reload reasons

Pass `.automatic` for an application-driven refresh or `.userInitiated` for a user gesture.
Bare `reload()` uses `.automatic` when it starts a refresh. Retry uses `.userInitiated`.
Loadable producers receive `.reload(reason)`. When you pass a reason explicitly, it reaches
the producer even if initial work is already running or the source has yet to connect.
Hot refresh closures receive the owner and the reason. Use `{ model, _ in … }` when
the refresh behaves the same for both reasons.

```swift
@ViewDataSource(
  make: { (model: Self) in model.useCase.updates() },
  refresh: { model, reason in await model.useCase.refresh(reason) }
)
@ObservationIgnored
var entries: ViewData<[Entry]>
```

## Reload several sources together

```swift
await Ensemble.reload(model.profile, model.activity, model.notifications)
await Ensemble.reload(.userInitiated, model.profile, model.activity, model.notifications)
```

The sources can hold different value types. This convenience calls each source's `reload()`
concurrently through a task group and awaits all actions. A reason supplied to the batch is
forwarded to each reload. Each source applies its own results, failures, and resets. A failure does not cancel its
siblings or throw from the batch; retry remains local. Completion means the actions finished,
not that every source succeeded or every stream outcome has been processed.

Cancellation propagates to outstanding actions and cold requests. It does not end the owning
models' lifetimes. Plain data, reload-disabled sources, an empty batch, and already-cancelled calls
perform no reload work. `AsyncContent` and `connect()` still connect reload-disabled sources normally.
Duplicate instances in one batch reload once.

### Overlapping requests

Hot and loadable sources can run multiple reload requests. Their producer decides how to handle
overlap. A cold reload after the initial request has been joined cancels and replaces the earlier
request. Awaiting that earlier request can finish while the newer request continues.

## Adapt source-specific updates

Use the macro's `receive` adapter to translate application-defined update types:

```swift
enum EntriesUpdate {
  case result(Result<[Entry], EntryFailure>)
  case invalidate
}

@ViewDataSource(
  make: { (model: Self) in model.useCase.updates() },
  refresh: { model, _ in await model.useCase.reload() },
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
Set `allowsReload: false` on a `make:` declaration to suppress programmatic reload and failure retry while
keeping activation and automatic rebinding.

## Track connection identity

Pass `id: \.selectedFilter` or a computed composite `Equatable` ID to the macro. Only that projection
is observed; factory construction runs untracked, including producer-internal reads. Equal IDs
renew dependencies without replacing sinks, retries, connections, or running requests. Changed IDs
reject obsolete callbacks and rebuild on the main actor. The same data survives. Sources declared
with `make:` retain successful content, and hot sources reconnect without invoking refresh.
Sources declared with `updates:` seed from the new producer and then request its initial load.
Omit `id` for a fixed connection.

Dependency tracking is renewed after notifications, including conditional branches. Completed
sequences still track identity changes while their model lives. Unconnected declarations stay dormant;
connecting selects the current identity. Owner teardown disarms pending callbacks and prevents
further connections.

For a `make:` source, use `reset()` before changing a domain identity when the old value is
no longer appropriate. Its `initial:` seed runs only on first access. See
[Source-backed data](source-backed-data.md#rebind-through-connection-identity).

## Completion, errors, and cancellation

A failure element enters failure without ending the subscription, so a later success can recover
it. A thrown iteration error enters failure and completes the subscription. Producer cancellation
is not presented as a failure. Empty completion or cancellation settles loading to its preceding
failure, retained success, or empty state. A previously emitted result keeps its phase.

Reload can reconnect a completed sequence. Cancelling an awaited cold reload stops that request
and rejects its retained sinks; identity tracking remains active for future changes.
Cancelling a hot refresh or an awaited loadable request leaves its model-owned subscription
intact. Owner teardown removes retry and settles only that connection's loading transition.
Connection revisions reject obsolete updates without settling a newer one-shot load or replacement
request.

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
