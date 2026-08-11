# Sources and lifecycle

`ViewDataContext` coordinates one-shot loads and owns asynchronous subscriptions, while `ViewData`
owns presentation state. Understanding where those lifetimes meet makes retries, reset, completion,
and cancellation predictable.

## Load one value

Use `load(_:to:)` for one throwing asynchronous operation:

```swift
await context.load(useCase.fetch, to: entries)
```

The destination enters loading before the operation starts. A returned value becomes its latest
successful value; a thrown error enters failure while preserving any previous successful value.
The method consumes the error into presentation state rather than rethrowing it.

A load follows the lifetime of the task awaiting it. Cancellation is not presented as a failure:
when no later update has replaced that load's loading transition, cancellation restores a failure
that preceded loading, settles to cached success if a value exists, or settles to empty. A load
does not install a retry action.

A load and binding can feed the same destination in tandem. Starting either one does not cancel the
other, and their accepted updates are applied in arrival order:

```swift
context.bind(useCase.values, to: entries)
await context.load(useCase.fetch, to: entries)
```

The latest accepted update determines the phase. The latest accepted success determines `latest`,
because a later loading or failure update preserves that successful value.

## Bind a result sequence

`bind(_:to:reload:)` accepts a main-actor factory rather than one already-created sequence:

```swift
context.bind(useCase.values, to: entries)
```

The context calls the factory synchronously during binding, then starts consuming the returned
sequence. The factory must return promptly; networking, observation, and other expensive work
belong to its producer. Any `AsyncSequence` works, including transformed and combined sequences.

For one-to-one element translation, prefer a lazy `AsyncSequence.map` so the original source keeps
its production and lifecycle semantics. Create a new `AsyncStream` and producer task only when the
adapter intentionally owns production, buffering, or lifecycle behavior.

A failure element updates the destination without terminating iteration:

```swift
continuation.yield(.failure(.offline))
continuation.yield(.success(recoveredEntries))
```

The later success replaces `latest` and moves the destination back to success. A source may instead
finish after either result when it represents one request per subscription. If iteration itself
throws, the terminal error enters failure.

## Adapt a source-specific update type

`bind(_:to:reload:receive:)` is the integration point for a source with its own update protocol.
Wrap it once in a constrained overload instead of translating updates at every feature call site:

```swift
enum RepositoryUpdate<Value: Sendable>: Sendable {
  case result(Result<Value, any Error>)
  case reset
}

extension ViewDataContext {
  func bind<Value: Sendable, Source>(
    _ makeSource: @escaping @MainActor @Sendable () -> Source,
    to destination: ViewData<Value>,
    refresh: @escaping @MainActor @Sendable () -> Void
  ) where
    Source: AsyncSequence,
    Source.Element == RepositoryUpdate<Value>
  {
    bind(makeSource, to: destination, reload: .refresh(refresh)) { update, sink in
      switch update {
      case .result(let result):
        sink.receive(result)
      case .reset:
        sink.reset()
      }
    }
  }
}
```

The overload translates the source vocabulary and chooses its reload contract. This example
requires a refresh action because the repository stream is hot; an adapter for a cold source can
use `.resubscribe` instead.

Feature code now uses the source-specific overload directly:

```swift
context.bind(
  { repository.updates() },
  to: entries,
  refresh: { repository.refresh() }
)
```

The source owns observation. Emitting no element leaves presentation unchanged, while a successful
empty collection remains distinguishable through `.result(.success([]))`. A reset clears
presentation without ending the binding or removing retry availability. Sink actions are ignored
after the binding is replaced or cancelled.

## Choose binding reload behavior

Choose reload behavior based on the source's lifetime. The binding's `ViewDataReloadBehavior`
defines what both programmatic reload and failure retry do:

| Behavior | Reload operation |
| --- | --- |
| `.resubscribe` | Cancel the current subscription and create a fresh sequence from the factory |
| `.refresh(action)` | Keep an active subscription and invoke the upstream refresh action |
| `.disabled` | Expose no reload or retry action |

`.resubscribe` is the default and fits cold, request-per-subscription sources:

```swift
context.bind(useCase.values, to: entries)
```

For a hot source, retain its subscription and tell the context how to signal its producer:

```swift
context.bind(
  useCase.values,
  to: entries,
  reload: .refresh(useCase.reload)
)
```

`context.reload(entries)` and the retry action exposed to failure UI use the configured behavior.
Both mark `entries` as loading. `.refresh` leaves an active subscription in place; if it has
completed, the context creates another before invoking the action. That action must publish into
the sequence returned by the factory.

The context retains the source factory and refresh action. A method reference therefore retains its
instance. Avoid passing a method on an owner that also retains the context unless that cycle is
intentional.

## Seed and reset state

Initialize `ViewData` with a value when useful content exists before any source starts:

```swift
let entries = ViewData(cachedEntries)
```

The initial phase is successful. If a load or source starts later, the seeded value remains
available as cached content while loading or after failure.

Reset presentation when both the lifecycle phase and cached value should be discarded:

```swift
entries.reset()
```

Reset does not cancel an active load or binding. A later accepted update can replace the empty
state. Use `ViewDataContext.cancel(_:)` when the binding should stop, and cancel the task awaiting
`load(_:to:)` when the one-shot operation should stop.

## Handle completion and cancellation

When a stream finishes without emitting while the destination is loading, the context restores a
failure that preceded loading. Without a retained failure, it settles the state to success if a
latest value exists and to empty otherwise. If the stream already emitted a success or failure,
that phase remains visible. A later `.refresh` reload re-establishes a completed subscription
before it invokes the producer action.

Cancel one binding when its destination should stop receiving updates:

```swift
context.cancel(entries)
```

Cancellation removes the retry action. A destination cancelled while loading restores the failure
that preceded loading, settles to cached success, or settles to empty using the same rule as
completion. An existing success or failure phase is preserved.

Cancel every binding explicitly with `cancelAll()`, or release the context. Its deinitializer
cancels all subscriptions it still owns.

Rebinding a destination cancels its current registration before starting the replacement. Other
destinations owned by the same context are unaffected.

Next: [Presentation policies](presentation-policies.md) · [Diagnostics](diagnostics.md)
