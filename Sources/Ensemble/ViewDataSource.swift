//
//  Copyright (c) 2026 @mtzaquia
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

@_exported import Observation

/// Declares stable presentation state with an automatically rebound source on a main-actor class.
///
/// Apply this macro to a get-only instance `var` explicitly typed as `ViewData<Value>`, without a
/// property initializer. The macro creates the data on first read, evaluates `initial` once, and
/// schedules activation after the getter returns. The source stays connected until its model
/// is released, including when the property is read only by a badge or a derived condition.
/// Retaining the returned `ViewData` separately does not keep its source alive.
/// In an `@Observable` model, place `@ObservationIgnored` after this attribute.
///
/// After activation, changes to observable properties read synchronously by `make` invalidate the
/// old connection and rebuild the subscription on the main actor after the mutation completes.
/// Keep mutable source-selection state on the main actor.
/// Success is retained and the seed is never reapplied. Use ``ViewData/reset()`` before changing
/// domain identity when retaining the old value would be inappropriate. Reads in the seed,
/// refresh, adapter, or later sequence iteration do not become factory dependencies.
///
/// All callbacks receive the owner. Adapters run synchronously on the main actor with a
/// connection-scoped sink; obsolete sinks and retries cannot affect a new connection. Callbacks
/// are skipped after owner release. Sources remain responsible for their own captures and
/// cooperative cancellation. A hot factory must register or buffer updates before refresh can
/// publish. Rebinding never invokes refresh; initial requests, reload, and retry are explicit.
/// Cold sequences start work on activation. Repeated reads do not restart completed sequences.
/// A callback temporarily retains the owner while it runs, including across an awaited refresh.
///
/// Write `(model: Self)` on `initial` or `make` to infer the other callbacks' owner type. Callbacks
/// must be inline closures. Direct instance `self` and `super` captures are diagnosed; use the
/// supplied owner parameter. Syntax checks cannot prove that returned sequences avoid retaining it.
///
/// - Parameters:
///   - initial: An optional synchronous owner-derived seed, evaluated once on first read.
///   - make: A prompt factory whose synchronous observable reads select the source.
///   - refresh: An optional async action that awaits a hot producer's work. Without one, reload
///     cancels and resubscribes; ongoing streams should provide this action.
///   - allowsReload: Whether explicit reloads and failure retries are enabled.
///   - receive: An optional owner-dependent adapter; omit it to apply each result directly.
@attached(accessor, names: named(get))
@attached(peer, names: prefixed(_))
public macro ViewDataSource<Owner: AnyObject, Value, Source: AsyncSequence, SourceError: Error>(
    initial: (@MainActor (Owner) -> ViewDataAvailability<Value>)? = nil,
    make: @escaping @MainActor (Owner) -> Source,
    refresh: (@MainActor (Owner) async -> Void)? = nil,
    allowsReload: Bool = true,
    receive: (@MainActor (Owner, Source.Element, ViewDataSink<Value>) -> Void)? = nil
) = #externalMacro(module: "EnsembleMacros", type: "ViewDataSourceMacro")
where Source.Element == Result<Value, SourceError>

/// Declares an automatically rebound source with application-defined update handling.
///
/// This overload accepts elements such as result/reset updates. The adapter receives the owner
/// and a connection-scoped sink. The same initialization, dependency tracking, ownership, and
/// capture rules as the result-source overload apply.
///
/// - Parameters:
///   - initial: An optional synchronous owner-derived seed, evaluated once on first read.
///   - make: A prompt factory whose synchronous observable reads select the source.
///   - refresh: An optional async action that awaits a hot producer's work.
///   - allowsReload: Whether explicit reloads and failure retries are enabled.
///   - receive: Translates an element using the owner and a connection-scoped sink.
@attached(accessor, names: named(get))
@attached(peer, names: prefixed(_))
public macro ViewDataSource<Owner: AnyObject, Value, Source: AsyncSequence>(
    initial: (@MainActor (Owner) -> ViewDataAvailability<Value>)? = nil,
    make: @escaping @MainActor (Owner) -> Source,
    refresh: (@MainActor (Owner) async -> Void)? = nil,
    allowsReload: Bool = true,
    receive: @escaping @MainActor (Owner, Source.Element, ViewDataSink<Value>) -> Void
) = #externalMacro(module: "EnsembleMacros", type: "ViewDataSourceMacro")
