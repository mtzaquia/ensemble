# Release notes

## v3.0.0-beta.3

- Rename the loadable producer requirement to `viewDataLoad(_:)`.
- Pass `.automatic` or `.userInitiated` to individual or batch reloads. Loadable producers
  receive the reason in `ViewDataLoadRequest.reload(_:)`. Retry is user-initiated.
- Update hot-source `refresh:` closures to take the owner and reload reason. Use
  `{ owner, _ in … }` when the refresh behaves the same for both reasons.

## v3.0.0-beta.2

- Declare a producer with `@ViewDataSource(updates:)` or `@ViewDataSource(id:updates:)`.
  A `ViewDataLoadableSource` supplies the first value, its native update sequence, and its
  initial and reload actions.
- Loadable sources reuse the producer for reload and retry. An identity change uses the new
  producer's cache and cancels the previous subscription and loads.
- Translate a third-party producer's results and resets once in its conformance. See
  [Loadable sources](docs/source-backed-data.md#loadable-sources) for a Continuum example.
- Replace `Ensemble.connect(...)` with individual `ViewData.connect()` calls in model startup.
- A hot refresh that returns without an update settles loading while its subscription stays active.
