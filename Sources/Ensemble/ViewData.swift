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

/// The availability of a successful value retained by ``ViewData``.
///
/// Availability is independent of ``ViewData/phase``. Loading and failure can retain an available
/// value, and an optional value can be available even when its successful result is `nil`.
public enum ViewDataAvailability<Value> {
    /// No successful value has been supplied, or the retained value was removed by
    /// ``ViewData/reset()``.
    case unavailable

    /// A successful value has been supplied and retained.
    case available(Value)
}

extension ViewDataAvailability: Equatable where Value: Equatable {}
extension ViewDataAvailability: Hashable where Value: Hashable {}
extension ViewDataAvailability: Sendable where Value: Sendable {}

/// Observable presentation state for an initial value or updates supplied by ``ViewDataContext``.
///
/// `ViewData` retains its latest successful value while loading or failed. A view can present that
/// retained value without requiring the source to emit it again.
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
        /// The previous successful value, if one exists, remains available through ``latestValue``.
        case loading

        /// A successful value is available through ``ViewData/latestValue``.
        case success

        /// The latest update contained an error.
        ///
        /// A subsequent successful update recovers the state without requiring a new binding.
        case failure(any Error)
    }

    private struct Presentation {
        var phase: Phase
        var latestValue: ViewDataAvailability<Value>
        var retryAction: ViewDataRetryAction?
        var animationValue = ViewDataAnimationValue()
    }

    private var presentation: Presentation

    /// The current lifecycle phase, including the latest error when the phase is failed.
    public var phase: Phase {
        presentation.phase
    }

    /// The availability of the most recently supplied successful value.
    ///
    /// Loading and failure updates preserve this availability. ``reset()`` changes it to
    /// ``ViewDataAvailability/unavailable``. When `Value` is optional, `.available(nil)` represents
    /// a successful result whose domain value is absent.
    public var latestValue: ViewDataAvailability<Value> {
        presentation.latestValue
    }

    /// The most recently supplied successful value, represented as an optional property.
    ///
    /// Loading and failure updates preserve this value. ``reset()`` removes it. When `Value` is
    /// optional, use ``latestValue`` to distinguish an unavailable value from an available `nil`.
    @available(
        *,
        deprecated,
        message: "Use latestValue to distinguish an unavailable value from an available optional nil."
    )
    public var latest: Value? {
        switch latestValue {
        case .unavailable:
            nil
        case .available(let value):
            .some(value)
        }
    }

    /// An opaque comparison value for animating the current presentation.
    ///
    /// The value changes after every accepted presentation update and does not retain or require
    /// an equatable `Value`. Pass it to SwiftUI's `animation(_:value:)` modifier.
    public var animationValue: ViewDataAnimationValue {
        presentation.animationValue
    }

    var retryAction: ViewDataRetryAction? {
        presentation.retryAction
    }
    @ObservationIgnored private var nextLoadingToken: UInt = 0
    @ObservationIgnored private var currentLoadingToken: UInt?
    @ObservationIgnored private(set) var loadingFailure: (any Error)?

    /// Creates empty presentation state.
    public init() {
        self.presentation = Presentation(
            phase: .empty,
            latestValue: .unavailable,
            retryAction: nil
        )
    }

    /// Creates successful presentation state with an initial value.
    ///
    /// The value is immediately available through ``latestValue`` and the initial ``phase`` is
    /// ``Phase/success``. Binding a source later preserves this value while the source is loading.
    ///
    /// - Parameter value: The value to expose to observers from creation.
    public init(_ value: Value) {
        self.presentation = Presentation(
            phase: .success,
            latestValue: .available(value),
            retryAction: nil
        )
    }

    // Work around swiftlang/swift#90385.
    @_optimize(none)
    deinit {}

    func set(_ value: Value) {
        currentLoadingToken = nil
        loadingFailure = nil
        updatePresentation {
            $0.latestValue = .available(value)
            $0.phase = .success
        }
    }

    func fail(_ error: any Error) {
        currentLoadingToken = nil
        loadingFailure = nil
        updatePresentation {
            $0.phase = .failure(error)
        }
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
        updatePresentation {
            $0.phase = .loading
        }
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
        updatePresentation {
            $0.latestValue = .unavailable
            $0.phase = .empty
        }
    }
}

extension ViewData {
    func installRetryAction(_ action: ViewDataRetryAction) {
        updatePresentation {
            $0.retryAction = action
        }
    }

    func removeRetryAction() {
        guard retryAction != nil else { return }
        updatePresentation {
            $0.retryAction = nil
        }
    }

    func finishLoading(_ token: UInt) {
        guard currentLoadingToken == token else { return }
        currentLoadingToken = nil
        if let loadingFailure {
            self.loadingFailure = nil
            updatePresentation {
                $0.phase = .failure(loadingFailure)
            }
        } else {
            let phase: Phase = switch latestValue {
            case .unavailable:
                .empty
            case .available:
                .success
            }
            updatePresentation {
                $0.phase = phase
            }
        }
    }

    private func updatePresentation(_ update: (inout Presentation) -> Void) {
        var nextPresentation = presentation
        update(&nextPresentation)
        nextPresentation.animationValue = nextPresentation.animationValue.advanced()
        presentation = nextPresentation
    }
}
