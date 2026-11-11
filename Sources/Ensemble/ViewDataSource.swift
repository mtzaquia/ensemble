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

/// Declares stable presentation state with a model-owned source on a main-actor class.
///
/// Apply this macro to a get-only instance `var` explicitly typed as `ViewData<Value>`, without a
/// property initializer. The macro creates the data on first read, evaluates `initial` once, and
/// installs a dormant source. Ordinary property, phase, and latest-value reads stay passive.
/// `AsyncContent` requests connection when rendered, or call ``ViewData/connect()`` from a model
/// startup action for badges and conditional gates. Connection is scheduled outside rendering and
/// then remains alive until the model is released, including while consumers are absent.
/// Retaining the returned `ViewData` separately does not keep its source alive.
/// In an `@Observable` model, place `@ObservationIgnored` after this attribute.
///
/// With no `id`, there is no automatic rebinding. Reload and retry keep their configured hot or
/// cold behavior. Source construction is untracked, including synchronous reads inside third-party
/// producers. To rebind automatically,
/// supply an `id` key path whose `Equatable` value identifies the complete connection.
/// Success is retained and the seed is never reapplied. Use ``ViewData/reset()`` before changing
/// domain identity when retaining the old value would be inappropriate.
///
/// All callbacks receive the owner. Adapters run synchronously on the main actor with a
/// connection-scoped sink; obsolete sinks and retries cannot affect a new connection. Callbacks
/// are skipped after owner release. Sources remain responsible for their own captures and
/// cooperative cancellation. A hot factory must register or buffer updates before refresh can
/// publish. Rebinding never invokes refresh; initial requests, reload, and retry are explicit.
/// Cold sequences start work on connection. Repeated reads do not restart completed sequences.
/// A callback temporarily retains the owner while it runs, including across an awaited refresh.
/// The model's creation-time dependency context is not restored around callbacks. `initial` runs
/// in the first reader's context; source tasks inherit their connection context, and refresh runs
/// in the reload caller's task. Prefer owner-held collaborators and explicitly propagate any
/// dependency framework's context when constructing new ones. Keep seeds cheap and read-only.
///
/// Write `(model: Self)` on `initial` or `make` to infer the other callbacks' owner type. Callbacks
/// must be inline closures. Direct instance `self` and `super` captures are diagnosed; use the
/// supplied owner parameter. Syntax checks cannot prove that returned sequences avoid retaining it.
///
/// - Parameters:
///   - initial: An optional synchronous owner-derived seed, evaluated once on first read.
///   - make: A prompt, untracked factory that builds the source.
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

/// Declares a fixed source with application-defined update handling.
///
/// This overload accepts elements such as result/reset updates. The adapter receives the owner
/// and a connection-scoped sink. The same initialization, ownership, and
/// capture rules as the result-source overload apply.
///
/// - Parameters:
///   - initial: An optional synchronous owner-derived seed, evaluated once on first read.
///   - make: A prompt, untracked factory that builds the source.
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

/// Declares a source that rebinds when the value at an identity key path changes.
///
/// Only the key path's projection is observed. `make`, `initial`, `refresh`, `receive`, and equality
/// comparison run outside that tracking scope. Equal identities renew observation without
/// replacing the connection, retry, or sinks. The current identity is checked before accepting
/// subsequent results or invoking reload. Changes coalesce after the main-actor mutation completes.
///
/// Use a pure value identity containing every input that defines a subscription, including producer
/// identity when the producer itself can be replaced. A computed `Equatable` value can combine
/// several inputs. Keep those inputs on the main actor. Retained models keep tracking after source
/// completion. The source and owner lifetime rules of the fixed-source declaration also apply.
///
/// - Parameters:
///   - id: A key-path literal projecting the connection's `Equatable` identity from its owner.
///   - initial: An optional synchronous owner-derived seed, evaluated once on first read.
///   - make: A prompt, untracked factory that builds the source for the current identity.
///   - refresh: An optional async action that awaits a hot producer's work.
///   - allowsReload: Whether explicit reloads and failure retries are enabled.
///   - receive: An optional owner-dependent adapter; omit it to apply each result directly.
@attached(accessor, names: named(get))
@attached(peer, names: prefixed(_))
public macro ViewDataSource<Owner: AnyObject, ID: Equatable, Value, Source: AsyncSequence, SourceError: Error>(
    id: KeyPath<Owner, ID>,
    initial: (@MainActor (Owner) -> ViewDataAvailability<Value>)? = nil,
    make: @escaping @MainActor (Owner) -> Source,
    refresh: (@MainActor (Owner) async -> Void)? = nil,
    allowsReload: Bool = true,
    receive: (@MainActor (Owner, Source.Element, ViewDataSink<Value>) -> Void)? = nil
) = #externalMacro(module: "EnsembleMacros", type: "ViewDataSourceMacro")
where Source.Element == Result<Value, SourceError>

