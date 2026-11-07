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

import Observation
import os

// The macro's owner-held storage controls this binding's lifetime. Connection revisions and
// identity tracking reject obsolete producers, sinks, and retries independently of views.
final class ViewDataBinding<Value> {
    private typealias Connect = @MainActor (ViewDataBinding, UInt) -> Bool

    // Resolve weak owners before entering loading, then retain them only for the request.
    private enum ReloadBehavior {
        case resubscribe
        case refresh(@MainActor () -> (@MainActor () async -> Void)?)
        case disabled

        var logMode: EnsembleReloadMode {
            switch self {
            case .resubscribe: .resubscribe
            case .refresh: .refresh
            case .disabled: .disabled
            }
        }
    }

    private let makeConnection: Connect
    private let observeIdentity: @MainActor (@escaping @Sendable () -> Void) -> Bool?
    private let reloadBehavior: ReloadBehavior
    private let logSource: EnsembleLogSource
    private weak var destination: ViewData<Value>?
    private var activationTask: Task<Void, Never>?
    private var isActive = true
    private var canJoinInitialLoad = false
    private var task: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryRevision: UInt = 0
    private var revision: UInt = 0
    private(set) var isConnected = false
    private var loadingToken: UInt?
    private var identityObservation: SourceValidity?
    private var connectionValidity: SourceValidity?
    private var needsRebind = false

    var isRunning: Bool { task != nil }

    init<Owner: AnyObject, ID: Equatable, Source: AsyncSequence>(
        destination: ViewData<Value>,
        owner: Owner,
        declaration: String,
        id: @escaping @MainActor (Owner) -> ID,
        make: @escaping @MainActor (Owner) -> Source,
        refresh: (@MainActor (Owner) async -> Void)?,
        allowsReload: Bool,
        receive: @escaping @MainActor (Owner, Source.Element, ViewDataSink<Value>) -> Void
    ) {
        var previousIdentity: ID?
        self.observeIdentity = { [weak owner] onChange in
            guard let owner else { return nil }
            let identity = withObservationTracking({ id(owner) }, onChange: onChange)
            // Equality can itself read observable properties; keep it outside the tracked scope.
            let changed = previousIdentity.map { $0 != identity } ?? true
            previousIdentity = .some(identity)
            return changed
        }
        if !allowsReload {
            self.reloadBehavior = .disabled
        } else if let refresh {
            self.reloadBehavior = .refresh { [weak owner] in
                guard let owner else { return nil }
                return { await refresh(owner) }
            }
        } else {
            self.reloadBehavior = .resubscribe
        }
        self.makeConnection = Self.connection(make: { [weak owner] in owner.map(make) }) { [weak owner] element, sink in
            guard let owner else { return }
            receive(owner, element, sink)
        }
        self.destination = destination
        self.logSource = EnsembleLogSource(declaration: declaration, destination: ObjectIdentifier(destination))
        ensembleLog.ensembleDebug(.sourceInstalled(source: logSource))
    }

