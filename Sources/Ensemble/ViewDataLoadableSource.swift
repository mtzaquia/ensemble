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

/// What prompted a request to refresh a source.
public enum ViewDataReloadReason: Hashable, Sendable {
    /// A refresh requested by the application, such as when a view reappears.
    case automatic

    /// A refresh requested by the user, such as pull-to-refresh or retry.
    case userInitiated
}

/// The request Ensemble sends to a loadable producer.
public enum ViewDataLoadRequest: Hashable, Sendable {
    /// The first request for the selected identity.
    case initial

    /// An explicit reload or failure retry.
    case reload(ViewDataReloadReason)
}

/// A presentation change emitted by a loadable producer or translated from its native updates.
public nonisolated enum ViewDataUpdate<Value> {
    /// Replaces the value on success or presents a failure while retaining the latest success.
    case result(Result<Value, any Error>)

    /// Clears presentation, including the latest successful value.
    case reset
}

extension ViewDataUpdate: Sendable where Value: Sendable {}

/// A producer that can seed presentation, publish updates, and load on demand.
///
/// Return the producer from the `updates:` initializer of `@ViewDataSource`. Construction,
/// reading availability, and subscribing should all be separate from loading. Ensemble calls
/// the producer on the main actor and retains it for the current source identity.
public nonisolated protocol ViewDataLoadableSource<Value> {
    associatedtype Value
    associatedtype Updates: AsyncSequence

    /// The successful value already held by the producer, if any.
    ///
    /// Ensemble reads this once per producer, before subscribing or loading.
    @MainActor var availability: ViewDataAvailability<Value> { get }

    /// Supplies an independent subscription to the producer's updates.
    ///
    /// Ensemble creates its iterator before calling ``viewDataLoad(_:)``. Register at sequence or
    /// iterator creation, or buffer or replay updates until the subscription is ready.
    @MainActor func viewDataUpdates() -> Updates

    /// Translates a native element into a presentation update.
    @MainActor func viewDataUpdate(for element: Updates.Element) -> ViewDataUpdate<Value>

    /// Requests work and awaits its completion. Publish outcomes through the update sequence.
    ///
    /// Ensemble cancels the task when the connection is replaced or the model is released.
    /// The producer owns cancellation and overlapping request policy.
    @MainActor func viewDataLoad(_ request: ViewDataLoadRequest) async
}

extension ViewDataLoadableSource where Self: AsyncSequence, Updates == Self {
    /// Uses the producer itself when it already provides an independent async iterator.
    public func viewDataUpdates() -> Self { self }
}

extension ViewDataLoadableSource where Updates.Element == ViewDataUpdate<Value> {
    /// Applies native Ensemble updates directly.
    public func viewDataUpdate(for element: Updates.Element) -> ViewDataUpdate<Value> { element }
}
