# Test source-backed models

Macro property reads create and seed presentation data without connecting the source. Tests choose
whether they are exercising presentation alone or the producer's updates. No SwiftUI host is needed
for model, adapter, identity, reload, or ownership tests.

## Keep presentation tests passive

Read `latestValue` or `phase` to assert a seed. Use `set`, `fail`, `reset`, or an awaited `load`
to exercise presentation without starting the declared producer. Do not call `connect()` merely
because the data came from a macro.

`initial` still runs synchronously once on the first property read. Set up its cache snapshot and
dependency overrides before that read, including reads inside assertions or derived properties.
The seed is not reevaluated after reset or connection. If it creates dependencies dynamically,
follow the [dependency-context guide](dependency-context.md).

## Connect a source harness

Use a fresh, deterministic sequence for every factory call. This complete finite-source example
shows passive assertions, explicit startup, and awaiting the initial cold request:

```swift
import Ensemble
import Testing

@MainActor
private final class EntriesHarness {
  private(set) var subscriptions = 0

  @ViewDataSource(
    initial: { _ in .available([1]) },
    make: { (model: Self) in model.values() }
  )
  var entries: ViewData<[Int]>

  func start() { entries.connect() }

  private func values() -> AsyncStream<Result<[Int], Never>> {
    subscriptions += 1
    return AsyncStream { continuation in
      continuation.yield(.success([2]))
      continuation.finish()
    }
  }
}

@MainActor
@Test
func sourceStartsWhenRequested() async {
  let model = EntriesHarness()
  defer { withExtendedLifetime(model) {} }

  #expect(model.entries.latestValue == .available([1]))
  #expect(model.entries.phase.kind == .success)
  #expect(model.subscriptions == 0)

  model.start()
  #expect(model.subscriptions == 0) // Startup is scheduled, not inline.

  // A first cold reload joins the pending initial request and awaits its completion.
  await model.entries.reload()
  #expect(model.subscriptions == 1)
  #expect(model.entries.latestValue == .available([2]))
}
```

Calling `reload()` before startup also connects the source. Direct and batch reloads have the same
behavior; `Ensemble.reload(...)` only runs independent requests concurrently. Use
`Ensemble.connect(...)` to start several heterogeneous sources without invoking hot refresh actions.

## Synchronize ongoing streams with the fixture

For an ongoing stream, call `connect()` and await a fixture-controlled subscription or update signal
before asserting. A continuation or an acknowledgement from `receive` can signal that the sink has
applied an outcome. Use bounded waits so a missed connection fails the test instead of hanging.
Avoid sleeps and assumptions about how many executor turns an update needs.

Returning from synchronous `connect()` does not mean the producer is ready. A hot `reload()` awaits
its refresh action, but streamed outcomes can be processed afterward. Await the fixture's update
acknowledgement when asserting presentation after that action. Do not await completion of an endless
sequence; give it a refresh action when testing requests.

Keep the owning model alive throughout a source test. Retaining only its `ViewData` does not retain
the source's lifetime. To test teardown, release the model deliberately and verify that retained
sinks and retries can no longer change its data.

## Test identity and rendering separately

Start the source, await its initial subscription, and mutate observable identity inputs on the main
actor. When several inputs form one update, change them in one synchronous operation. An intervening
`await`, reload, or reentrant callback can observe a partially updated model.

Check that an unequal ID selects the new producer and rejects old sinks, while an equal ID preserves
the subscription, pending work, and retry. Rebinding retains success and does not reapply the seed.

Use hosted SwiftUI or sample UI tests for automatic `AsyncContent` startup, conditional rendering,
retained rows, transactions, and animation behavior. Constructing an `AsyncContent` value alone does
not render its body or request connection.

Next: [Choose startup](source-backed-data.md#connect-without-rendering) · [Dependency context](dependency-context.md) · [Diagnostics](diagnostics.md)
