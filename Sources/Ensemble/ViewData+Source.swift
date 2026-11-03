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

extension ViewData {
    /// Creates immediately seeded presentation state with a lazily connected result source.
    ///
    /// The factory is not invoked during initialization. `AsyncContent` observes this source
    /// automatically; `observe()` provides explicit observation. Concurrent consumers share a
    /// subscription, and cancelling the last consumer stops it while retaining successful data.
    /// Use `replaceSource(make:refresh:)` to change the producer while preserving this instance's
    /// successful value and connection policy. The producer never supplies a separate UI fallback.
    /// Factory and refresh closures are retained with their captures. Use the owner-taking
    /// initializer when the callbacks should receive a weakly held owner, as with the macro.
    ///
    /// - Parameters:
    ///   - initialValue: Successful availability to expose before observation starts.
    ///   - make: A prompt result-sequence factory. Hot sources must register or buffer before a
    ///     refresh action can publish a result.
    ///   - refresh: A hot-source refresh action. Omit it to resubscribe on reload.
    ///   - initialRefresh: Whether connecting observation should invoke the refresh action.
    public convenience init<Source: AsyncSequence, SourceError: Error>(
        _ initialValue: ViewDataAvailability<Value> = .unavailable,
        make: @escaping @MainActor () -> Source,
        refresh: (@MainActor () -> Void)? = nil,
        initialRefresh: ViewDataInitialRefresh = .whenUnavailable
    ) where Source.Element == Result<Value, SourceError> {
        self.init(
            initialValue, make: make,
            reload: refresh.map(ViewDataReloadBehavior.refresh) ?? .resubscribe,
            initialRefresh: initialRefresh,
            receive: { result, sink in sink.receive(result) }
        )
    }

    /// Creates seeded presentation state from a sequence with application-defined updates.
    ///
    /// This is the extension point for source-specific update types. The source is connected only
    /// while observed. `receive` runs on the main actor and its sink ignores updates after the
    /// connection is replaced or cancelled. Sequence errors enter failure; cancellation and empty
    /// completion settle loading without discarding a successful value or a preceding failure.
    ///
    /// - Parameters:
    ///   - initialValue: Successful availability to expose immediately.
    ///   - make: A prompt sequence factory, retained for reconnection and reload.
    ///   - reload: Whether reloading resubscribes, signals a hot producer, or is disabled.
    ///   - initialRefresh: Whether connecting invokes a separately supplied refresh action.
    ///   - receive: Translates one source element using a connection-scoped sink.
    public convenience init<Source: AsyncSequence>(
        _ initialValue: ViewDataAvailability<Value> = .unavailable,
        make: @escaping @MainActor () -> Source,
        reload: ViewDataReloadBehavior = .resubscribe,
        initialRefresh: ViewDataInitialRefresh = .whenUnavailable,
        receive: @escaping @MainActor (Source.Element, ViewDataSink<Value>) -> Void
    ) {
        self.init(initialValue)
        binding = ViewDataBinding(
            make: make, reload: reload, initialRefresh: initialRefresh, receive: receive
        )
    }

    /// Creates seeded presentation state with the same weak-owner source wiring as the macro.
    ///
    /// The factory remains dormant until observation starts. The owner is held weakly between
    /// callbacks; if it has been released, connecting does not invoke the factory or refresh.
    /// The callbacks themselves are retained, so use their owner parameter instead of capturing
    /// that owner. Returned sequences remain responsible for their own captures and cancellation.
    /// Successful values are retained across cancellation, refresh, failure, and source replacement.
    ///
    /// - Parameters:
    ///   - initialValue: Successful availability to expose immediately, before observation starts.
    ///   - owner: A collaborator kept alive by the caller for as long as callbacks need it.
    ///   - make: A prompt owner-dependent result-sequence factory.
    ///   - refresh: A hot-source refresh action. Omit it to resubscribe on reload.
    ///   - initialRefresh: Whether connecting observation should invoke the refresh action.
    public convenience init<Owner: AnyObject, Source: AsyncSequence, SourceError: Error>(
        _ initialValue: ViewDataAvailability<Value> = .unavailable,
        owner: Owner,
        make: @escaping @MainActor (Owner) -> Source,
        refresh: (@MainActor (Owner) -> Void)? = nil,
        initialRefresh: ViewDataInitialRefresh = .whenUnavailable
    ) where Source.Element == Result<Value, SourceError> {
        self.init(initialValue)
        _installSource(owner: owner, make: make, refresh: refresh, initialRefresh: initialRefresh)
    }

