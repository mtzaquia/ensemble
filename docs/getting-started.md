# Getting started

Ensemble separates presentation state, subscription ownership, and rendering policy. Keep the
first two in a main-actor model, then let each SwiftUI call site decide how to present the result.

## Bind presentation data

A bound source is an `AsyncSequence` of `Result` values. A failure element can be followed by a
success, while an error thrown by iteration ends the sequence and enters failure.

```swift
import Ensemble

@MainActor
final class EntriesViewModel {
  let entries = ViewData<[Entry]>()

  private let context = ViewDataContext()
  private let useCase: EntriesUseCase

  init(useCase: EntriesUseCase) {
    self.useCase = useCase
  }

  func start() {
    context.bind({ useCase.values() }, to: entries)
  }

  func reload() {
    context.reload(entries)
  }
}
```

Keep the context alive for as long as its bindings should remain active. Binding marks `entries`
as loading and consumes results until the sequence completes, the destination is rebound, or the
context is released. Success replaces `latestValue`; failure preserves it.

The source factory runs synchronously and must return promptly. Networking, observation, and other
work belong to the sequence producer.

## Match reload to the source

The default `.resubscribe` behavior replaces a cold, request-per-subscription sequence. A hot
source instead needs an action that publishes through its existing subscription:

```swift
context.bind(
  { useCase.values() },
  to: entries,
  reload: .refresh { useCase.refresh() }
)
```

`context.reload(entries)` and retry UI both use the configured behavior. Choose `.disabled` when
neither should be available.

Use `load(_:to:)` for one throwing asynchronous operation:

```swift
await context.load(useCase.fetch, to: entries)
```

A load and binding may feed the same destination; accepted updates are applied in arrival order.
See [Sources and lifecycle](sources-and-lifecycle.md) for reset-aware adapters, completion, and
cancellation.

## Render presentation state

Pass `ViewData` to `AsyncContent` and start the binding from a stable ancestor:

```swift
ZStack {
  AsyncContent(viewModel.entries) { entries, _ in
    List(entries) { entry in
      Text(entry.title)
    }
  }
}
.task {
  viewModel.start()
}
```

The default policies render nothing before the first success, then retain the latest successful
value while loading or failed. An empty collection is still a success; render its empty state
inside the success builder. See [Presentation policies](presentation-policies.md) for placeholders,
failure UI, and retry.

Next: [Presentation policies](presentation-policies.md) ·
[Sources and lifecycle](sources-and-lifecycle.md)
