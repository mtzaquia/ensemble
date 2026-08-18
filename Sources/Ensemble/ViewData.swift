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

/// An opaque comparison value for intentionally coordinating animations beyond one
/// ``AsyncContent`` presentation.
///
/// This value describes every accepted presentation mutation, including lifecycle, failure, reset,
/// and retry changes. It does not identify changed successful data and should not be used as the
/// smart update trigger for ``AsyncContent``.
///
/// Values from different `ViewData` instances compare unequal. The value changes when its instance
/// enters another lifecycle phase, receives a changed value or error, resets, or changes retry
/// availability.
///
/// When `ViewData` is already successful, receiving another value that compares equal to the latest
/// value does not change this comparison value. The newly supplied value is still retained. Values
/// without `Equatable` conformance are treated as changed whenever they are received.
///
/// It does not retain or compare the presented value, so it remains equatable and sendable
/// regardless of `Value`.
///
/// - Deprecated: Use ``AsyncContent``'s `animation` parameter for local presentation animation. For
///   a larger coordinated update, combine ``ViewData/phase``'s `kind` with a domain projection such
///   as an identifier or revision instead.
@available(
    *,
    deprecated,
    message: "Use AsyncContent's animation parameter for local presentation animation, or combine phase.kind with a domain projection for a larger update."
)
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

// Drives view-local presentation mirroring even when an equal value suppresses animation.
struct ViewDataPresentationRevision: Equatable, Sendable {
    fileprivate let sourceID: UUID
    fileprivate let revision: UInt
}

// Drives AsyncContent's smart update animation independently of lifecycle and retry changes.
struct ViewDataContentRevision: Equatable, Sendable {
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
/// When already successful, receiving a value equal to the latest successful value retains the new
/// value without advancing ``animationValue``. Values without `Equatable` conformance always
/// advance it when received.
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
        var retryAction: ViewDataRetryAction?
        var animationValue = ViewDataAnimationValue()
        var contentRevision = ViewDataContentRevision()
        var revision: UInt = 0
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
    ///
    /// When `Value` is `Equatable`, use this value or a domain projection of it as a higher-level
    /// data-animation trigger. Use ``ViewData/phase``'s `kind` when the trigger should describe a
    /// lifecycle transition instead.
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

    /// An opaque comparison value for intentionally coordinating a larger animation.
    ///
    /// The value changes after every accepted presentation change. When the phase is already
    /// successful, receiving an equal `Value` retains that value without changing this comparison
    /// value. A non-equatable `Value` is always treated as changed.
    ///
    /// - Deprecated: Use ``AsyncContent``'s `animation` parameter for local presentation animation.
    ///   For a larger coordinated update, use `phase.kind` with a meaningful domain projection such
    ///   as `latestValue`, stable IDs, or a server revision.
    @available(
        *,
        deprecated,
        message: "Use AsyncContent's animation parameter for local presentation animation, or combine phase.kind with a domain projection for a larger update."
    )
    public var animationValue: ViewDataAnimationValue {
        presentation.animationValue
    }

    var presentationRevision: ViewDataPresentationRevision {
        ViewDataPresentationRevision(
            sourceID: presentation.animationValue.sourceID,
            revision: presentation.revision
        )
    }

    var contentRevision: ViewDataContentRevision {
        presentation.contentRevision
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
        self.presentation.contentRevision = self.presentation.contentRevision.advanced()
    }

    // Work around swiftlang/swift#90385.
    @_optimize(none)
    deinit {}

    func set(_ value: Value) {
        currentLoadingToken = nil
        loadingFailure = nil
        updatePresentation(
            advancingAnimation: shouldAdvanceAnimation(for: value),
            advancingContent: shouldAdvanceContentRevision(for: value)
        ) {
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

    private func shouldAdvanceAnimation(for value: Value) -> Bool {
        guard case .success = presentation.phase else { return true }
        guard case .available(let latestValue) = presentation.latestValue else { return true }
        return valuesAreEqual(latestValue, value) == false
    }

    private func shouldAdvanceContentRevision(for value: Value) -> Bool {
        guard case .available(let latestValue) = presentation.latestValue else { return true }
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
        advancingAnimation: Bool = true,
        advancingContent: Bool = false,
        _ update: (inout Presentation) -> Void
    ) {
        var nextPresentation = presentation
        update(&nextPresentation)
        if advancingAnimation {
            nextPresentation.animationValue = nextPresentation.animationValue.advanced()
        }
        if advancingContent {
            nextPresentation.contentRevision = nextPresentation.contentRevision.advanced()
        }
        nextPresentation.revision &+= 1
        presentation = nextPresentation
    }
}
