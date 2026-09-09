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

/// Coordinates one-shot loads and owns the subscriptions that feed ``ViewData`` values.
///
/// Keep a context for as long as its bindings should remain active. Each destination has at most
/// one binding across all contexts; binding it again cancels and replaces the previous
/// subscription, including one owned by another context.
///
/// A load and binding can update the same destination in tandem. Their accepted updates are applied
/// in arrival order, and a load does not cancel or replace the binding.
///
/// `ViewDataContext` is main actor-isolated because it coordinates presentation state. Sources and
/// load operations remain responsible for scheduling their own upstream work. Releasing the context
/// cancels every binding it still owns; a load follows the lifetime of the task awaiting it.
@MainActor
public final class ViewDataContext {
    private final class Registration {
        var task: Task<Void, Never>?
        var isActive = true
        var restartAction: (@MainActor () -> Void)?
        var reloadAction: ViewDataRetryAction?
        let removeRetryAction: @MainActor () -> Void
        var finishLoading: @MainActor () -> Void = {}

        init(removeRetryAction: @escaping @MainActor () -> Void) {
            self.removeRetryAction = removeRetryAction
        }
    }

    private struct TrackedDestination {
        weak var destination: AnyObject?
        let clear: @MainActor () -> Void
    }

    private final class Lifecycle {
        var isCurrent = true
    }

    private var lifecycle = Lifecycle()
    private var destinations: [ObjectIdentifier: TrackedDestination] = [:]
    private var registrations: [ObjectIdentifier: Registration] = [:]

    /// Creates a context with no active bindings.
    public init() {}

    /// Performs one throwing asynchronous operation and applies its result to presentation state.
    ///
    /// Loading begins before `operation` is called. A returned value becomes the destination's
    /// latest successful value, while a thrown error enters failure and preserves any latest value.
    /// Cancellation is not presented as a new failure; it restores a failure that preceded loading,
    /// settles to retained success, or settles to empty when no later update has replaced this load's
    /// loading transition.
    ///
    /// A load does not cancel or replace a binding for the same destination. Load completions and
    /// bound results are accepted in arrival order. The load follows the lifetime of the caller's
    /// task and does not install a retry action.
    ///
    /// - Parameters:
    ///   - operation: The one-shot asynchronous operation to perform.
    ///   - destination: The presentation state that receives the operation's result.
    public func load<Value>(
        _ operation: () async throws -> Value,
        to destination: ViewData<Value>
    ) async {
        let identifier = ObjectIdentifier(destination)
        ensembleLog.ensembleDebug(.loadStarted(destination: identifier))
        track(destination)
        let lifecycle = lifecycle
        let loadingToken = destination.beginLoading()

        do {
            let value = try await operation()
            guard lifecycle.isCurrent else { return }
            try Task.checkCancellation()
            destination.set(value)
            ensembleLog.ensembleDebug(.loadSucceeded(destination: identifier))
        } catch is CancellationError {
            guard lifecycle.isCurrent else { return }
            destination.finishLoading(loadingToken)
            ensembleLog.ensembleDebug(.loadCancelled(destination: identifier))
        } catch {
            guard lifecycle.isCurrent else { return }
            guard Task.isCancelled == false else {
                destination.finishLoading(loadingToken)
                ensembleLog.ensembleDebug(.loadCancelled(destination: identifier))
                return
            }
            destination.fail(error)
            ensembleLog.ensembleDebug(.loadFailed(destination: identifier, error: error))
        }
    }

