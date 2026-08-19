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

/// Coordinates one-shot loads and owns the subscriptions that feed ``ViewData`` values.
///
/// Keep a context for as long as its bindings should remain active. Each destination has at most
/// one binding; binding it again cancels and replaces the previous subscription.
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
        var reloadAction: ViewDataRetryAction?
        let removeRetryAction: @MainActor () -> Void
        var finishLoading: @MainActor () -> Void = {}

        init(removeRetryAction: @escaping @MainActor () -> Void) {
            self.removeRetryAction = removeRetryAction
        }
    }

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
        let loadingToken = destination.beginLoading()

        do {
            let value = try await operation()
            try Task.checkCancellation()
            destination.set(value)
            ensembleLog.ensembleDebug(.loadSucceeded(destination: identifier))
        } catch is CancellationError {
            destination.finishLoading(loadingToken)
            ensembleLog.ensembleDebug(.loadCancelled(destination: identifier))
        } catch {
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
    /// subscription.
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
        registrations[ObjectIdentifier(destination)]?.reloadAction?()
    }

    /// Cancels and removes the binding for a destination.
    ///
    /// If the destination was loading, it restores the failure that preceded loading, returns to
    /// success when retained data exists, or returns to empty otherwise. Existing success or failure
    /// presentation state is preserved. Cancellation also removes the retry action associated with
    /// the binding.
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

    isolated deinit {
        cancelAll()
    }
}

private extension ViewDataContext {
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
        removeRegistration(identifier)
        ensembleLog.ensembleDebug(
            .bindingStarted(destination: identifier, reload: reload.logMode)
        )

        let registration = Registration(removeRetryAction: { [weak destination] in
            destination?.removeRetryAction()
        })
        let reloadAction = makeReloadAction(
            reload,
            makeSource: makeSource,
            destination: destination,
            identifier: identifier,
            registration: registration,
            receive: receive
        )

        registrations[identifier] = registration
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
        let sink = makeSink(
            destination: destination,
            identifier: identifier,
            registration: registration
        )
        let task = Task { [weak self, weak registration] in
            do {
                for try await element in source {
                    guard Task.isCancelled == false else { return }
                    guard let self, let registration else { return }
                    guard self.registrations[identifier] === registration else { return }
                    receive(element, sink)
                }
            } catch is CancellationError {
                return
            } catch {
                guard Task.isCancelled == false else { return }
                guard let self, let registration else { return }
                guard self.registrations[identifier] === registration else { return }
                let failure: Result<Value, any Error> = .failure(error)
                sink.receive(failure)
            }

            guard Task.isCancelled == false else { return }
            guard let self, let registration else { return }
            guard self.registrations[identifier] === registration else { return }
            registration.finishLoading()
            registration.task = nil
            ensembleLog.ensembleDebug(.bindingCompleted(destination: identifier))
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
                guard self.registrations[identifier] === registration else { return }
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
                guard self.registrations[identifier] === registration else { return }
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
            guard self.registrations[identifier] === registration else { return }

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