    func connect(reason: EnsembleConnectionReason = .connect) {
        guard isActive, !isConnected, activationTask == nil else { return }
        ensembleLog.ensembleDebug(.connectionScheduled(source: logSource, reason: reason))
        activationTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.activationTask = nil
            self.activate(reason: reason)
        }
    }

    private func activate(reason: EnsembleConnectionReason) {
        activationTask?.cancel()
        activationTask = nil
        guard isActive, !isConnected else { return }
        updateIdentityIfNeeded()
        guard isActive else { return }
        start(reason: reason)
        canJoinInitialLoad = task != nil
    }

    func reload(trigger: EnsembleReloadTrigger = .reload) async {
        guard !Task.isCancelled, isActive else { return }
        if case .disabled = reloadBehavior { return }
        activate(reason: .reload)
        guard isConnected, let destination else { return }
        updateIdentityIfNeeded()
        guard isActive else { return }
        switch reloadBehavior {
        case .resubscribe:
            ensembleLog.ensembleDebug(.reloadRequested(
                source: logSource, generation: revision, mode: .resubscribe, trigger: trigger
            ))
            if !needsRebind, canJoinInitialLoad, task != nil {
                canJoinInitialLoad = false
                ensembleLog.ensembleDebug(.reloadJoinedInitial(source: logSource, generation: revision))
            } else {
                reconnect(startsLoading: true, reason: needsRebind ? .identityChanged : .coldReload)
            }
            await waitForConnection(task)
        case .refresh(let prepare):
            guard let refresh = prepare() else { return }
            ensembleLog.ensembleDebug(.reloadRequested(
                source: logSource, generation: revision, mode: .refresh, trigger: trigger
            ))
            if needsRebind || task == nil || connectionValidity?.isValid == false {
                reconnect(startsLoading: true, reason: needsRebind ? .identityChanged : .completedSource)
            } else {
                beginLoading()
            }
            let currentRevision = revision
            let token = loadingToken
            if isConnected { await refresh() }
            if Task.isCancelled, accepts(currentRevision), let token {
                destination.finishLoading(token)
                if loadingToken == token { loadingToken = nil }
            }
        case .disabled:
            break
        }
    }

    private func waitForConnection(_ connection: Task<Void, Never>?) async {
        let currentRevision = revision
        let validity = connectionValidity
        await withTaskCancellationHandler {
            await connection?.value
        } onCancel: {
            validity?.invalidate()
            connection?.cancel()
        }
        if Task.isCancelled, revision == currentRevision {
            ensembleLog.ensembleDebug(.bindingRequestCancelled(source: logSource, generation: currentRevision))
            task = nil
            destination?.removeRetryAction()
            finishLoading()
        }
    }

    func cancel() {
        isActive = false
        activationTask?.cancel()
        activationTask = nil
        identityObservation?.invalidate()
        identityObservation = nil
        needsRebind = false
        cancelRetry()
        disconnect(reason: .ownerReleased)
    }

    private func start(reason: EnsembleConnectionReason) {
        // Activating a hot source only subscribes. Its refresh action is invoked explicitly by
        // reload/retry. Cold sequences start their work when connected.
        let startsLoading: Bool
        if case .refresh = reloadBehavior { startsLoading = false } else { startsLoading = true }
        reconnect(startsLoading: startsLoading, reason: reason)
    }

    private func reconnect(startsLoading: Bool, reason: EnsembleConnectionReason) {
        needsRebind = false
        disconnect(reason: .replaced)
        guard isActive, let destination else { return }
        isConnected = true
        connectionValidity = SourceValidity()
        let currentRevision = revision
        ensembleLog.ensembleDebug(.bindingStarted(
            source: logSource, generation: currentRevision, reason: reason, reload: reloadBehavior.logMode
        ))
        if case .disabled = reloadBehavior {
            destination.removeRetryAction()
        } else {
            destination.installRetryAction(ViewDataRetryAction { [weak self] in
                guard let self, self.accepts(currentRevision) else { return }
                self.retryTask?.cancel()
                self.retryRevision &+= 1
                let request = self.retryRevision
                self.retryTask = Task { [weak self] in
                    await self?.reload(trigger: .retry)
                    if let self, self.retryRevision == request { self.retryTask = nil }
                }
            })
        }
        if startsLoading { beginLoading() }
        if !makeConnection(self, currentRevision), accepts(currentRevision) { disconnect(reason: .ownerReleased) }
    }

    private func disconnect(reason: EnsembleDisconnectionReason) {
        let previousRevision = revision
        canJoinInitialLoad = false
        connectionValidity?.invalidate()
        connectionValidity = nil
        revision &+= 1
        task?.cancel()
        task = nil
        guard isConnected else { return }
        isConnected = false
        destination?.removeRetryAction()
        finishLoading()
        ensembleLog.ensembleDebug(.bindingCancelled(source: logSource, generation: previousRevision, reason: reason))
    }

    private func accepts(_ revision: UInt) -> Bool {
        guard isActive, isConnected, self.revision == revision else { return false }
        updateIdentityIfNeeded()
        return isActive && !needsRebind && connectionValidity?.isValid == true
    }

    private func updateIdentityIfNeeded() {
        guard isActive, identityObservation?.isValid != true else { return }
        identityObservation?.invalidate()
        let observation = SourceValidity()
        identityObservation = observation
        let changed = observeIdentity { [weak self] in
            // Observation reports willSet. Compare after the setter, or before accepting a
            // subsequent callback. Equal IDs renew tracking without invalidating producer work.
            guard observation.invalidate() else { return }
            Task { @MainActor [weak self] in self?.identityDidChange() }
        }
        guard let changed else { cancel(); return }
        if changed, isConnected {
            needsRebind = true
            connectionValidity?.invalidate()
            cancelRetry()
        } else if isConnected {
            ensembleLog.ensembleDebug(.bindingIdentityUnchanged(source: logSource, generation: revision))
        }
    }

    private func identityDidChange() {
        guard isActive else { return }
        updateIdentityIfNeeded()
        if isActive, needsRebind { start(reason: .identityChanged) }
    }

    private func beginLoading() {
        loadingToken = destination?.beginLoading()
    }

    private func finishLoading() {
        if let loadingToken { destination?.finishLoading(loadingToken) }
        loadingToken = nil
    }

    private static func connection<Source: AsyncSequence>(
        make: @escaping @MainActor () -> Source?,
        receive: @escaping @MainActor (Source.Element, ViewDataSink<Value>) -> Void
    ) -> Connect {
        { binding, revision in
            guard let source = make() else { return false }
            guard binding.accepts(revision) else { return true }
            binding.consume(source, revision: revision, receive: receive)
            return true
        }
    }

    private func consume<Source: AsyncSequence>(
        _ source: Source,
        revision: UInt,
        receive: @escaping @MainActor (Source.Element, ViewDataSink<Value>) -> Void
    ) {
        let sink = ViewDataSink<Value> { [weak self] action in
            guard let self, self.accepts(revision), let destination = self.destination else { return }
            self.canJoinInitialLoad = false
            switch action {
            case .value(let value):
                ensembleLog.ensembleDebug(.bindingReceivedValue(source: self.logSource, generation: revision))
                destination.set(value)
            case .failure(let error):
                ensembleLog.ensembleDebug(.bindingReceivedFailure(source: self.logSource, generation: revision, error: error))
                destination.fail(error)
            case .reset:
                ensembleLog.ensembleDebug(.bindingReceivedReset(source: self.logSource, generation: revision))
                destination.reset()
            }
        }
        task = Task { [weak self] in
            defer {
                if let self, self.accepts(revision) {
                    self.finishLoading()
                    self.task = nil
                    self.canJoinInitialLoad = false
                    ensembleLog.ensembleDebug(.bindingCompleted(source: self.logSource, generation: revision))
                }
            }
            do {
                for try await element in source {
                    guard !Task.isCancelled, self?.accepts(revision) == true else { return }
                    receive(element, sink)
                }
            } catch is CancellationError {
                // Producer cancellation settles loading without disabling the retry action.
            } catch {
                guard !Task.isCancelled else { return }
                sink.receive(Result<Value, any Error>.failure(error))
            }
        }
    }

    private func cancelRetry() {
        retryRevision &+= 1
        retryTask?.cancel()
        retryTask = nil
    }

    isolated deinit {
        cancel()
    }
}

// Identity notifications and request cancellation may arrive from any executor. Separate tokens
// let equal identity changes renew tracking without cancelling a connection or a pending request.
private final class SourceValidity: Sendable {
    private nonisolated let validity = OSAllocatedUnfairLock(initialState: true)

    nonisolated var isValid: Bool { validity.withLock { $0 } }

    @discardableResult
    nonisolated func invalidate() -> Bool {
        validity.withLock { valid in
            guard valid else { return false }
            valid = false
            return true
        }
    }
}