    /// Binds an asynchronous sequence of results to presentation state.
    ///
    /// Binding begins immediately and changes `destination` to loading. Successful and failed
    /// elements update the destination without ending the subscription, so a source can recover
    /// by emitting a later success. If the sequence completes before emitting, a destination still
    /// loading restores the failure that preceded loading, settles to success when retained data
    /// exists, or settles to empty otherwise. Completion after an emitted success or failure
    /// preserves that phase. An error thrown by the sequence enters failure and ends the
    /// subscription. A `CancellationError` thrown by iteration settles loading using the same
    /// rules as completion, without presenting a new failure or disabling configured reloads.
    ///
    /// The factory is invoked synchronously during binding and retained for reloads that need a new
    /// subscription. A method reference strongly retains its instance.
    /// Prefer a dedicated source method such as `useCase.values` when that source should share the
    /// context's lifetime. Avoid passing a method on an owner that also retains this context because
    /// that creates a retain cycle. The factory should return promptly; the sequence's producer
    /// should own any expensive or blocking work.
    ///
    /// - Parameters:
    ///   - makeSource: A factory that promptly creates a sequence for the initial binding and any
    ///     required resubscription.
    ///   - destination: The presentation state that receives source results.
    ///   - reload: The behavior used by ``reload(_:)`` and the retry action exposed to a failure view.
    public func bind<Value, SourceError, Source>(
        _ makeSource: @escaping @MainActor () -> Source,
        to destination: ViewData<Value>,
        reload: ViewDataReloadBehavior = .resubscribe
    )
    where
        SourceError: Error,
        Source: AsyncSequence,
        Source.Element == Result<Value, SourceError>
    {
        bind(makeSource, to: destination, reload: reload) { result, sink in
            sink.receive(result)
        }
    }

    /// Binds an asynchronous sequence with application-defined element handling.
    ///
    /// This is the extension point for source-specific update types. Add a constrained `bind`
    /// overload that forwards here and translates each element with the supplied ``ViewDataSink``.
    /// Binding, completion, cancellation, reload, and retry retain their standard behavior.
    ///
    /// `receive` runs on the main actor after Ensemble confirms that the element belongs to the
    /// active binding. The factory is invoked synchronously and retained for reloads that need
    /// another subscription.
    ///
    /// - Parameters:
    ///   - makeSource: A factory that promptly creates a sequence for the initial binding
    ///     and any required resubscription.
    ///   - destination: The presentation state associated with the binding.
    ///   - reload: The behavior used by ``reload(_:)`` and the retry action exposed to a failure view.
    ///   - receive: Interprets one accepted source element using a binding-scoped sink.
    public func bind<Value, Source>(
        _ makeSource: @escaping @MainActor () -> Source,
        to destination: ViewData<Value>,
        reload: ViewDataReloadBehavior = .resubscribe,
        receive: @escaping @MainActor (
            _ element: Source.Element,
            _ sink: ViewDataSink<Value>
        ) -> Void
    ) where Source: AsyncSequence {
        bindSource(makeSource, to: destination, reload: reload, receive: receive)
    }

    /// Reloads a bound destination using the behavior configured by ``bind(_:to:reload:)``.
    ///
    /// A reload-enabled binding marks the destination as loading before it resubscribes or invokes
    /// its refresh action.
    ///
    /// The method does nothing when this context does not own the destination's binding or when
    /// the binding uses ``ViewDataReloadBehavior/disabled``.
    ///
    /// - Parameter destination: The presentation state whose source should reload.
    public func reload<Value>(_ destination: ViewData<Value>) {
        let identifier = ObjectIdentifier(destination)
        guard let registration = registrations[identifier] else {
            ensembleLog.ensembleDebug(.reloadIgnored(destination: identifier))
            return
        }
        registration.reloadAction?()
    }

    /// Cancels and removes the binding for a destination.
    ///
    /// If the destination was loading, it restores the failure that preceded loading, returns to
    /// success when retained data exists, or returns to empty otherwise. Existing success or failure
    /// presentation state is preserved. Cancellation also removes the retry action associated with
    /// the binding. This method does nothing when another context owns the binding.
    ///
    /// - Parameter destination: The presentation state whose binding should stop.
    public func cancel<Value>(_ destination: ViewData<Value>) {
        removeRegistration(ObjectIdentifier(destination))
    }

    /// Cancels and removes every binding owned by this context, including their retry actions.
    public func cancelAll() {
        let currentRegistrations = registrations
        registrations.removeAll()

        for (identifier, registration) in currentRegistrations {
            registration.task?.cancel()
            registration.removeRetryAction()
            registration.finishLoading()
            ensembleLog.ensembleDebug(.bindingCancelled(destination: identifier))
        }
    }

