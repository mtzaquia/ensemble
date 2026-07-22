# Presentation policies

`AsyncContent` maps one `ViewData` phase to SwiftUI without adding a `List`, `Section`, stack, or other layout container. Loading and failure policies belong at the call site, so two views can present the same state differently.

## Choose loading behavior

Pass an `AsyncContentLoadingPolicy` through the `loading` argument:

| Policy | Rendering while loading | Content source |
| --- | --- | --- |
| `.hidden` | Nothing | — |
| `.cached` | The latest successful value when one exists; otherwise nothing | `.cached` |
| `.placeholder(value)` | The latest successful value when one exists; otherwise the supplied placeholder | `.cached` or `.placeholder` |

The default is `.cached`. Before the first successful value it renders nothing; on later loads it keeps the latest successful value visible. Use `.placeholder(value)` to show a skeleton on the first load while retaining useful content during refresh. Placeholder values are presentation input rather than successful data: Ensemble does not store them in `ViewData.latest`.

Use the `AsyncContentSource` passed to the success builder to adjust presentation without changing the data model:

```swift
AsyncContent(
  viewModel.entries,
  loading: .placeholder(Entry.placeholders)
) { entries, source in
  ForEach(entries) { entry in
    EntryRow(entry: entry)
  }
  .redacted(reason: source == .placeholder ? .placeholder : [])
}
```

When the phase is successful, the source is `.live` whether the value arrived from a load, a bound stream, or the initial-value initializer.

## Animate presentation changes

Use `ViewData.animationValue` with SwiftUI's scoped animation modifier:

```swift
AsyncContent(viewModel.entries) { entries, _ in
  EntryRows(entries)
}
.animation(.default, value: viewModel.entries.animationValue)
```

`animationValue` is an opaque comparison value. It changes for every accepted
presentation update, including loading, success, failure, reset, and retry availability. This
means phase changes can animate even when `latest` is retained, such as failure UI using
`.replace`.

The token does not retain or compare `Value`, so this works when the presented value is not
`Equatable`. Reading it repeatedly without a presentation update returns an equal token, while
tokens from different `ViewData` instances compare unequal.

## Choose failure behavior

When supplying a failure builder, pass an `AsyncContentFailurePolicy` through the `failure` argument:

| Policy | Rendering after failure |
| --- | --- |
| `.cached` | The latest successful value when one exists; otherwise the failure builder |
| `.replace` | The failure builder, even when a latest value exists |

The default is `.replace`, making the presence of a failure builder an explicit choice to present failure UI.

Use `.replace` when failed data should show the failure builder instead of live or retained content. It replaces only the content produced by that `AsyncContent` instance:

```swift
AsyncContent(
  viewModel.profileSummary,
  loading: .placeholder(ProfileSummary.placeholder),
  failure: .replace
) { summary, source in
  ProfileSummaryCard(summary: summary)
    .redacted(reason: source == .placeholder ? .placeholder : [])
} failure: { error, retry in
  ContentUnavailableView {
    Text("Profile summary unavailable")
  } description: {
    Text(error.localizedDescription)
  } actions: {
    if let retry {
      Button("Try again") {
        retry()
      }
    }
  }
}
```

Use `.cached` for refreshable UI where stale content remains useful. The successful-content builder receives source `.cached`, allowing the view to mark the content as retained or stale.

When omitting the failure builder, the initializer instead accepts `AsyncContentFailureFallbackPolicy`:

| Policy | Rendering after failure |
| --- | --- |
| `.hidden` | Nothing |
| `.cached` | The latest successful value when one exists; otherwise nothing |

The default is `.cached`. The separate policy types make invalid combinations unavailable: `.replace` requires failure content, while `.hidden` cannot be paired with an unreachable failure builder.

The retry action is optional and uses the [reload behavior](sources-and-lifecycle.md#choose-binding-reload-behavior) configured when the destination was bound: `.resubscribe` replaces a cold source, while `.refresh(action)` signals a hot or long-lived producer without replacing its active subscription. It is available while a `ViewDataContext` owns a reload-enabled binding, including after the stream finishes. A load does not install its own retry action. Retry is absent when no reload-enabled binding owns the destination, when the binding uses `.disabled`, or after the binding is cancelled.

## Scope policies to UI chunks

Place separate `AsyncContent` values inside a container when sections can resolve independently:

```swift
List {
  AsyncContent(
    viewModel.activity,
    loading: .placeholder(Activity.placeholders),
    failure: .replace
  ) { activity, source in
    ActivitySection(activity: activity, source: source)
  } failure: { error, retry in
    ActivityFailureSection(error: error, retry: retry)
  }

  AsyncContent(
    viewModel.account,
    loading: .cached,
    failure: .cached
  ) { account, source in
    AccountSection(account: account, source: source)
  }
}
```

The outer `List` stays mounted while each section moves through its own phase. An app can also place `AsyncContent` around a larger composed region, but that is ordinary SwiftUI composition rather than a separate whole-screen failure mode in Ensemble.

Next: [Getting started](getting-started.md) · [Sources and lifecycle](sources-and-lifecycle.md)
