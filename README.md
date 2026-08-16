# 👯 Ensemble

[![Tests](https://github.com/mtzaquia/ensemble/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/mtzaquia/ensemble/actions/workflows/tests.yml)
[![Swift 6.3](https://img.shields.io/badge/Swift-6.3-orange.svg)](https://www.swift.org/)
[![iOS 17+](https://img.shields.io/badge/iOS-17%2B-blue.svg)](https://github.com/mtzaquia/ensemble/blob/main/Package.swift)
![Class B](https://img.shields.io/badge/class-B-silver)

<a href="https://www.buymeacoffee.com/mtzaquia" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" style="height: 30px !important;" ></a>

`Ensemble` is a SwiftUI presentation-state library for composing self-contained, reloadable
features.

A `ViewData` value remembers the latest successful data and its current lifecycle phase.
A `ViewDataContext` feeds it from one-shot asynchronous operations or asynchronous sequences,
while `AsyncContent` decides whether a view should show the latest data, retained data, placeholders,
a failure, or nothing.

- Seed presentation state immediately, load one value, or bind a stream of updates.
- Distinguish not-yet-loaded, loaded-but-empty, and reset observable state.
- Keep useful data visible while a refresh is loading or fails.
- Recover after a failure without terminating the stream.
- Reload cold sources with `.resubscribe` or signal a hot source with `.refresh(action)`.
- Give each screen or section its own loading, failure, and animation behavior.

```swift
AsyncContent(viewModel.entries) { entries, _ in
  List(entries) { entry in
    EntryRow(entry: entry)
  }
}
```

## Install

Ensemble requires Swift 6.3 and supports iOS 17+ and macOS 14+. It is available through Swift
Package Manager.

```swift
dependencies: [
  .package(url: "https://github.com/mtzaquia/ensemble.git", from: "1.2.1"),
]
```

Add the `Ensemble` product to the app target, then `import Ensemble` where it is used.

## Five-minute start

Start with a source that returns an asynchronous sequence of `Result` values. Own one `ViewData`
value and retain its `ViewDataContext` for as long as the subscription should remain active:

```swift
import Ensemble

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
        Entry(id: 1, title: "The latest value"),
      ]))
      continuation.finish()
    }
  }
}

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
}
```

`ViewData` is observable, so the surrounding view model does not need observation solely to expose
it. Render the value with `AsyncContent` and start the binding from a stable ancestor:

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
      viewModel.start()
    }
  }
}
```

With this `AsyncContent` initializer, loading and failure render nothing until a successful value
exists, then retain that value. The [presentation policies guide](docs/presentation-policies.md)
shows how to add placeholder or failure UI.

The surrounding `ZStack` remains mounted while `AsyncContent` is empty, making it a reliable place
to start the binding. Releasing the context cancels its subscription.

That is the core idea: bind observable presentation data once, then render its latest useful value with `AsyncContent`.

## Documentation

- [Getting started](docs/getting-started.md) — connect a source, choose its reload behavior, and
  render the first result.
- [Presentation policies](docs/presentation-policies.md) — choose placeholder, retained, hidden,
  and failure-content behavior per view.
- [Sources and lifecycle](docs/sources-and-lifecycle.md) — adapt source update types and understand
  reload, reset, completion, and cancellation.
- [Diagnostics](docs/diagnostics.md) — inspect load, binding, reload, and cancellation activity.

## Sample app

Open [`SampleApp/SampleApp.xcodeproj`](SampleApp/SampleApp.xcodeproj) to explore dedicated failure
content, seeded content retained through refresh, independently loading sections, and locally
scoped animated list updates.

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
