# Getting started

Declare a source with `@ViewDataSource`, then read its `ViewData` from views or model logic.
First access activates the source for its model’s lifetime. `AsyncContent` renders that state;
no observation task, modifier, or startup method is needed.

## Declare presentation data

A source is an `AsyncSequence` of `Result` values. A failure element can be followed by a success;
an error thrown by iteration ends that subscription and enters failure.

```swift
import Ensemble

@MainActor
final class EntriesViewModel {
  let useCase: EntriesUseCase

  @ViewDataSource(
    initial: { (model: Self) in model.useCase.cachedAvailability },
    make: { model in model.useCase.values() }
  )
  var entries: ViewData<[Entry]>

  init(useCase: EntriesUseCase) {
    self.useCase = useCase
  }
}
```

The application supplies `cachedAvailability`. Its seed closure runs synchronously once on first
read, including successful empty collections or optional `nil`. Omit `initial:` to start unavailable.
The macro creates stable data and schedules activation after the getter returns. Its factory must
return promptly; expensive work belongs to the producer. Unread declarations start no work.

Callbacks receive a weakly held owner. In an `@Observable` model, put `@ObservationIgnored` after
`@ViewDataSource`. See [Source-backed data](source-backed-data.md) for callback capture rules.

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

`AsyncContent` renders source-backed data even when its initial presentation is hidden.
Badge and conditional-gate reads activate the same source without constructing `AsyncContent`.
The seed is immediately renderable; no startup task delays it. Default loading and failure policies
retain the latest successful value. Empty collections are successes: render their empty state inside
the content builder. See [Presentation policies](presentation-policies.md) for failure UI and retry.

Every consumer shares the property’s one connection. Hiding or removing content does not stop it
while its model lives. Releasing the model cancels the source even when something else retains its
`ViewData`. Choose model scope deliberately for retained tabs and application-wide state.

## Request another result

Cold sources perform work when connected; `await entries.reload()` cancels and resubscribes. Hot sources
need a separate action that publishes through their existing subscription:

```swift
@ViewDataSource(
  make: { (model: Self) in model.useCase.values() },
  refresh: { model in await model.useCase.refresh() }
)
var entries: ViewData<[Entry]>
```

Connecting calls the factory without invoking the refresh action. A hot source can passively
observe repository or use-case outcomes and replay a cached snapshot. The model requests initial
loading explicitly and chooses the data layer's caching policy. Explicit reload and failure retry
invoke the configured refresh action. Reload works immediately after first access, before a view
renders, and keeps the model-owned subscription alive afterward.

Keep source-selection inputs observable and read them synchronously inside `make`. Changes
rebind the source automatically while preserving successful content. Rebinding a hot source only
subscribes; use `await reload()` for an explicit request. Reset before changing domain identity
when the previous value should be cleared.

SwiftUI can await the producer's request directly:

```swift
.refreshable {
  await viewModel.entries.reload()
}
```

The configured refresh closure must await the actual work. Cold reloads await the new sequence's
completion, so ongoing streams should provide a refresh action. The first explicit cold reload
joins a pending initial load; later reloads resubscribe. Property reads alone never restart a
completed sequence.

## Reload a screen's independent chunks

Keep one screen-level request method even when the data properties have different value types:

```swift
func reload() async {
  await Ensemble.reload(profile, activity, notifications)
}
```

```swift
.task { await viewModel.reload() }
.refreshable { await viewModel.reload() }
```

The batch starts requests concurrently and waits for every action. Each chunk handles its own
success, failure, and retry UI; one failure does not cancel the others. Caller cancellation
propagates to outstanding requests. This is a convenience for concurrent `data.reload()` calls;
each call can run before rendering. Cold sources that already fetch on activation do not need an
additional startup reload just to load their first value.

A successful batch return means the actions finished, not that every source succeeded. Stream
outcomes may be delivered separately; the model-owned connections continue receiving them
after batch completion. Repeated instances reload once; unmanaged or reload-disabled
data is ignored. See [Sources and lifecycle](sources-and-lifecycle.md) for overlapping requests.

## Load one value

For a single throwing asynchronous operation, use:

```swift
await entries.load(useCase.fetch)
```

The operation follows the caller's task lifetime. It can update the same data as a source binding;
accepted updates apply in arrival order. Cancellation settles its own loading transition without
replacing later updates. See [Sources and lifecycle](sources-and-lifecycle.md) for adapters and
model-owned source lifetimes.

Next: [Presentation policies](presentation-policies.md) · [Source-backed data](source-backed-data.md)
