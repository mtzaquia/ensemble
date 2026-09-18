# Ensemble sample app

The sample app is a UI/platform showcase for `ViewData` and `AsyncContent`. Each catalog screen
keeps its state local, uses deterministic fixtures, and places the explanation beside the behavior
it demonstrates.

## Run a scenario

Open `SampleApp/SampleApp.xcodeproj` and run the `SampleApp` scheme on an iOS 17 or newer
simulator. For a direct launch into one screen, pass:

```text
UI_TESTING --scenario=animated-reordering
```

The `UI_TESTING` flag disables platform animations for deterministic final-state assertions. Omit it
for manual inspection of transitions.

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

## Validation

Use the package tests for state, snapshot, and rendered-category semantics, then use XcodeBuildMCP
for the SampleApp build and serial UI suite. The simulator acceptance scenario is deterministic and
uses only local fixtures; no network or account state is required.