    /// Begins a fresh context lifecycle, discarding previously tracked presentation data.
    ///
    /// Synchronously invalidates outstanding loads and cancels subscriptions, clears every live
    /// tracked destination, then recreates registered bindings from their saved factories.
    /// Replacement bindings use their original reload behavior and element handler and begin
    /// in initial loading state. Completed bindings restart; explicitly cancelled bindings do not.
    ///
    /// One-shot operations are not rerun. They continue to follow caller cancellation, but their
    /// eventual results and cleanup cannot affect the new lifecycle, even if they ignore cancellation.
    /// Destinations are tracked weakly, including after explicit binding cancellation.
    ///
    /// Unlike ``ViewData/reset()``, which clears a value, and ``reload(_:)``, which preserves
    /// content while refreshing, restart clears the context's presentation history. Applications
    /// decide when session changes require this operation and notify each affected context.
    public func restart() {
        lifecycle.isCurrent = false
        lifecycle = Lifecycle()
        let currentLifecycle = lifecycle
        let currentRegistrations = registrations
        for registration in currentRegistrations.values {
            registration.isActive = false
            registration.task?.cancel()
            registration.task = nil
            registration.removeRetryAction()
        }
        destinations = destinations.filter { $0.value.destination != nil }
        for destination in destinations.values {
            destination.clear()
        }
        for (identifier, registration) in currentRegistrations {
            guard lifecycle === currentLifecycle else { return }
            guard registrations[identifier] === registration else { continue }
            guard destinations[identifier]?.destination != nil else {
                removeRegistration(identifier)
                continue
            }
            registration.restartAction?()
        }
    }

    isolated deinit {
        cancelAll()
    }
}

private extension ViewDataContext {
    private func track<Value>(_ destination: ViewData<Value>) {
        destinations = destinations.filter { $0.value.destination != nil }
        destinations[ObjectIdentifier(destination)] = TrackedDestination(
            destination: destination,
            clear: { [weak destination] in
                destination?.reset()
            }
        )
    }

    private func bindSource<Value, Source>(
        _ makeSource: @escaping @MainActor () -> Source,
        to destination: ViewData<Value>,
        reload: ViewDataReloadBehavior,
        receive: @escaping @MainActor (
            _ element: Source.Element,
            _ sink: ViewDataSink<Value>
        ) -> Void
    ) where Source: AsyncSequence {
        let identifier = ObjectIdentifier(destination)
        track(destination)
        destination.bindingContext?.cancel(destination)
        removeRegistration(identifier)
        ensembleLog.ensembleDebug(
            .bindingStarted(destination: identifier, reload: reload.logMode)
        )

        let bindingID = UUID()
        let registration = Registration(removeRetryAction: { [weak destination] in
            guard let destination, destination.bindingID == bindingID else { return }
            destination.bindingID = nil
            destination.bindingContext = nil
            destination.removeRetryAction()
        })
        registration.restartAction = { [weak self, weak destination] in
            guard let self, let destination else { return }
            self.bindSource(makeSource, to: destination, reload: reload, receive: receive)
        }
        let reloadAction = makeReloadAction(
            reload,
            makeSource: makeSource,
            destination: destination,
            identifier: identifier,
            registration: registration,
            receive: receive
        )

        registrations[identifier] = registration
        destination.bindingID = bindingID
        destination.bindingContext = self
        registration.reloadAction = reloadAction
        if let reloadAction {
            destination.installRetryAction(reloadAction)
        }
        beginLoading(destination, for: registration)
        start(
            makeSource(),
            destination: destination,
            identifier: identifier,
            registration: registration,
            receive: receive
        )
    }