/// Declares an identity-driven source with application-defined update handling.
///
/// The same identity comparison, tracking, ownership, and capture rules as the result-source
/// declaration apply. The adapter translates custom elements with an owner and scoped sink.
///
/// - Parameters:
///   - id: A key-path literal projecting the connection's `Equatable` identity from its owner.
///   - initial: An optional synchronous owner-derived seed, evaluated once on first read.
///   - make: A prompt, untracked factory that builds the source for the current identity.
///   - refresh: An optional async action that awaits a hot producer's work.
///   - allowsReload: Whether explicit reloads and failure retries are enabled.
///   - receive: Translates an element using the owner and a connection-scoped sink.
@attached(accessor, names: named(get))
@attached(peer, names: prefixed(_))
public macro ViewDataSource<Owner: AnyObject, ID: Equatable, Value, Source: AsyncSequence>(
    id: KeyPath<Owner, ID>,
    initial: (@MainActor (Owner) -> ViewDataAvailability<Value>)? = nil,
    make: @escaping @MainActor (Owner) -> Source,
    refresh: (@MainActor (Owner) async -> Void)? = nil,
    allowsReload: Bool = true,
    receive: @escaping @MainActor (Owner, Source.Element, ViewDataSink<Value>) -> Void
) = #externalMacro(module: "EnsembleMacros", type: "ViewDataSourceMacro")

/// Declares a fixed producer that provides its own seed, updates, and load action.
///
/// First access creates a dormant producer and seeds the stable `ViewData` from its availability.
/// Connecting subscribes to that producer and requests its initial load. Reload and retry ask
/// the same producer for a reload, resubscribing first if the sequence completed.
///
/// - Parameters:
///   - updates: A prompt factory for a producer whose construction starts no work.
///   - receive: An optional owner-aware override for applying the producer's native elements.
@attached(accessor, names: named(get))
@attached(peer, names: prefixed(_))
public macro ViewDataSource<Owner: AnyObject, Source: ViewDataLoadableSource>(
    updates: @escaping @MainActor (Owner) -> Source,
    receive: (@MainActor (Owner, Source.Updates.Element, ViewDataSink<Source.Value>) -> Void)? = nil
) = #externalMacro(module: "EnsembleMacros", type: "ViewDataSourceMacro")

/// Declares a loadable producer selected by an observable identity key path.
///
/// A new identity gets its own producer, cache seed, and initial load. Its availability replaces
/// the previous identity's presentation, including when the new producer has no cached value.
///
/// - Parameters:
///   - id: A key-path literal projecting the connection's `Equatable` identity from its owner.
///   - updates: A prompt factory for a producer whose construction starts no work.
///   - receive: An optional owner-aware override for applying the producer's native elements.
@attached(accessor, names: named(get))
@attached(peer, names: prefixed(_))
public macro ViewDataSource<Owner: AnyObject, ID: Equatable, Source: ViewDataLoadableSource>(
    id: KeyPath<Owner, ID>,
    updates: @escaping @MainActor (Owner) -> Source,
    receive: (@MainActor (Owner, Source.Updates.Element, ViewDataSink<Source.Value>) -> Void)? = nil
) = #externalMacro(module: "EnsembleMacros", type: "ViewDataSourceMacro")
