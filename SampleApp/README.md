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
2. A delayed local result replaces it without an Ensemble transition because placeholder and latest
   values are both successful content.
3. Consumer-owned animation on the enclosing `List`, driven by `latestValueRevision`, handles
   stable-ID insertion, removal, and reordering while row detail changes use a row-level trigger.
4. Hide and restore the section to see post-mount presentation removal and insertion controlled by
   `transitionAnimation`.
5. Toggle list animation and presentation animation independently, including the
   `transitionAnimation: nil` branch that suppresses category replacement animation.

The source badge, stable row identifiers, inserted and removed rows, changed row detail, and action
text make each ownership boundary legible. The same ambient-transaction approach works when the
identity-bearing content is hosted by a list, stack, or another container. UI tests verify
placeholder/latest visibility, both reorder directions, hidden/restore behavior, and both animation
toggles. They do not prove motion; inspect the scenario directly in Simulator for that part of the
contract.

## Validation

Use the package tests for state, snapshot, and rendered-category semantics, then use XcodeBuildMCP
for the SampleApp build and serial UI suite. The simulator acceptance scenario is deterministic and
uses only local fixtures; no network or account state is required.