    private func start<Value, Source>(
        _ source: Source,
        destination: ViewData<Value>,
        identifier: ObjectIdentifier,
        registration: Registration,
        receive: @escaping @MainActor (
            _ element: Source.Element,
            _ sink: ViewDataSink<Value>
        ) -> Void
    ) where Source: AsyncSequence {
        guard registrations[identifier] === registration, registration.isActive else { return }
        let sink = makeSink(
            destination: destination,
            identifier: identifier,
            registration: registration
        )
        let task = Task { [weak self, weak registration] in
            defer {
                if let self, let registration, self.registrations[identifier] === registration, registration.isActive {
                    registration.finishLoading()
                    registration.task = nil
                    ensembleLog.ensembleDebug(.bindingCompleted(destination: identifier))
                }
            }

            do {
                for try await element in source {
                    guard Task.isCancelled == false else { return }
                    guard let self, let registration else { return }
                    guard self.registrations[identifier] === registration, registration.isActive else { return }
                    receive(element, sink)
                }
            } catch is CancellationError {
                // A producer can cancel independently of the context. Common terminal cleanup
                // settles loading and allows refresh to attach a new subscription.
            } catch {
                guard Task.isCancelled == false else { return }
                guard let self, let registration else { return }
                guard self.registrations[identifier] === registration, registration.isActive else { return }
                let failure: Result<Value, any Error> = .failure(error)
                sink.receive(failure)
            }
        }

        registration.task = task
    }

    private func makeReloadAction<Value, Source>(
        _ behavior: ViewDataReloadBehavior,
        makeSource: @escaping @MainActor () -> Source,
        destination: ViewData<Value>,
        identifier: ObjectIdentifier,
        registration: Registration,
        receive: @escaping @MainActor (
            _ element: Source.Element,
            _ sink: ViewDataSink<Value>
        ) -> Void
    ) -> ViewDataRetryAction? where Source: AsyncSequence {
        switch behavior {
        case .resubscribe:
            ViewDataRetryAction { [weak self, weak destination, weak registration] in
                guard let self, let destination, let registration else { return }
                guard self.registrations[identifier] === registration, registration.isActive else { return }
                ensembleLog.ensembleDebug(
                    .reloadRequested(destination: identifier, mode: .resubscribe)
                )
                self.bindSource(
                    makeSource,
                    to: destination,
                    reload: .resubscribe,
                    receive: receive
                )
            }

        case .refresh(let refresh):
            ViewDataRetryAction { [weak self, weak destination, weak registration] in
                guard let self, let destination, let registration else { return }
                guard self.registrations[identifier] === registration, registration.isActive else { return }
                ensembleLog.ensembleDebug(
                    .reloadRequested(destination: identifier, mode: .refresh)
                )

                self.beginLoading(destination, for: registration)
                if registration.task == nil {
                    self.start(
                        makeSource(),
                        destination: destination,
                        identifier: identifier,
                        registration: registration,
                        receive: receive
                    )
                }
                refresh()
            }

        case .disabled:
            nil
        }
    }

    private func removeRegistration(_ identifier: ObjectIdentifier) {
        guard let registration = registrations.removeValue(forKey: identifier) else { return }
        registration.task?.cancel()
        registration.removeRetryAction()
        registration.finishLoading()
        ensembleLog.ensembleDebug(.bindingCancelled(destination: identifier))
    }

    private func beginLoading<Value>(
        _ destination: ViewData<Value>,
        for registration: Registration
    ) {
        let loadingToken = destination.beginLoading()
        registration.finishLoading = { [weak destination] in
            destination?.finishLoading(loadingToken)
        }
    }

    private func makeSink<Value>(
        destination: ViewData<Value>,
        identifier: ObjectIdentifier,
        registration: Registration
    ) -> ViewDataSink<Value> {
        ViewDataSink { [weak self, weak destination, weak registration] action in
            guard let self, let destination, let registration else { return }
            guard self.registrations[identifier] === registration, registration.isActive else { return }

            switch action {
            case .value(let value):
                ensembleLog.ensembleDebug(.bindingReceivedValue(destination: identifier))
                destination.set(value)

            case .failure(let error):
                ensembleLog.ensembleDebug(
                    .bindingReceivedFailure(destination: identifier, error: error)
                )
                destination.fail(error)

            case .reset:
                ensembleLog.ensembleDebug(.bindingReceivedReset(destination: identifier))
                destination.reset()
            }
        }
    }
}
