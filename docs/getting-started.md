# Getting started

Declare a source on `ViewData`, then pass that value to `AsyncContent`. The data owns its binding;
SwiftUI consumers share observation of it. No separate subscription owner or startup method is needed.

## Declare presentation data

A source is an `AsyncSequence` of `Result` values. A failure element can be followed by a success;
an error thrown by iteration ends that subscription and enters failure.

```swift
import Ensemble

@MainActor
final class EntriesViewModel {
  let entries: ViewData<[Entry]>

  init(useCase: EntriesUseCase, initial: ViewDataAvailability<[Entry]> = .unavailable) {
    entries = ViewData(initial, make: useCase.values)
  }
}
```

An available seed is exposed synchronously, including an empty collection or optional `nil`.
Creating `ViewData` does not invoke the factory. The factory runs when observation starts and
must return promptly; expensive work belongs to the sequence's producer.

Factories and refresh closures retain their captures. Capture collaborators directly, or use the
weak-owner initializer described in [Source-backed data](source-backed-data.md).

## Render the data

```swift
List {
  AsyncContent(viewModel.entries, loading: .placeholder(Entry.placeholders)) { entries, source in
    ForEach(entries) { entry in
      Text(entry.title)
        .redacted(reason: source == .placeholder ? .placeholder : [])
    }
  }
}
```

`AsyncContent` observes source-backed data automatically, even when its initial rendering is hidden.
The seed is immediately renderable; no startup task delays it. Default loading and failure policies
retain the latest successful value. Empty collections are successes: render their empty state inside
the content builder. See [Presentation policies](presentation-policies.md) for failure UI and retry.

Concurrent consumers share one connection. When the last consumer's observation ends, the connection
and retry action are cancelled, while the seed, successful value, and source configuration remain.
A later consumer reconnects. Automatic observation follows SwiftUI state lifetime, including state
that SwiftUI retains offscreen.

## Request another result

Cold sources perform work when connected; `await entries.reload()` cancels and resubscribes. Hot sources
need a separate action that publishes through their existing subscription:

```swift
entries = ViewData(
  initial,
  make: useCase.values,
  refresh: useCase.refresh
)
```

Connecting calls the factory without invoking the refresh action. A hot source can passively
observe repository or use-case outcomes and replay a cached snapshot. The model requests initial
loading explicitly and chooses the data layer's caching policy. Explicit reload and failure retry
invoke the configured refresh action. Reloading inactive data does nothing.

Keep the data instance stable and use `replaceSource(make:refresh:)` when dependencies change;
successful content stays available through replacement. A replacement hot source is subscribed
without requesting a refresh; call `await reload()` when the user explicitly requests new data.

SwiftUI can await the producer's request directly:

```swift
.refreshable {
  await viewModel.entries.reload()
}
```

The configured refresh closure must await the actual work. Cold reloads await the new sequence's
completion, so ongoing streams should provide a refresh action. Inactive data remains unchanged.

For a single throwing asynchronous operation, use:

```swift
await entries.load(useCase.fetch)
```

The operation follows the caller's task lifetime. It can update the same data as a source binding;
accepted updates apply in arrival order. Cancellation settles its own loading transition without
replacing later updates. See [Sources and lifecycle](sources-and-lifecycle.md) for adapters and
explicit task-scoped observation.

Next: [Presentation policies](presentation-policies.md) · [Source-backed data](source-backed-data.md)
