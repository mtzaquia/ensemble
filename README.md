# 👯 Ensemble

[![Tests](https://github.com/mtzaquia/ensemble/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/mtzaquia/ensemble/actions/workflows/tests.yml)
[![Swift 6.3](https://img.shields.io/badge/Swift-6.3-orange.svg)](https://www.swift.org/)
[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-blue.svg)](https://github.com/mtzaquia/ensemble/blob/main/Package.swift)
![Class B](https://img.shields.io/badge/class-B-silver)

<a href="https://www.buymeacoffee.com/mtzaquia" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" style="height: 30px !important;" ></a>

`Ensemble` is a SwiftUI presentation-state library for composing self-contained, reloadable
features.

A `ViewData` value remembers successful data and its current lifecycle phase. In the v3 prototype,
it can also own a lazy asynchronous source: `AsyncContent` connects it automatically, and replacing
the source preserves the same successful model data through refresh and failure. `@ViewDataSource` offers
property-level shorthand, with no model-level macro or projected value. Each data value owns its
binding; one-shot operations use `await entries.load(...)`.

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

Add the `Ensemble` product to the app target, then `import Ensemble` where it is used.

## Five-minute start

Initialize presentation state with a synchronous snapshot and a lazy result-sequence factory:

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
  func values() -> AsyncStream<Result<[Entry], EntryFailure>> {
    AsyncStream { continuation in
      continuation.yield(.success([
        Entry(id: 1, title: "The latest value"),
      ]))
      continuation.finish()
    }
  }
}

@MainActor
final class EntriesViewModel {
  let entries: ViewData<[Entry]>

  init(
    useCase: EntriesUseCase,
    initialEntries: ViewDataAvailability<[Entry]> = .unavailable
  ) {
    entries = ViewData(initialEntries, make: useCase.values)
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

Keep the data instance stable and swap its producer when dependencies change:

```swift
viewModel.entries.replaceSource(
  make: anotherUseCase.values,
  refresh: anotherUseCase.reload
)
```

The existing successful value stays in `entries.latestValue`. Replacement reconnects active
observation without invoking the refresh action. The new producer decides what to do on subscription;
replacement does not accept a new seed.
For an account change, call `entries.reset()` before replacement to discard inappropriate content.
See [Source-backed data and v3 migration](docs/source-backed-data.md).

When adding skeletons, use `loading: .placeholder(...)` and redact only `source == .placeholder`.
Successful empty collections and successful optional `nil` remain distinct from unavailable data.
The [presentation guide](docs/presentation-policies.md) covers loading, failure, and animation.

## Documentation

- [Source-backed data and v3 migration](docs/source-backed-data.md) — automatic observation, property
  macros, source replacement, and lifetime boundaries.
- [Getting started](docs/getting-started.md) — connect a source, choose its reload behavior, and
  render the first result.
- [Presentation policies](docs/presentation-policies.md) — choose placeholder, retained, hidden,
  and failure-content behavior per view.
- [Sources and lifecycle](docs/sources-and-lifecycle.md) — adapt source update types and understand
  reload, reset, completion, and cancellation.
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
