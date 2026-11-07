# 👯 Ensemble

[![Tests](https://github.com/mtzaquia/ensemble/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/mtzaquia/ensemble/actions/workflows/tests.yml)
[![Swift 6.3](https://img.shields.io/badge/Swift-6.3-orange.svg)](https://www.swift.org/)
[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-blue.svg)](https://github.com/mtzaquia/ensemble/blob/main/Package.swift)
![Class B](https://img.shields.io/badge/class-B-silver)

<a href="https://www.buymeacoffee.com/mtzaquia" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" style="height: 30px !important;" ></a>

`Ensemble` is a SwiftUI presentation-state library for composing self-contained, reloadable
features.

A `ViewData` value remembers successful data and its current lifecycle phase. Declare its source
with `@ViewDataSource`; `AsyncContent` connects it for the model’s lifetime. An optional `id` key
path selects when to rebuild the source, while the same presentation state retains success.
One-shot operations use `await entries.load(...)` on ordinary `ViewData`.

- Seed presentation state immediately, load one value, or bind a stream of updates.
- Distinguish not-yet-loaded, loaded-but-empty, and reset observable state.
- Keep useful data visible while a refresh is loading or fails.
- Recover after a failure without terminating the stream.
- Reload cold sources by resubscribing or signal hot producers through a refresh action.
- Animate presentation presence separately from caller-owned successful-content changes.

```swift
AsyncContent(viewModel.entries) { entries, _ in
  List(entries) { entry in
    EntryRow(entry: entry)
  }
}
```

## Install

Ensemble requires Swift 6.3 and supports iOS 17+ and macOS 14+. It is available through Swift
Package Manager. This branch is the unreleased v3.0.0 prototype; the APIs below are not in v2.

```swift
dependencies: [
  .package(url: "https://github.com/mtzaquia/ensemble.git", branch: "zaquia/v3"),
]
```

Add the `Ensemble` product to the app target, then `import Ensemble` where it is used. Source
properties use the `EnsembleMacros` compiler plugin; approve Xcode's macro trust prompt. Configure
macro trust in unattended build environments before building the app.

## Five-minute start

Declare a synchronous seed and a lazy source beside the presentation property:

```swift
import Ensemble

struct Entry: Identifiable, Sendable {
  let id: Int
  let title: String
}

enum EntryFailure: Error, Sendable {
  case unavailable
}

@MainActor
final class EntriesUseCase {
  let cachedEntries = [Entry(id: 1, title: "Cached entry")]

  func values() -> AsyncStream<Result<[Entry], EntryFailure>> {
    AsyncStream { continuation in
      continuation.yield(.success([Entry(id: 1, title: "The latest value")]))
      continuation.finish()
    }
  }
}

@MainActor
final class EntriesViewModel {
  let useCase: EntriesUseCase

  @ViewDataSource(
    initial: { (model: Self) in .available(model.useCase.cachedEntries) },
    make: { model in model.useCase.values() }
  )
  var entries: ViewData<[Entry]>

  init(useCase: EntriesUseCase) {
    self.useCase = useCase
  }
}
```

The seed is immediately available. Creating the model starts no source work. Render the property
directly; source-backed data connects automatically even when the initial content is hidden:

```swift
import SwiftUI

struct EntriesView: View {
  @State private var viewModel: EntriesViewModel

  init(useCase: EntriesUseCase) {
    _viewModel = State(initialValue: EntriesViewModel(useCase: useCase))
  }

  var body: some View {
    List {
      AsyncContent(viewModel.entries) { entries, _ in
        ForEach(entries) { entry in
          Text(entry.title)
        }
      }
    }
  }
}
```

No context property, start method, or view task is needed for this path. For hot sources, pass a
`refresh` action for explicit reloads and retries. Hot streams can simply observe repository or
use-case outcomes; the model requests loading explicitly. Caching policy stays in the data layer.
Cold sources fetch through their sequence and resubscribe when `await entries.reload()` is called.

Source properties are get-only and seeded on first read. Reads stay passive. `AsyncContent`
requests connection when rendered; badges and conditional gates can connect from model startup:

```swift
func start() {
  Ensemble.connect(profile, activity, notifications)
}
```

`data.connect()` and the batch convenience are synchronous, idempotent, and schedule startup outside
the current call stack. They do not invoke a hot refresh action. Once connected, all consumers share
the connection until the model is released.
Every callback receives the weakly held model, including `receive(owner, element, sink)`.
The optional adapter is unnecessary for ordinary `Result` streams. In `@Observable` models, put `@ObservationIgnored` after `@ViewDataSource`.

For a screen with several independent chunks, request them together:

```swift
await Ensemble.reload(viewModel.profile, viewModel.activity, viewModel.notifications)
```

The batch starts requests concurrently, waits for all actions, and lets each chunk present its own
failure. Each call behaves like `await data.reload()` and propagates caller cancellation.
Finishing a request keeps the model-owned subscription alive for later updates.

Declare source identity separately from source construction:

```swift
@ViewDataSource(
  id: \.filter,
  make: { (model: Self) in model.repository.values(for: model.filter) }
)
@ObservationIgnored
var entries: ViewData<[Entry]>
```

Only the `id` projection is observed. An unequal identity rebuilds the connection; equal identities
preserve it, including its sinks and retry. `make` runs untracked, including producer internals.
Without `id`, source changes do not trigger automatic rebinding. Reload and retry keep their
configured hot or cold behavior. Use a computed `Equatable` identity for multiple inputs,
including mutable producer identity.
Successful content remains in the same `ViewData`. Use `reset()` before changing an
account or another domain identity when the previous value should be discarded.
See [Source-backed data and v3 migration](docs/source-backed-data.md).

When adding skeletons, use `loading: .placeholder(...)` and redact only `source == .placeholder`.
Successful empty collections and successful optional `nil` remain distinct from unavailable data.
The [presentation guide](docs/presentation-policies.md) covers loading, failure, and animation.

## Documentation

- [Source-backed data and v3 migration](docs/source-backed-data.md) — lazy activation, property
  macros, connection identity, and lifetime boundaries.
- [Getting started](docs/getting-started.md) — connect a source, choose its reload behavior, and
  render the first result.
- [Presentation policies](docs/presentation-policies.md) — choose placeholder, retained, hidden,
  and failure-content behavior per view.
- [Sources and lifecycle](docs/sources-and-lifecycle.md) — adapt source update types and understand
  reload, reset, completion, and cancellation.
- [Testing](docs/testing.md) — test passive seeds, connect source harnesses, and synchronize updates.
- [Dependency context](docs/dependency-context.md) — understand callback timing and dependency propagation.
- [Diagnostics](docs/diagnostics.md) — inspect load, binding, reload, and cancellation activity.

## Sample app

Open [`SampleApp/SampleApp.xcodeproj`](SampleApp/SampleApp.xcodeproj) to explore dedicated failure
content, seeded content retained through refresh, independently loading sections, and the
placeholder-first stable-ID animation scenario. The Cached refresh screen compares fast and slow
requests, retained empty results, and deliberate invalidation. See [`SampleApp/README.md`](SampleApp/README.md)
for the scenario guide and manual animation checks.

## License

Copyright (c) 2026 @mtzaquia

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
