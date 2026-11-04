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

/// Declares a lazily connected source on a main-actor class property.
///
/// The annotated property must be a `var` explicitly typed as `ViewData<Value>`. Seed it with a
/// property initializer, assign it in the model's initializer, or supply `initialValue` here.
/// Reading the property installs its source once without starting work. `AsyncContent` observes
/// source-backed data automatically; call `ViewData.observe()` for explicit observation.
/// In an `@Observable` model, apply `@ObservationIgnored` after this attribute to prevent competing
/// accessor expansions. The stable `ViewData` observes its own presentation state.
///
/// Factories receive the owning model at invocation time and do not retain it between calls.
/// Write `make: { (model: Self) in model.useCase.values() }`; the refresh closure's owner type
/// is then inferred. Callbacks must be inline closures. Direct instance `self` and `super`
/// references, including capture lists and nested closures, produce compile-time diagnostics.
/// This syntax check cannot prove that helpers or returned sequences avoid retaining the owner;
/// they remain responsible for their own captures and producer cancellation.
/// Hot sources must establish observation synchronously in `make` or buffer results published
/// before iteration starts. Hot streams can remain passive and replay cached outcomes without
/// requesting data. Initial requests belong to the model's explicit loading flow; the refresh
/// action runs only for an explicit reload or retry.
///
/// - Parameters:
///   - make: A prompt factory for a result sequence. Expensive work belongs to its producer.
///   - refresh: An optional action that requests another result from a hot source. Without one,
///     reload cancels the current subscription and invokes `make` again. Await the producer's
///     work in this closure so `reload()` can await its completion.
///   - initialValue: Optional declaration-site availability used to initialize the property.
///   - receive: An optional adapter for result elements. Omit it to apply each result directly.
@attached(accessor, names: named(init), named(get))
@attached(peer, names: prefixed(_))
public macro ViewDataSource<Owner: AnyObject, Value, Source: AsyncSequence, SourceError: Error>(
    make: @escaping @MainActor (Owner) -> Source,
    refresh: (@MainActor (Owner) async -> Void)? = nil,
    initialValue: ViewDataAvailability<Value> = .unavailable,
    receive: (@MainActor (Source.Element, ViewDataSink<Value>) -> Void)? = nil
) = #externalMacro(module: "EnsembleMacros", type: "ViewDataSourceMacro")
where Source.Element == Result<Value, SourceError>

/// Declares a lazy source with application-defined element handling.
///
/// This overload accepts streams such as result/reset updates. The adapter runs on the main actor
/// with a connection-scoped sink; obsolete sinks cannot modify a replacement connection. The same
/// storage, initialization, ownership, and capture rules as the result-source overload apply.
///
/// - Parameters:
///   - make: A prompt factory for the update sequence.
///   - refresh: An optional async action that awaits a hot producer's refresh work.
///   - initialValue: Declaration-site availability used to initialize the property.
///   - receive: Translates each update into successful, failed, or reset presentation state.
@attached(accessor, names: named(init), named(get))
@attached(peer, names: prefixed(_))
public macro ViewDataSource<Owner: AnyObject, Value, Source: AsyncSequence>(
    make: @escaping @MainActor (Owner) -> Source,
    refresh: (@MainActor (Owner) async -> Void)? = nil,
    initialValue: ViewDataAvailability<Value> = .unavailable,
    receive: @escaping @MainActor (Source.Element, ViewDataSink<Value>) -> Void
) = #externalMacro(module: "EnsembleMacros", type: "ViewDataSourceMacro")