    /// Installs an owner-dependent source once without invoking its factory.
    ///
    /// This supports generated `@ViewDataSource` accessors and the owner-taking initializer.
    /// Subsequent accesses preserve an explicitly initialized source. The owner is held weakly
    /// and is supplied only while invoking an action.
    ///
    /// - Parameters:
    ///   - owner: The model or collaborator supplied when invoking a source callback.
    ///   - make: The model-dependent sequence factory.
    ///   - refresh: The model-dependent refresh action, if the source is hot.
    ///   - initialRefresh: The connection policy used by this instance.
    public func _installSource<Owner: AnyObject, Source: AsyncSequence, SourceError: Error>(
        owner: Owner,
        make: @escaping @MainActor (Owner) -> Source,
        refresh: (@MainActor (Owner) -> Void)?,
        initialRefresh: ViewDataInitialRefresh
    ) where Source.Element == Result<Value, SourceError> {
        guard binding == nil else { return }
        let weakRefresh: (@MainActor () -> Void)?
        if let refresh {
            weakRefresh = { [weak owner] in
                guard let owner else { return }
                refresh(owner)
            }
        } else {
            weakRefresh = nil
        }
        binding = ViewDataBinding(
            make: { [weak owner] in owner.map(make) },
            reload: weakRefresh.map(ViewDataReloadBehavior.refresh) ?? .resubscribe,
            initialRefresh: initialRefresh,
            receive: { result, sink in sink.receive(result) }
        )
    }

    /// Observes a managed source until the calling task is cancelled.
    ///
    /// Concurrent callers share one subscription. Cancelling the last caller stops the subscription
    /// and removes its retry action while retaining successful content and source configuration.
    /// A later caller reconnects using the declared initial-refresh policy. Completed sequences keep the observation lease alive
    /// so explicit reload can reconnect them. Ordinary data without a managed source returns
    /// immediately. Cancellation is cooperative with the source's producer.
    public func observe() async {
        await binding?.observe(self)
    }

    /// Replaces a managed source without replacing presentation state or connection policy.
    ///
    /// The old subscription is cancelled and its later updates are ignored. Active observation
    /// reconnects immediately using the instance's declared initial-refresh policy. Otherwise
    /// the new factory remains dormant until observation starts. Successful values, including
    /// empty collections and optional nil, stay available through refresh or failure.
    /// Call `reset()` before replacement when the previous domain value is no longer suitable.
    /// This method requires a source declared by the macro or the source-aware initializer.
    ///
    /// Factories are retained. Capture collaborators directly to avoid retaining an owning model.
    ///
    /// - Parameters:
    ///   - make: The new prompt sequence factory.
    ///   - refresh: The new hot-source refresh action; omit it to resubscribe on reload.
    public func replaceSource<Source: AsyncSequence, SourceError: Error>(
        make: @escaping @MainActor () -> Source,
        refresh: (@MainActor () -> Void)? = nil
    ) where Source.Element == Result<Value, SourceError> {
        guard let binding else {
            preconditionFailure("replaceSource requires a managed source")
        }
        binding.replace(
            make: make, reload: refresh.map(ViewDataReloadBehavior.refresh) ?? .resubscribe,
            receive: { result, sink in sink.receive(result) }
        )
    }

    /// Replaces a managed producer with application-defined source updates.
    ///
    /// Active observation reconnects immediately; inactive data keeps the factory dormant.
    /// Successful presentation state and the original initial-refresh policy are preserved.
    /// Old results, retained sinks, and retries are ignored after replacement.
    /// This requires an existing managed source.
    ///
    /// - Parameters:
    ///   - make: The new prompt sequence factory.
    ///   - reload: The new source's reload behavior.
    ///   - receive: Translates source elements using a connection-scoped sink.
    public func replaceSource<Source: AsyncSequence>(
        make: @escaping @MainActor () -> Source,
        reload: ViewDataReloadBehavior = .resubscribe,
        receive: @escaping @MainActor (Source.Element, ViewDataSink<Value>) -> Void
    ) {
        guard let binding else { preconditionFailure("replaceSource requires a managed source") }
        binding.replace(make: make, reload: reload, receive: receive)
    }

    /// Requests another result from an actively observed managed source.
    ///
    /// Hot sources receive their refresh action; cold sources resubscribe. This signals the
    /// producer synchronously and does not await a result. Inactive or unmanaged data is unchanged.
    public func reload() {
        binding?.reload()
    }
}
