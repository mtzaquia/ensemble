# Inspect source activity

Ensemble can report the load and binding lifecycle through unified logging. Logging is off by
default and is intended to make source ownership, reload behavior, and update ordering visible
during development.

## Enable lifecycle logs

Set `Ensemble.debug` during app startup:

```swift
import Ensemble
import SwiftUI

@main
struct ExampleApp: App {
  init() {
    Ensemble.debug = .trace
  }

  var body: some Scene {
    WindowGroup { ContentView() }
  }
}
```

| Level | Output |
| --- | --- |
| `.off` | No lifecycle logs. |
| `.normal` | Loads, bindings, reloads, cancellations, and failures. |
| `.trace` | Normal logs plus each accepted binding value or reset and source completion. |

These optional logs are compiled out of release builds. They include the destination's identity so
activity from independent `ViewData` values can be distinguished, but do not include loaded values.
Errors are rendered with their descriptions.

Logs use the `eu.lelfe.ensemble` subsystem and `Ensemble` category.

Next: [Sources and lifecycle](sources-and-lifecycle.md)
