# Ensemble sample app

The sample app is a UI/platform showcase for `ViewData` and `AsyncContent`. Each catalog screen
keeps its state local, uses deterministic fixtures, and places the explanation beside the behavior
it demonstrates.

All stream-backed models declare their sources at initialization. `AsyncContent` manages their
observation, and the models reload directly through their data properties. One-shot examples use
`await entries.load(...)`; no separate context or binding-start method is required. Reload is async:
Screen replacement's pull-to-refresh awaits the new cold request, and custom async refresh actions
can await producer work directly.

## Run a scenario

Open `SampleApp/SampleApp.xcodeproj` and run the `SampleApp` scheme on an iOS 17 or newer
simulator. For a direct launch into one screen, pass:

```text
UI_TESTING --scenario=animated-reordering
```

The `UI_TESTING` flag disables platform animations for deterministic final-state assertions. Omit it
for manual inspection of transitions.

## Source lifecycle (v3 prototype)

Launch `UI_TESTING --scenario=source-lifecycle` or select **Source lifecycle** from the catalog.
The model uses source-aware `ViewData` initialization. A separate model demonstrates
`@ViewDataSource` without a context, lifecycle method, model-level macro, or projected value.

1. The first source exposes cached rows immediately.
2. Choose **Swap source**. The model keeps its successful value in the same instance, and the
   view keeps showing those rows. Connecting the new source does not request a refresh.
   Choose **Reload** to enter loading with a Retained badge instead of placeholders.
3. Choose **Fail response** to retain those rows through failure, then **Reload** and
   **Deliver response** to recover with the new source's rows.
4. Choose **Show macro source** and scroll its rows into view. Its connection count changes from
   zero only when rendered.
5. Hide that consumer to release its lease; SwiftUI may retain state for offscreen list rows, so
   visibility alone is not the source-lifetime contract.

| Promise | Evidence | Primary proof |
| --- | --- | --- |
| Seeds are synchronous; factories are lazy | Cached rows before connection; macro count starts at zero | Package tests and sample UI test |
| An empty renderer still activates its source | Hidden source delivers without an ancestor task | Hosted SwiftUI test |
| Source replacement retains real model data | Old rows remain available in the model throughout the request | Package, hosted List, and sample UI tests |
| Leases share work and cancel after their last consumer | One connection for two observers, no binding after cancellation | Package tests |
| Macro-generated owners are weak | Model deallocates while data is independently observed | Package test |

The source-aware initializer is the simplest path for observable models. The prototype's property
macro requires `@ObservationIgnored` after its annotation when used inside an `@Observable` class.
See [Source-backed data](../docs/source-backed-data.md) for policies, lifecycle, and migration.

## Animated reordering

The `animated-reordering` scenario is the direct animation acceptance path:

1. A placeholder is mounted without a first-draw fly-in.
2. A delayed local result replaces it without an Ensemble animation because phase animation starts
   disabled.
3. Consumer-owned animation on the enclosing `List`, driven by `latestValueRevision`, handles
   stable-ID insertion, removal, and reordering while row detail changes use a row-level trigger.
4. Hide and restore the section to see phase-driven removal and insertion.
5. Toggle consumer list animation and phase animation independently.
6. Enable phase animation and use “Replay placeholder loading” to
   opt into `.phaseAnimation(.snappy)`, then disable it and replay again to compare. The sibling
   updates alongside the reset without being configured for a phase animation.

The source badge, stable row identifiers, inserted and removed rows, changed row detail, and action
text make each ownership boundary legible. The same ambient-transaction approach works when the
identity-bearing content is hosted by a list, stack, or another container. UI tests verify
placeholder/latest visibility, both reorder directions, hidden/restore behavior, and all animation
toggles. Hosted SwiftUI package tests inspect descendant transactions and native List row-position
animations to verify phase-animation scope, the unanimated default, inherited transactions, and
same-phase updates. The independent-sections screen applies `.phaseAnimation(.snappy)` to its
entire List; no additional List animation modifier is needed for its phase-driven structural changes.
Final-state UI tests do not prove motion; inspect the scenario directly in Simulator for that part
of the contract.

## Cached refresh

Launch `UI_TESTING --scenario=cached-refresh` for deterministic UI assertions, or open Cached
refresh from the catalog without `UI_TESTING` for normal interaction. The sample starts with seeded
successful rows and uses `loading: .placeholder(...)` plus `failure: .retained`.

1. Choose **Manual**, then **Refresh successfully**. The source badge becomes Retained. Read and
   tap the existing rows: they stay visible and interactive for the entire request, with no timer
   turning them into skeletons. The row-tap count confirms interaction.
2. Choose **Deliver pending response**. The new result appears immediately with the Latest badge.
3. Choose **Fast** and refresh again, then compare with **Slow** (two seconds). Both retain the
   previous value until the producer publishes a result. These timings simulate source latency;
   they do not delay results or control loading presentation inside Ensemble.
4. Choose **Manual**, then **Load empty result** and deliver it. Refresh successfully again: the
   confirmed-empty message remains visible with Retained until you deliver the populated result.
   An empty collection is a successful value, not a reason to bring back placeholders.
5. Refresh with failure and deliver it. Real content remains visible through failure. This also
   works with the confirmed-empty result. A later successful refresh recovers the same binding.
6. Choose **Invalidate and reload** in Manual mode. This action explicitly calls `reset()`;
   placeholders and their badge appear immediately and placeholder row buttons are disabled.
   Deliver the result to restore real, interactive content. Ordinary refresh never calls `reset()`.
7. **Load one value** exercises an immediate one-shot load into the same destination without
   replacing the long-lived subscription; response timing applies only to the stream controls.

The List and controls stay mounted through content changes. The builder redacts and disables rows
only for `source == .placeholder`; `.retained` always represents real data. In an app, reset only
when the previous value is unsuitable, and cancel obsolete producers before they can publish into
the invalidated destination. Do not redact retained rows based on the loading phase or elapsed time.
See [the presentation guide](../docs/presentation-policies.md#keep-successful-content-visible-throughout-refresh)
for the consumer pattern and troubleshooting.

UI tests hold manual responses to inspect retained populated and empty content, row interaction,
failure, recovery, and invalidation before completion. They also exercise immediate stream results.
For transient flashes, record Fast and Slow refreshes without `UI_TESTING` and inspect intermediate
frames. Settled screenshots and final-state assertions alone do not prove that no flash occurred.

## Validation

Use the package tests for state, snapshot, and rendered-category semantics, then use XcodeBuildMCP
for the SampleApp build and serial UI suite. The simulator acceptance scenario is deterministic and
uses only local fixtures; no network or account state is required.
