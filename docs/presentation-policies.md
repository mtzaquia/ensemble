# Presentation policies

`AsyncContent` turns `ViewData` into one of three rendered categories: hidden, successful content,
or failure content. It adds no layout container, so each call site can choose policies for a row,
section, stack, list, or larger region.

## Resolve the rendered category

`AsyncContent` first projects the latest successful value, then applies the policy for the current
phase. Successful content carries an `AsyncContentSource` describing what the builder received:

- `.latest` for the current successful value;
- `.retained` for a previous successful value shown during loading or failure;
- `.placeholder` for caller-supplied presentation input.

Placeholders are never stored in `ViewData.latestValue`. An empty collection is still a successful
value and belongs in the content builder.

### Choose loading behavior

Pass an `AsyncContentLoadingPolicy` through `loading`:

| Policy | Empty or loading rendering |
| --- | --- |
| `.hidden` | Nothing |
| `.retained` | Retained content when available; otherwise nothing |
| `.placeholder(value)` | Retained content when available; otherwise placeholder content |

The default is `.retained`. Use a placeholder for first-load skeletons while preserving useful
content during later refreshes:

```swift
AsyncContent(
  viewModel.entries,
  loading: .placeholder(Entry.placeholders)
) { entries, source in
  EntryRows(entries)
    .redacted(reason: source == .placeholder ? .placeholder : [])
}
```

The loading policy applies before a source starts, so a placeholder participates in the first
layout pass. When retry begins from visible failure content, that failure stays visible until the
source produces another success or failure. Retained or placeholder loading content does not
replace the failure in between.

### Choose failure behavior

An initializer with a failure builder accepts `AsyncContentFailurePolicy`:

| Policy | Failure rendering |
| --- | --- |
| `.retained` | Retained content when available; otherwise the failure builder |
| `.failureContent` | The failure builder |

The default is `.failureContent`:

```swift
AsyncContent(
  viewModel.profile,
  loading: .placeholder(Profile.placeholder),
  failure: .failureContent
) { profile, source in
  ProfileCard(profile)
    .redacted(reason: source == .placeholder ? .placeholder : [])
} failure: { error, retry in
  ContentUnavailableView {
    Text("Profile unavailable")
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

An initializer without a failure builder accepts `AsyncContentFailureFallbackPolicy` instead:

| Policy | Failure rendering |
| --- | --- |
| `.hidden` | Nothing |
| `.retained` | Retained content when available; otherwise nothing |

The default is `.retained`. Separate policy types prevent selecting failure content when no failure
builder exists.

The optional retry action uses the binding's configured
[reload behavior](sources-and-lifecycle.md#choose-binding-reload-behavior). It is absent for
one-shot loads, `.disabled` bindings, and cancelled bindings.

## Render optional values

The standard initializer preserves the domain type. For `ViewData<Value?>`, its builder therefore
receives `Value?`, including a successful `nil`.

Use `unwrapping:` when the builder should run only for non-`nil` values:

```swift
AsyncContent(unwrapping: viewModel.profile) { profile, source in
  ProfileCard(profile: profile, source: source)
}
```

A successful `nil` remains `.success` in `ViewData`, but renders as hidden through this initializer.
A retained `nil` is likewise unavailable to the builder; an explicit non-optional placeholder can
still render while empty or loading.

Inspect `phase` for lifecycle and `latestValue` for successful-result availability.
`.available(nil)` means the source succeeded with no domain value; `.unavailable` means no
successful result is retained.

## Own animation at the right boundary

Presentation replacement and successful-content changes have different owners.

### Animate presentation replacement

`transitionAnimation` defaults to `.default`. `AsyncContent` explicitly applies it after mount when
the final rendered category changes between hidden, content, and failure. The initial category is
seeded without animation.

Latest, retained, and placeholder values all belong to the content category. Changes such as
placeholder-to-latest, latest-to-retained, and latest-A-to-latest-B therefore receive no
Ensemble-originated animation. A reset that hides content and a later value that restores it are
category changes and can animate.

Pass `nil` when `AsyncContent` should supply no animation for rendered-category changes:

```swift
AsyncContent(
  viewModel.entries,
  transitionAnimation: nil
) { entries, _ in
  EntryRows(entries)
}
```

For content-to-content replacement, `AsyncContent` renders the concrete incoming snapshot directly
in the consumer's current transaction because the category remains stable. For a category change,
it retains the previously displayed snapshot until it commits the incoming category, using
`withAnimation` when `transitionAnimation` is non-`nil`. This keeps consumer-owned list updates
atomic while restoring explicit insertion, removal, and replacement animation at the
hidden/content/failure boundary. `AsyncContent` does not configure a SwiftUI `.transition`
modifier.

### Animate successful content

The consumer owns successful-value animation because it knows the relevant identity and domain
fields. Attach array-replacement animation to the container that performs layout:

```swift
List {
  AsyncContent(viewModel.entries) { entries, _ in
    ForEach(entries) { entry in
      EntryRow(entry: entry)
        .animation(.snappy, value: entry.amount)
    }
  }
}
.animation(.snappy, value: viewModel.entries.latestValueRevision)
```

The revision advances for an unequal replacement of an available successful value. Equal
`Equatable` replacements retain the new instance without advancing. Non-`Equatable` replacements
advance after the first value. First success, reset, first success after reset, lifecycle, failure,
and retry changes do not advance it. Values from different `ViewData` instances compare unequal.

`latestValueRevision` follows whole-value equality, not collection identity. When only insertion,
removal, and reordering should trigger animation, attach an ID projection where the collection value
is available:

```swift
ForEach(entries) { entry in
  EntryRow(entry: entry)
}
.animation(.snappy, value: entries.map(\.id))
```

Both forms work with `List`, `VStack`, `LazyVStack`, and other containers because `AsyncContent`
does not commit content-to-content changes in a separate transaction.

Use `phase.kind` separately when a larger view should respond to lifecycle rather than data.

## Compose independent regions

Place separate `AsyncContent` values in a shared container when regions resolve independently:

```swift
List {
  AsyncContent(viewModel.activity) { activity, source in
    ActivitySection(activity: activity, source: source)
  }

  AsyncContent(
    viewModel.account,
    failure: .retained
  ) { account, source in
    AccountSection(account: account, source: source)
  }
}
```

The container remains mounted while each region resolves its own category and animation boundary.

Next: [Getting started](getting-started.md) · [Sources and lifecycle](sources-and-lifecycle.md)
