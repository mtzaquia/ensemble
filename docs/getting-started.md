# Getting started

Ensemble separates observable presentation state, subscription ownership, and rendering policy. This keeps a view model focused on data flow while each view decides how loading and failure should appear.

## Model the source result

A bound source is an `AsyncSequence` whose elements are `Result` values. Representing failure as
an element lets the same sequence recover later instead of ending at the first error. If iteration
itself throws, Ensemble presents that terminal error as failure.

```swift
import Foundation

struct Entry: Identifiable, Sendable {
  let id: Int
  let title: String
}

enum EntryFailure: Error, Sendable {
  case unavailable
}

final class EntriesUseCase {
  func values() -> AsyncStream<Result<[Entry], EntryFailure>> {
    AsyncStream { continuation in
      continuation.yield(.success([
        Entry(id: 1, title: "A live value"),
      ]))
      continuation.finish()
    }
  }
}
```

The factory must return promptly. Networking, observation, and other expensive work belong to the stream's producer rather than in the factory itself.

## Own state and subscription lifetime

Create one `ViewData` for each independently presented value. Keep the `ViewDataContext` alive for as long as those bindings should remain active.

```swift
import Ensemble

final class EntriesViewModel {
  let entries = ViewData<[Entry]>()

  private let context = ViewDataContext()
  private let useCase: EntriesUseCase

  init(useCase: EntriesUseCase) {
    self.useCase = useCase
  }

  func load() {
    context.bind(useCase.values, to: entries)
  }
}
```

`ViewData` is observable, so the surrounding view model does not need observation solely to expose it. `bind(_:to:reload:)` creates the stream synchronously, marks `entries` as loading, and starts consuming results. A success replaces `latest`; a failure changes the phase but preserves `latest`.

## Choose how the binding reloads

The default `.resubscribe` behavior fits a cold source that creates one request for each
subscription:

```swift
context.bind(useCase.values, to: entries)

func reload() {
  context.reload(entries)
}
```

Reload cancels that subscription and asks the factory for a fresh stream.

For a hot or long-lived stream, keep its subscription and tell Ensemble how to signal its producer:

```swift
context.bind(
  useCase.values,
  to: entries,
  reload: .refresh(useCase.reload)
)

func reload() {
  context.reload(entries)
}
```

Here, reload marks `entries` as loading, preserves the active subscription, and invokes
`useCase.reload`. The producer should publish its next result through the bound stream. A retry
action shown by `AsyncContent` performs the same configured reload behavior.

Use `.disabled` when the binding should expose neither programmatic reload nor a retry action. The
[sources and lifecycle guide](sources-and-lifecycle.md#choose-binding-reload-behavior) covers source
completion, reattachment, and retention details for each behavior.

For a one-shot throwing operation, use `load(_:to:)` instead. It applies the returned value or
thrown error to the same presentation state:

```swift
func refresh() async {
  await context.load(useCase.fetch, to: entries)
}
```

Loads and bindings can work in tandem on one destination. Starting a load does not cancel its
binding; their accepted updates are applied in arrival order.

## Render the first result

Own the view model with SwiftUI and pass its `ViewData` to `AsyncContent`:

```swift
import SwiftUI

struct EntriesView: View {
  @State private var viewModel: EntriesViewModel

  init(useCase: EntriesUseCase) {
    _viewModel = State(initialValue: EntriesViewModel(useCase: useCase))
  }

  var body: some View {
    ZStack {
      AsyncContent(viewModel.entries) { entries, _ in
        List(entries) { entry in
          Text(entry.title)
        }
      }
    }
    .task {
      viewModel.load()
    }
  }
}
```

Attach the initial `.task` to a stable ancestor such as the surrounding `ZStack`. Before a binding, load, or initial value exists, `AsyncContent` renders `EmptyView`, so a task attached directly to that empty output is not a reliable place to start work.

With this overload, the default loading and failure policies render nothing until the first successful value. After that, both keep the latest successful value visible. Placeholder, replacement failure, and retry UI are opt-in choices for content that needs them.

An empty collection is still a successful value. Render domain-specific empty-state UI inside the success builder when that distinction matters.

Next: [Presentation policies](presentation-policies.md) · [Sources and lifecycle](sources-and-lifecycle.md)
