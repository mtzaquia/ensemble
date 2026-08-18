# Presentation policies

`AsyncContent` maps one `ViewData` phase to SwiftUI without adding a `List`, `Section`, stack, or
other layout container. Loading, failure, and animation behavior belong at the call site, so two
views can present the same state differently.

## Choose loading behavior

Pass an `AsyncContentLoadingPolicy` through the `loading` argument:

| Policy | Rendering while empty or loading | Content source |
| --- | --- | --- |
| `.hidden` | No successful or placeholder content | — |
| `.retained` | The retained successful value when one exists; otherwise nothing | `.retained` |
| `.placeholder(value)` | The retained successful value when one exists; otherwise the supplied placeholder | `.retained` or `.placeholder` |

Loading policies control the successful-content builder; they do not hide a failure builder that
was already presented. With `.hidden`, an initial load renders nothing, but retrying a presented
failure keeps that failure visible until the source succeeds or fails again. If a loading policy can
supply retained or placeholder content, that content replaces the failure during the retry.

The policy applies to an empty `ViewData` immediately, before a source changes its phase to
loading. A `.placeholder(value)` therefore participates in the first layout pass instead of
briefly rendering no content.

The default is `.retained`. Before the first successful value it renders nothing; on later loads it
keeps the retained successful value visible. Use `.placeholder(value)` to show a skeleton on the
first load while retaining useful content during refresh. Placeholder values are presentation input
rather than successful data: Ensemble does not store them in `ViewData.latestValue`.

Use the `AsyncContentSource` passed to the success builder to adjust presentation without changing
the data model:

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

When the phase is successful, the source is `.latest` whether the value arrived from a load, a
bound stream, or the initial-value initializer. Ensemble marks a previous successful value as
`.retained` while presenting it during loading or after failure; this does not make Ensemble the
data's source of truth.

## Render optional state

Use the `unwrapping:` initializer when `ViewData` holds an optional domain value. Its content
builder receives a non-optional value:

```swift
AsyncContent(unwrapping: viewModel.profile) { profile, source in
  ProfileCard(profile: profile, source: source)
}
```

A successful `nil` remains a successful result in `ViewData`, but this initializer omits its
content. While empty or loading, an explicit `.placeholder(value)` still renders because the
placeholder is non-optional presentation input. A retained `nil` does not count as retained content
for this initializer.

For direct state inspection, use `phase` for the current operation state and `latestValue` for
successful-result availability. `.available(nil)` means the operation succeeded with an absent
domain value; `.unavailable` means no successful result is retained.

## Animate presentation changes

Every `AsyncContent` initializer has an `animation: Animation?` parameter whose default is
`.default`. The default is a smart local animation. The presentation visible on the initial mount is
seeded without animation, so a screen does not fly in on its first draw. After mount, genuine
structural changes are animated at this `AsyncContent` boundary, including hidden/content insertion
or removal, failure/content replacement, and changed successful values. A placeholder becoming
latest or retained content is intentionally not animated; it is a source transition from
presentation input to real data. A latest or retained value becoming a placeholder remains a
genuine replacement and may animate.

The smart policy does not animate the following transitions:

- an equal successful value, including when it is retained during loading or failure;
- a placeholder becoming latest or retained content;
- a latest/retained source-only change when the successful data is unchanged;
- retry-action availability and lifecycle changes that leave the rendered content equivalent;
- a placeholder-to-placeholder or failure-to-failure update.

Values without `Equatable` conformance count as changed whenever a successful value is accepted.
Equal `Equatable` replacements retain the newly supplied instance without triggering smart update
animation. A reset followed by new content is a post-mount structural removal and insertion, so it
animates when those updates are observed separately.

The animation is applied at the `AsyncContent` boundary, so a `List` can animate stable-ID row or
section changes without animating unrelated state that changed in the same action:

```swift
List {
  AsyncContent(viewModel.entries) { entries, _ in
    EntrySection(entries)
  }
}
```

Use a custom curve when the smart update policy is right but the timing should be different:

```swift
AsyncContent(viewModel.entries, animation: .easeInOut(duration: 0.35)) { entries, _ in
  EntrySection(entries)
}
```

