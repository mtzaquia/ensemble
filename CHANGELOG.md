# Release notes

## v3.0.0

- Declare model-owned sources with `@ViewDataSource`, with automatic connection from
  `AsyncContent`, explicit startup through `connect()`, and identity-driven rebinding.
- Adapt producers with `ViewDataLoadableSource` to reuse their cached values, updates, and
  `viewDataLoad(_:)` action across initial loading, reload, and retry.
- Reload individual sources or independent batches with `.automatic` or `.userInitiated`.
  Hot `refresh:` closures receive the owner and reason. Retry is user-initiated.
- Replace `ViewDataContext` registrations with source declarations and direct `ViewData`
  load and reload methods. Seed ordinary data with `ViewData(.available(value))`.
- Configure phase animations with `.phaseAnimation(...)`.
- Follow the [v2 migration guide](docs/source-backed-data.md#migrate-from-v2) when upgrading.

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
