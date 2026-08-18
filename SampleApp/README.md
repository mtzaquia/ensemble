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
2. A delayed local result replaces it after mount without animating the placeholder-to-real-data transition.
3. The default `AsyncContent` animation targets stable-ID row reordering while a sibling counter
   changes independently.
4. Hide and restore the section to see post-mount content removal and insertion.
5. Toggle animation off to exercise the explicit `animation: nil` branch.

The source badge, stable row identifiers, and action text make each state legible. UI tests verify
placeholder/latest visibility, final row order, sibling isolation, hidden/restore behavior, and the
explicit nil branch. They do not prove motion; inspect the scenario directly in Simulator for that
part of the contract.

## Validation

Use the package tests for state and classifier semantics, then use XcodeBuildMCP for the SampleApp
build and serial UI suite. The simulator acceptance scenario is deterministic and uses only local
fixtures; no network or account state is required.