Pass `animation: nil` to disable local animation entirely. This is useful for a reduced-motion
branch or an alternate sample path:

```swift
AsyncContent(viewModel.entries, animation: nil) { entries, _ in
  EntrySection(entries)
}
```

Omitting `animation` no longer inherits an animation from the surrounding transaction. It selects
the default smart update policy. The explicit `nil` value disables local animation even when an
ancestor supplies an animated transaction.

## Use higher-level semantic triggers

Use the presentation animation parameter for one `AsyncContent` region. When a larger view owns a
meaningful semantic transition, coordinate it with the state that describes that transition rather
than with Ensemble's internal lifecycle bookkeeping:

- For an `Equatable` `Value`, use `latestValue` (or a domain projection of it) to trigger a data
  animation. This compares the successful domain value and distinguishes unavailable state from an
  available optional `nil`.
- Use `phase.kind` when the larger view should react to lifecycle case changes. `phase.kind` is an
  `Equatable` and `Sendable` projection of `Phase`; it omits the associated failure error while
  preserving the public `Phase` contract.
- For a non-`Equatable` value, expose a meaningful domain projection such as stable IDs, a content
  revision, or a server version and use that projection as the higher-level trigger.

`ViewData.animationValue` and `ViewDataAnimationValue` remain available as deprecated compatibility
API for code that shipped with them. They describe every accepted presentation mutation, including
failure and retry changes, and are not the smart data-animation trigger. Migrate local presentation
animation to `AsyncContent(animation:)`; migrate larger-scope animation to `latestValue`,
`phase.kind`, or a meaningful domain projection.

## Choose failure behavior

When supplying a failure builder, pass an `AsyncContentFailurePolicy` through the `failure` argument:

| Policy | Rendering after failure |
| --- | --- |
| `.retained` | The retained successful value when one exists; otherwise the failure builder |
| `.failureContent` | The failure builder, even when a retained value exists |

The default is `.failureContent`, making the presence of a failure builder an explicit choice to
present failure UI.

Use `.failureContent` when failed data should show the failure builder instead of latest or retained
content. It replaces only the content produced by that `AsyncContent` instance:

```swift
AsyncContent(
  viewModel.profileSummary,
  loading: .placeholder(ProfileSummary.placeholder),
  failure: .failureContent
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

Use `.retained` for refreshable UI where previous content remains useful. The successful-content
builder receives source `.retained`, allowing the view to mark that content as retained or stale.

When omitting the failure builder, the initializer instead accepts `AsyncContentFailureFallbackPolicy`:

| Policy | Rendering after failure |
| --- | --- |
| `.hidden` | Nothing |
| `.retained` | The retained successful value when one exists; otherwise nothing |

The default is `.retained`. The separate policy types make invalid combinations unavailable:
`.failureContent` requires a failure builder, while `.hidden` cannot be paired with an unreachable
failure builder.

The optional retry action uses the configured
[reload behavior](sources-and-lifecycle.md#choose-binding-reload-behavior). It remains available
while a `ViewDataContext` owns a reload-enabled binding, including after its sequence completes.
Retrying marks the destination as loading; a load does not install its own retry action. Retry is
absent for `.disabled` bindings and after cancellation.

## Scope policies to UI chunks

Place separate `AsyncContent` values inside a container when sections can resolve independently:

```swift
List {
  AsyncContent(
    viewModel.activity,
    loading: .placeholder(Activity.placeholders),
    failure: .failureContent
  ) { activity, source in
    ActivitySection(activity: activity, source: source)
  } failure: { error, retry in
    ActivityFailureSection(error: error, retry: retry)
  }

  AsyncContent(
    viewModel.account,
    loading: .retained,
    failure: .retained
  ) { account, source in
    AccountSection(account: account, source: source)
  }
}
```

The outer `List` stays mounted while each section moves through its own phase. An app can also
place `AsyncContent` around a larger composed region, but that is ordinary SwiftUI composition
rather than a separate whole-screen failure mode in Ensemble.

Next: [Getting started](getting-started.md) · [Sources and lifecycle](sources-and-lifecycle.md)
