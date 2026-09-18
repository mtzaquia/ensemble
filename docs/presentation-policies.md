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

Phase changes and same-phase value updates have separate animation boundaries. Policy-driven
insertion and removal are phase changes too: hidden loading content becoming visible on success
uses the phase animation. When an ancestor independently inserts or removes the entire
`AsyncContent` instance, that ancestor owns the transaction.

### Opt into internal phase animation

Use `.phaseAnimation(_:)` to animate changes between the underlying data's empty, loading,
successful, and failed phases. No phase animation is supplied by default, preserving existing
placeholder-to-content behavior:

```swift
AsyncContent(
  viewModel.entries,
  loading: .placeholder(Entry.placeholders)
) { entries, source in
  EntryRows(entries)
    .redacted(reason: source == .placeholder ? .placeholder : [])
} failure: { error, _ in
  Text(error.localizedDescription)
}
.phaseAnimation(.snappy)
```

The initial presentation does not receive a phase animation. Later phase changes—including
placeholder-to-success, success-to-loading with retained content, and failure recovery—receive
the configured animation inside this AsyncContent. Policy-selected rendering and lifecycle remain
distinct: a loading phase can still render retained rows, and retry can keep failure content
visible while the phase is loading.

The modifier is available on any `View`. Its configuration cascades through the environment to
descendant `AsyncContent` instances, including nested instances. Apply it directly to one instance
or to an enclosing container to configure a region:

```swift
VStack {
  AsyncContent(viewModel.profile) { profile, _ in
    ProfileSummary(profile)
  }
  AsyncContent(viewModel.entries) { entries, _ in
    EntryRows(entries)
  }
  .phaseAnimation(nil)
}
.phaseAnimation(.snappy)
```

Here the profile inherits `.snappy`; the entries clear that phase-animation configuration. The
nearest modifier wins, following normal SwiftUI environment precedence. Each instance supplies
an animated transaction only when its own phase changes. The presentation update is forwarded in
that transaction before the surrounding container performs its structural diff. A `List` can
therefore animate phase-driven insertions and removals without its own `.animation` modifier.
Rendered descendants can animate too. The container may reposition neighboring rows as it reflows;
unrelated presentation updates are not wrapped in that instance's phase-animation transaction.

A non-`nil` phase animation replaces the inherited animation for the presentation update when the
phase changes, including when that update inserts, removes, or replaces rendered views. Passing
`.phaseAnimation(nil)` supplies no phase animation and leaves the inherited transaction intact.
An explicit `nil` overrides inherited phase-animation configuration; it does not strip an animation
already supplied by an ancestor's transaction.
Updates within the same phase, including success-to-success value replacement, receive no phase
animation and preserve their inherited transaction.

This modifier preserves the existing content subtree identity and adds no layout container. It
does not choose a visual transition effect; SwiftUI `.transition` and `.contentTransition`
modifiers remain owned by the views that support them.

The former `transitionAnimation` initializer parameter has been removed. To migrate an explicit
animation, apply `.phaseAnimation(animation)` to the instance instead. Unlike the former parameter,
the modifier also covers placeholder replacement and phase changes that keep the rendering category
unchanged. Omitting it supplies no local animation, including for hidden/content/failure changes.

### Animate updates within successful content

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
