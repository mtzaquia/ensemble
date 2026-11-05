# Source-backed data (v3 prototype)

This guide describes the unreleased v3.0.0 work on `zaquia/v3`. Each `ViewData` owns its source
binding, with optional property macros and automatic observation. Swift 6.3, iOS 17, and macOS 14 remain the minimums.

## Own the source with its state

```swift
let entries = ViewData(
  cachedAvailability,
  make: useCase.values,
  refresh: useCase.reload
)
```

`cachedAvailability` is `ViewDataAvailability<[Entry]>`. The factory is retained but not invoked
during initialization. The seed is available synchronously for the first render. An asynchronous
factory cannot provide synchronous first-paint data: obtain or pass that snapshot before rendering.

A factory must return promptly and support a new subscription after cancellation. Upstream
producers own expensive work. Capture collaborators directly rather than a model that owns the
`ViewData`, because factories and refresh actions are retained.

For the same weak-owner callback wiring as the macro, supply an owner explicitly:

```swift
let entries = ViewData(
  cachedAvailability,
  owner: useCase,
  make: { $0.values() },
  refresh: { await $0.reload() }
)
```

Keep `useCase` alive in the model. This initializer and the macro use the same source installation,
observation, cancellation, and successful-value retention. The owner is weak between callback
invocations. The closures themselves are retained, so use their parameter instead of capturing
the owner. Unlike the macro, an ordinary initializer cannot inspect closure syntax at compile time.

## Observe directly from the view

```swift
AsyncContent(model.entries, loading: .placeholder(Entry.placeholders)) { entries, source in
  EntryRows(entries: entries, isPlaceholder: source == .placeholder)
}
```

A private source lifecycle object observes the concrete `ViewData` without changing presentation
observation or erasing successful values. Hidden initial rendering still activates the source.
No layout container is added, so native List rows and Sections remain available.

Concurrent consumers of the same instance share one subscription. Automatic leases follow
**SwiftUI state lifetime**, not strict visibility: offscreen views whose state SwiftUI retains can
continue observing. Rebinding a consumer or releasing its lifecycle storage cancels that lease.
The last lease ending cancels the binding and retry action while retaining successful data.

For work outside `AsyncContent`, acquire a task-scoped lease directly:

```swift
.task {
  await model.entries.observe()
}
```

The call waits until cancellation, including after sequence completion, so `await entries.reload()` can
reconnect a completed sequence. Other active consumers keep their own leases. Plain `ViewData`
without a managed source remains passive and its `observe()` returns immediately.

## Distinguish observing from requesting data

| Source | Connecting | `await reload()` |
| --- | --- | --- |
| Cold, no `refresh` action | Creates and consumes the request sequence | Cancels and resubscribes |
| Hot, with a `refresh` action | Registers observation | Signals the producer, reconnecting a completed sequence first |

Connecting invokes the factory without calling the refresh action. Hot sources can observe
repository or use-case outcomes passively and replay an established snapshot without requesting
new data. The model initiates loading explicitly and chooses the data layer's caching policy.
Replay is optional: Ensemble cannot force an arbitrary sequence to emit immediately. A synchronous
seed remains the first-paint guarantee.

Idle hot-source observation is not marked loading unless an explicit refresh is requested.
Cold sources begin loading when their sequences connect. Empty collections and optional `nil`
are successful available values.

Hot factories should establish observation synchronously or buffer updates before iteration.
On explicit reload of a completed source, Ensemble calls the factory before the refresh action,
but cannot await arbitrary upstream registration. `await reload()` waits for the configured refresh
closure. That closure must await the producer's actual work rather than launching a separate task.
For a cold source, reload waits for the replacement sequence to complete. Cancelling that wait
cancels its replacement subscription; ongoing streams should provide a refresh action.

## Use a property macro when it helps

```swift
@MainActor
final class EntriesModel {
  let useCase: EntriesUseCase

  @ViewDataSource(
    make: { (model: Self) in model.useCase.values() },
    refresh: { model in await model.useCase.reload() }
  )
  var entries: ViewData<[Entry]>

  init(useCase: EntriesUseCase, initial: ViewDataAvailability<[Entry]>) {
    self.useCase = useCase
    entries = ViewData(initial)
  }
}
```

There is no model-level macro, protocol, context property, or `$entries` projection. The property
must be one stored instance `var`, explicitly typed as `ViewData<Value>`, in a main-actor class.
The macro generates backing storage, an init accessor, and a getter. After initialization the
property holds the same data instance; change its producer with `replaceSource`.

Reading the property installs a weak-owner factory once without starting work. A source-aware
initializer supplied by the caller takes precedence over the macro's default source. For a fixed
declaration-site seed, specify `initialValue: .available(cachedValue)` on the macro or give the
property a `ViewData` initializer. Do not supply both. Otherwise initialize it in the model's init.

### Observation compatibility

In an `@Observable` model, put `@ObservationIgnored` **after** `@ViewDataSource`:

```swift
@ViewDataSource(make: { (model: Self) in model.useCase.values() })
@ObservationIgnored
var entries: ViewData<[Entry]>
```

This prevents competing accessor expansions. The stable `ViewData` observes its own contents.
The attribute order matters with the current compiler. This extra annotation is a prototype
limitation; the source-aware initializer on an ordinary property needs no special annotation.

