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

import Foundation
import Observation

/// An opaque, immutable comparison value for animating changes exposed by ``ViewData``.
///
/// Compare this value with SwiftUI's `animation(_:value:)` modifier to animate accepted
/// presentation changes. Values from different `ViewData` instances compare unequal, and the value
/// changes when its instance enters another lifecycle phase, receives a value or error, resets, or
/// changes retry availability.
///
/// It does not retain or compare the presented value, so it remains equatable and sendable
/// regardless of `Value`.
public struct ViewDataAnimationValue: Equatable, Sendable {
    fileprivate let sourceID: UUID
    fileprivate let revision: UInt

    fileprivate init(sourceID: UUID, revision: UInt) {
        self.sourceID = sourceID
        self.revision = revision
    }

    fileprivate init() {
        self.sourceID = UUID()
        self.revision = 0
    }

    fileprivate func advanced() -> Self {
        Self(sourceID: sourceID, revision: revision &+ 1)
    }
}

/// Observable presentation state for an initial value or updates supplied by ``ViewDataContext``.
///
/// `ViewData` retains its latest successful value while loading or failed. A view can use that value
/// as cached content without requiring the source to emit it again.
///
/// ``reset()`` clears presentation state without cancelling work. A later accepted update from a
/// load or binding can supply another value.
///
/// `ViewData` and its mutations are main actor-isolated.
@Observable
public final class ViewData<Value> {
    /// The current lifecycle phase of a ``ViewData`` value.
    public enum Phase {
        /// No successful value has been supplied, or the state was explicitly cleared.
        case empty

        /// The state is waiting for its next update.
        ///
        /// The previous successful value, if one exists, remains available through ``latest``.
        case loading

        /// A successful value is available through ``ViewData/latest``.
        case success

        /// The latest update contained an error.
        ///
        /// A subsequent successful update recovers the state without requiring a new binding.
        case failure(any Error)
    }

    /// The current lifecycle phase, including the latest error when the phase is failed.
    public private(set) var phase: Phase

    /// The most recently supplied successful value.
    ///
    /// Loading and failure updates preserve this value. ``reset()`` removes it.
    public private(set) var latest: Value?

    /// An opaque comparison value for animating the current presentation.
    ///
    /// The value changes after every accepted presentation update and does not retain or require
    /// an equatable `Value`. Pass it to SwiftUI's `animation(_:value:)` modifier.
    public private(set) var animationValue = ViewDataAnimationValue()

    var retryAction: ViewDataRetryAction?
    @ObservationIgnored private var nextLoadingToken: UInt = 0
    @ObservationIgnored private var currentLoadingToken: UInt?
    @ObservationIgnored private(set) var loadingFailure: (any Error)?

    /// Creates empty presentation state.
    public init() {
        self.phase = .empty
    }

    /// Creates successful presentation state with an initial value.
    ///
    /// The value is immediately available through ``latest`` and the initial ``phase`` is
    /// ``Phase/success``. Binding a source later preserves this value while the source is loading.
    ///
    /// - Parameter value: The value to expose to observers from creation.
    public init(_ value: Value) {
        self.phase = .success
        self.latest = value
    }

    // Work around swiftlang/swift#90385.
    @_optimize(none)
    deinit {}

    func set(_ value: Value) {
        currentLoadingToken = nil
        loadingFailure = nil
        latest = value
        phase = .success
        advanceAnimationValue()
    }

    func fail(_ error: any Error) {
        currentLoadingToken = nil
        loadingFailure = nil
        phase = .failure(error)
        advanceAnimationValue()
    }

    @discardableResult
    func beginLoading() -> UInt {
        nextLoadingToken &+= 1
        currentLoadingToken = nextLoadingToken
        if case .failure(let error) = phase {
            loadingFailure = error
        } else if case .loading = phase {
            // Keep a failure retained by an overlapping or repeated reload.
        } else {
            loadingFailure = nil
        }
        phase = .loading
        advanceAnimationValue()
        return nextLoadingToken
    }

    /// Removes the latest value and returns the presentation to ``Phase/empty``.
    ///
    /// Resetting presentation state does not cancel an active load or binding. A later accepted
    /// update can replace the empty state. Use ``ViewDataContext/cancel(_:)`` when a binding should
    /// stop as well, and cancel the task awaiting ``ViewDataContext/load(_:to:)`` to stop a load.
    public func reset() {
        currentLoadingToken = nil
        loadingFailure = nil
        latest = nil
        phase = .empty
        advanceAnimationValue()
    }
}

extension ViewData {
    func installRetryAction(_ action: ViewDataRetryAction) {
        retryAction = action
        advanceAnimationValue()
    }

    func removeRetryAction() {
        guard retryAction != nil else { return }
        retryAction = nil
        advanceAnimationValue()
    }

    func finishLoading(_ token: UInt) {
        guard currentLoadingToken == token else { return }
        currentLoadingToken = nil
        if let loadingFailure {
            self.loadingFailure = nil
            phase = .failure(loadingFailure)
        } else {
            phase = latest == nil ? .empty : .success
        }
        advanceAnimationValue()
    }

    private func advanceAnimationValue() {
        animationValue = animationValue.advanced()
    }
}
