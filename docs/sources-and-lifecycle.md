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
when no later update has replaced that load's loading transition, cancellation settles to cached
success if a value exists and to empty otherwise. A load does not install a retry action.

A load and binding can feed the same destination in tandem. Starting either one does not cancel the
other, and their accepted updates are applied in arrival order:

```swift
context.bind(useCase.values, to: entries)
await context.load(useCase.fetch, to: entries)
```

The latest accepted update determines the phase. The latest accepted success determines `latest`,
because a later loading or failure update preserves that successful value.

## Bind a result stream

`bind(_:to:reload:)` accepts a main-actor factory rather than one already-created stream:

```swift
context.bind(useCase.values, to: entries)
```

The context calls the factory synchronously during binding, then starts consuming the returned stream. The factory must return promptly; networking, observation, and other expensive work belong to the stream's producer.

The stream itself does not throw. A failure is one `Result.failure` element, so it updates the destination without terminating iteration:

```swift
continuation.yield(.failure(.offline))
continuation.yield(.success(recoveredEntries))
```

The later success replaces `latest` and moves the destination back to success. A source may instead finish after either result when it represents one request per subscription.

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
func load() {
  context.bind(useCase.values, to: entries)
}

func reload() {
  context.reload(entries)
}
```

For a hot source, bind its long-lived stream once and tell the context how to ask its producer for another value:

```swift
func load() {
  context.bind(
    useCase.values,
    to: entries,
    reload: .refresh(useCase.reload)
  )
}

func reload() {
  context.reload(entries)
}
```

Both behaviors mark `entries` as loading before starting the reload. `.refresh` leaves an active subscription in place. If that sequence has already completed, the context creates another sequence before calling the refresh action, so the new result still has a consumer. The refresh action must publish into the sequence returned by the factory; an `AsyncStream` that deliberately discards values before iteration should coordinate or buffer that initial publication itself.

The context retains the source factory and any refresh action. A method reference strongly retains its instance. A reference such as `useCase.values` is appropriate when the use case should live with the context. Do not pass a method on an object that also owns the context, because that creates a retain cycle; use a separate source object or an intentional weak capture instead.

## Seed and reset state

Initialize `ViewData` with a value when useful content exists before any source starts:

```swift
let entries = ViewData(cachedEntries)
```

The initial phase is successful. If a load or source starts later, the seeded value remains available as cached content while loading or after failure.

Reset presentation when both the lifecycle phase and cached value should be discarded:

```swift
entries.reset()
```

Reset does not cancel an active load or binding. A later accepted update can replace the empty
state. Use `ViewDataContext.cancel(_:)` when the binding should stop, and cancel the task awaiting
`load(_:to:)` when the one-shot operation should stop.

## Retry with the configured reload behavior

The failure builder receives an optional `ViewDataRetryAction`:

```swift
} failure: { error, retry in
  VStack {
    Text(error.localizedDescription)
    if let retry {
      Button("Try again") {
        retry()
      }
    }
  }
}
```

Calling it performs the same operation as `context.reload(entries)`. A resubscribing binding cancels and replaces its sequence; a refreshing binding keeps its active sequence and signals the producer. Results from a sequence replaced by resubscription are ignored even if its producer emits after cancellation.

## Handle completion and cancellation

When a stream finishes without emitting while the destination is loading, the context settles the state to success if a latest value exists and to empty otherwise. If the stream already emitted a success or failure, that phase remains visible. A later `.refresh` reload re-establishes a completed subscription before it invokes the producer action.

Cancel one binding when its destination should stop receiving updates:

```swift
context.cancel(entries)
```

Cancellation removes the retry action. A destination cancelled while loading settles to cached success or empty using the same rule as completion; an existing success or failure phase is preserved.

Cancel every binding explicitly with `cancelAll()`, or release the context. Its deinitializer cancels all subscriptions it still owns.

Rebinding a destination is equivalent to cancelling its current registration before starting the replacement. Other destinations owned by the same context are unaffected.

Next: [Getting started](getting-started.md) · [Presentation policies](presentation-policies.md)
