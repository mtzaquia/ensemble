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

/// An opaque comparison value for successful-data changes in one ``ViewData`` instance.
///
/// The value advances when an available successful value is replaced by an unequal successful
/// value. The first success, the first success after ``ViewData/reset()``, lifecycle changes,
/// failures, retry changes, and equal replacements do not advance it. Equal replacements still
/// retain the newly supplied instance.
///
/// Values without `Equatable` conformance are treated as changed after their first successful
/// value. Optional values distinguish unavailable state from an available `nil`. Values from
/// separate `ViewData` instances always compare unequal.
///
/// The value describes domain equality, not collection identity. Use a stable-ID projection when
/// animation should respond only to insertion, removal, or reordering.
public struct ViewDataLatestValueRevision: Equatable, Sendable {
    fileprivate let sourceID: UUID
    fileprivate let revision: UInt

    fileprivate init(sourceID: UUID = UUID(), revision: UInt = 0) {
        self.sourceID = sourceID
        self.revision = revision
    }

    fileprivate func advanced() -> Self {
        Self(sourceID: sourceID, revision: revision &+ 1)
    }
}

// Identifies every accepted presentation or builder-input change for one ViewData instance.
struct ViewDataPresentationRevision: Equatable, Sendable {
    fileprivate let sourceID: UUID
    fileprivate let revision: UInt
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
        /// The case-only lifecycle identity of a ``ViewData`` phase.
        public enum Kind: Equatable, Sendable {
            /// No successful value has been supplied, or the state was explicitly cleared.
            case empty

            /// The state is waiting for its next update.
            case loading

            /// A successful value is available.
            case success

            /// The latest update contained an error.
            case failure
        }

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

        /// The case-only identity of this phase, without its associated error.
        public var kind: Kind {
            switch self {
            case .empty: .empty
            case .loading: .loading
            case .success: .success
            case .failure: .failure
            }
        }
    }

    private struct Presentation {
        var phase: Phase
        var latestValue: ViewDataAvailability<Value>
        var retryAction: ViewDataRetryAction? = nil
        var loadingFailure: (any Error)? = nil
        var latestValueRevision = ViewDataLatestValueRevision()
        var presentationRevision: UInt = 0
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

    /// The current ``ViewDataLatestValueRevision`` for this instance.
    public var latestValueRevision: ViewDataLatestValueRevision {
        presentation.latestValueRevision
    }

    var presentationRevision: ViewDataPresentationRevision {
        ViewDataPresentationRevision(
            sourceID: presentation.latestValueRevision.sourceID,
            revision: presentation.presentationRevision
        )
    }

    var retryAction: ViewDataRetryAction? {
        presentation.retryAction
    }

    var loadingFailure: (any Error)? {
        presentation.loadingFailure
    }

    @ObservationIgnored private var nextLoadingToken: UInt = 0
    @ObservationIgnored private var currentLoadingToken: UInt?

    /// Creates empty presentation state.
    public init() {
        self.presentation = Presentation(
            phase: .empty,
            latestValue: .unavailable
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
            latestValue: .available(value)
        )
    }

    // Work around swiftlang/swift#90385.
    @_optimize(none)
    deinit {}

    func set(_ value: Value) {
        currentLoadingToken = nil
        updatePresentation(
            advancingLatestValueRevision: shouldAdvanceLatestValueRevision(for: value)
        ) {
            $0.latestValue = .available(value)
            $0.phase = .success
            $0.loadingFailure = nil
        }
    }

    func fail(_ error: any Error) {
        currentLoadingToken = nil
        updatePresentation {
            $0.phase = .failure(error)
            $0.loadingFailure = nil
        }
    }

    @discardableResult
    func beginLoading() -> UInt {
        nextLoadingToken &+= 1
        currentLoadingToken = nextLoadingToken
        updatePresentation {
            switch $0.phase {
            case .failure(let error):
                $0.loadingFailure = error
            case .loading:
                break // Preserve a failure retained by an overlapping reload.
            case .empty, .success:
                $0.loadingFailure = nil
            }
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
        updatePresentation {
            $0.latestValue = .unavailable
            $0.phase = .empty
            $0.loadingFailure = nil
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
        updatePresentation {
            $0.phase = if let loadingFailure = $0.loadingFailure {
                .failure(loadingFailure)
            } else {
                switch $0.latestValue {
                case .unavailable:
                    .empty
                case .available:
                    .success
                }
            }
            $0.loadingFailure = nil
        }
    }

    private func shouldAdvanceLatestValueRevision(for value: Value) -> Bool {
        guard case .available(let latestValue) = presentation.latestValue else { return false }
        return valuesAreEqual(latestValue, value) == false
    }

    private func valuesAreEqual(_ lhs: Value, _ rhs: Value) -> Bool {
        func compare<EquatableValue: Equatable>(
            _ lhs: EquatableValue,
            _ rhs: Any
        ) -> Bool {
            guard let rhs = rhs as? EquatableValue else { return false }
            return lhs == rhs
        }

        guard let lhs = lhs as? any Equatable else { return false }
        return compare(lhs, rhs)
    }

    private func updatePresentation(
        advancingLatestValueRevision: Bool = false,
        _ update: (inout Presentation) -> Void
    ) {
        var nextPresentation = presentation
        update(&nextPresentation)
        if advancingLatestValueRevision {
            nextPresentation.latestValueRevision = nextPresentation.latestValueRevision.advanced()
        }
        nextPresentation.presentationRevision &+= 1
        presentation = nextPresentation
    }
}
