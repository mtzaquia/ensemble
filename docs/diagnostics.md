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
| `.normal` | Loads, connection starts and their reasons, reload/retry requests, cancellations, and failures. |
| `.trace` | Normal logs plus dormant-source installation, scheduled startup, equal-ID retention, joined initial loads, accepted updates, and completion. |

These optional logs are compiled out of release builds. Turning them on does not connect sources
or change their lifecycle. Macro declarations supply their type and property name automatically;
no diagnostic parameter is added to `@ViewDataSource`.

## Follow one source connection

Source events include `source`, such as `Wallet.sections`, and a destination object identifier.
Use the destination to distinguish two instances of the same declaration. `generation` identifies
one connection of that instance: values, completion, replacement, and teardown carry that same
number. The next connection advances it. One-shot load events keep their destination identifier,
so they can be correlated with source events for the same data.

Connection starts explain their cause:

| `reason` | Meaning |
| --- | --- |
| `render` | Rendering `AsyncContent` requested startup |
| `connect` | A single or batch `connect()` requested startup |
| `reload` | Reload requested work before the source had connected |
| `identityChanged` | The projected ID compared unequal to the previous value |
| `coldReload` | A cold request replaced its previous subscription |
| `completedSource` | A hot reload reconnected a completed source before refreshing |

A reload request records `trigger=reload` or `trigger=retry`. Its generation is the connection
present at the request; a following replacement starts a new generation. Replacement cancellation
uses `reason=replaced`, while model teardown uses `reason=ownerReleased`. Cancelling an awaited
cold request is logged separately from releasing its owner.

For example, the same destination might produce:

```text
[bind] • installed | source="Wallet.sections" destination=ObjectIdentifier(0x1234) state=dormant
[bind] ⏳ scheduled | source="Wallet.sections" destination=ObjectIdentifier(0x1234) reason=connect
[bind] → started | source="Wallet.sections" destination=ObjectIdentifier(0x1234) generation=1 reason=connect reload=refresh
[bind] • kept connection | source="Wallet.sections" destination=ObjectIdentifier(0x1234) generation=1 reason=identityEqual
[bind] • cancelled | source="Wallet.sections" destination=ObjectIdentifier(0x1234) generation=1 reason=replaced
[bind] → started | source="Wallet.sections" destination=ObjectIdentifier(0x1234) generation=2 reason=identityChanged reload=refresh
```

An equal identity renews dependency tracking without restarting its connection. In trace mode,
`reason=identityEqual` makes that decision visible. A first cold reload that shares pending initial
work reports `joined initial load` rather than another connection start.

## Diagnose data that stays seeded

Enable `.trace` before the first property read. An `installed` event with `state=dormant` means the
data exists and its seed has been evaluated. If no `scheduled` or `started` event follows, check
whether an `AsyncContent` actually renders or model startup calls `connect()`. See the
[startup table](source-backed-data.md#connect-without-rendering) for conditional and nested consumers.

Dormancy is valid for seed-only presentation and tests. It produces no timed warning. A previously
installed source will not repeat its installation event if logging is enabled later.

## Log contents

Logs contain declaration names, object identifiers, generations, and lifecycle decisions. They do
not include successful data or projected connection-ID values, even at trace level. Declaration
labels are quoted and escaped. Existing failure events render error descriptions; their contents
are supplied by the error type.

Logs use the `eu.lelfe.ensemble` subsystem and `Ensemble` category.

Next: [Sources and lifecycle](sources-and-lifecycle.md)