Use `(model: Self)` on `make` to avoid repeating the model's class name, including in generic
models. Swift infers the refresh closure's owner from it. Fully untyped `{ model in ... }` is not
supported: macro arguments are checked before generated code can provide the enclosing owner type.

Macro callbacks must be inline closures so the macro can inspect their syntax. It diagnoses direct
instance `self` or `super` references, including capture lists and nested closures. Comments, string
literals, and metatype expressions such as `Entry.self` are allowed. This checks direct captures;
it cannot prove that a helper or returned sequence avoids retaining the owner parameter.

Factories do not hold their owning model between invocations. A returned sequence can still retain
that model if its producer captures it.

## Request a whole screen

```swift
func reload() async {
  await Ensemble.reload(profile, activity, notifications)
}
```

Use the same model method from `.task` and `.refreshable` when the sources are passive streams
that need an explicit request. The batch establishes observation, starts the configured requests
concurrently, and awaits every action. Different value types are accepted. Each source keeps its
own presentation state and failures; siblings continue after one source fails. Cancellation
propagates to outstanding work. Batch completion is not an aggregate success result.

The batch releases its temporary leases after all actions finish. Rendered consumers keep streaming
through their own leases. See [Sources and lifecycle](sources-and-lifecycle.md#reload-several-sources-together)
for cold startup behavior and overlapping direct reloads.

## Adapt result/reset streams

Result streams use the default adapter. Supply `receive` for a source such as Continuum's
`Composition`, whose updates include both results and invalidation:

```swift
@ViewDataSource(
  make: { (model: Self) in model.displayUser },
  refresh: { model in await model.displayUser.load(using: .remote) },
  receive: { update, sink in
    switch update {
    case .result(let result): sink.receive(result)
    case .reset: sink.reset()
    }
  }
)
@ObservationIgnored
var user: ViewData<DisplayUser>
```

The initializer accepts the same adapter:

```swift
let user = ViewData<DisplayUser>(
  initial,
  make: { displayUser },
  refresh: { await displayUser.load(using: .remote) },
  receive: { update, sink in
    switch update {
    case .result(let result): sink.receive(result)
    case .reset: sink.reset()
    }
  }
)
```

Here `displayUser` is an application-owned Continuum composition. No Continuum dependency is
required by Ensemble itself. The owner-taking initializer and `replaceSource` accept `receive`
as well. Adapters run on the main actor and their sinks ignore obsolete connections. Ordinary
`Result` streams may omit `receive`, pass `nil`, or provide a custom mapping. Other element types
require an adapter at compile time. Macro adapters follow the same inline-closure and capture
checks as factory and refresh callbacks.

The refresh callback is async. Use `.refreshable { await model.user.reload() }` to keep the
refresh control active until the command finishes. Subscription remains passive; observing the
composition does not execute its loading actions. Initial loading and cache-policy choices are
explicit application actions.

## Replace the producer, keep presentation state

```swift
entries.replaceSource(
  make: repository.values,
  refresh: repository.reload
)
```

Replacement cancels the old binding and rejects later results or retry actions from that binding.
Active observation reconnects immediately; inactive data keeps the new factory dormant. Replacement
calls the new factory without invoking its refresh action. The seed was applied at construction;
replacement does not accept another initial value.

The latest successful value stays in the same `ViewData`. Existing `AsyncContent` loading and
failure policies present it, including successful empty or optional nil values. The model and
every consumer use that single typed successful value throughout the source change.

A replacement hot source may replay cached data or simply listen; replacing it does not request a
load. Call `await reload()` after replacement when an explicit refresh is desired.

For a domain boundary, invalidate before replacing:

```swift
entries.reset()
entries.replaceSource(
  make: { repository.values(for: newAccountID) },
  refresh: { await repository.reload(for: newAccountID) }
)
```

All consumers see the invalidation because the model owns the single successful value. Constructing
a completely new `ViewData` also creates fresh presentation state; `AsyncContent` does not copy or
retain another instance's content across that change.

Environment-dependent collaborators can be supplied when the view is installed, through a model
action that calls `replaceSource`. Do not publish model mutations from `body`. For cached first-paint
content, an environment-reading parent can construct a child model with resolved dependencies and
a synchronous seed; source replacement from `.task` alone cannot guarantee that timing.

## Migrate and verify

- Seeded initialization uses `ViewData(.available(value))`; plain-value initialization is gone.
- `ViewDataContext` is removed. Replace separate data creation and binding with a source-aware
  initializer. `AsyncContent` observes automatically; use a task awaiting `data.observe()` for an
  explicit lifetime. Replace `context.load(operation, to: data)` with `await data.load(operation)`,
  and `context.reload(data)` with `await data.reload()`. Cancel observation tasks to release their leases.
- Custom source adapters move from `context.bind` to the initializer or `replaceSource` overload
  with a `receive` closure and a connection-scoped sink.
- Remove corresponding startup tasks only after the data owns its source.
- Keep data instances stable across source changes and use `reset()` for deliberate invalidation.
- Macro clients need the compiler plugin to be trusted by their build environment.

The sample's **Source lifecycle** scenario demonstrates synchronous seeds, retained data throughout
source replacement, manual response delivery, and lazy property-macro activation. Package tests cover
macro expansion, leases, cancellation, weak owners, explicit refresh, obsolete results and retry actions,
and retained source replacement in a hosted SwiftUI List.
