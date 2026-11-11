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
        case refresh(@MainActor (ViewDataReloadReason) -> (@MainActor () async -> Void)?)
        case loadable
        case disabled

        var logMode: EnsembleReloadMode {
            switch self {
            case .resubscribe: .resubscribe
            case .refresh: .refresh
            case .loadable: .loadable
            case .disabled: .disabled
            }
        }
    }

    private struct LoadableSource {
        let subscribe: @MainActor (ViewDataBinding, UInt) -> Void
        let load: @MainActor (ViewDataLoadRequest) async -> Void
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
    private var loadableSource: LoadableSource?
    private var initialLoad: Task<Void, Never>?
    private var loadTasks: [UInt: Task<Void, Never>] = [:]

    var isRunning: Bool { task != nil }

    convenience init<Owner: AnyObject, ID: Equatable, Source: AsyncSequence>(
        destination: ViewData<Value>,
        owner: Owner,
        declaration: String,
        id: @escaping @MainActor (Owner) -> ID,
        make: @escaping @MainActor (Owner) -> Source,
        refresh: (@MainActor (Owner, ViewDataReloadReason) async -> Void)?,
        allowsReload: Bool,
        receive: @escaping @MainActor (Owner, Source.Element, ViewDataSink<Value>) -> Void
    ) {
        let reloadBehavior: ReloadBehavior
        if !allowsReload {
            reloadBehavior = .disabled
        } else if let refresh {
            reloadBehavior = .refresh { [weak owner] reason in
                guard let owner else { return nil }
                return { await refresh(owner, reason) }
            }
        } else {
            reloadBehavior = .resubscribe
        }
        let connect = Self.connection(make: { [weak owner] in owner.map(make) }) { [weak owner] element, sink in
            guard let owner else { return }
            receive(owner, element, sink)
        }
        self.init(destination: destination, owner: owner, declaration: declaration, id: id,
                  reloadBehavior: reloadBehavior, makeConnection: connect)
    }

    convenience init<Owner: AnyObject, ID: Equatable, Source: ViewDataLoadableSource<Value>>(
        destination: ViewData<Value>,
        owner: Owner,
        declaration: String,
        id: @escaping @MainActor (Owner) -> ID,
        initialID: ID,
        source: Source,
        updates: @escaping @MainActor (Owner) -> Source,
        receive: (@MainActor (Owner, Source.Updates.Element, ViewDataSink<Value>) -> Void)?
    ) {
        let prepare: @MainActor (Source) -> LoadableSource = { [weak owner] source in
            LoadableSource(
                subscribe: { binding, revision in
                    guard binding.accepts(revision) else { return }
                    let subscription = SourceSubscription(iterator: source.viewDataUpdates().makeAsyncIterator())
                    guard binding.accepts(revision) else { return }
                    binding.consume(subscription, revision: revision) { element, sink in
                        guard let owner else { return }
                        if let receive {
                            receive(owner, element, sink)
                        } else {
                            sink.receive(source.viewDataUpdate(for: element))
                        }
                    }
                },
                load: { request in await source.viewDataLoad(request) }
            )
        }
        self.init(
            destination: destination, owner: owner, declaration: declaration, id: id,
            initialID: .some(initialID), reloadBehavior: .loadable
        ) { [weak owner] binding, revision in
            if binding.loadableSource == nil {
                guard let owner else { return false }
                let source = updates(owner)
                let availability = source.availability
                guard binding.accepts(revision) else { return true }
                binding.loadableSource = prepare(source)
                switch availability {
                case .available(let value): binding.destination?.set(value)
                case .unavailable: binding.destination?.reset()
                }
            }
            binding.loadableSource?.subscribe(binding, revision)
            return true
        }
        loadableSource = prepare(source)
    }

    private init<Owner: AnyObject, ID: Equatable>(
        destination: ViewData<Value>,
        owner: Owner,
        declaration: String,
        id: @escaping @MainActor (Owner) -> ID,
        initialID: ID? = nil,
        reloadBehavior: ReloadBehavior,
        makeConnection: @escaping Connect
    ) {
        var previousIdentity = initialID
        self.observeIdentity = { [weak owner] onChange in
            guard let owner else { return nil }
            let identity = withObservationTracking({ id(owner) }, onChange: onChange)
            // Equality can itself read observable properties; keep it outside the tracked scope.
            let changed = previousIdentity.map { $0 != identity } ?? true
            previousIdentity = .some(identity)
            return changed
        }
        self.reloadBehavior = reloadBehavior
        self.makeConnection = makeConnection
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

    private func activate(reason: EnsembleConnectionReason, startsInitialLoad: Bool = true) {
        activationTask?.cancel()
        activationTask = nil
        guard isActive, !isConnected else { return }
        updateIdentityIfNeeded()
        guard isActive else { return }
        start(reason: reason, startsInitialLoad: startsInitialLoad)
        canJoinInitialLoad = task != nil
    }

    func reload(reason: ViewDataReloadReason?, trigger: EnsembleReloadTrigger = .reload) async {
        guard !Task.isCancelled, isActive else { return }
        if case .disabled = reloadBehavior { return }
        activate(reason: .reload, startsInitialLoad: reason == nil)
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
            guard let refresh = prepare(reason ?? .automatic) else { return }
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
            if accepts(currentRevision), let token {
                destination.finishLoading(token)
                if loadingToken == token { loadingToken = nil }
            }
        case .loadable:
            await reloadLoadable(reason: reason, trigger: trigger)
        case .disabled:
            break
        }
    }

    private func reloadLoadable(reason: ViewDataReloadReason?, trigger: EnsembleReloadTrigger) async {
        guard !Task.isCancelled else { return }
        ensembleLog.ensembleDebug(.reloadRequested(
            source: logSource, generation: revision, mode: .loadable, trigger: trigger
        ))
        if needsRebind { start(reason: .identityChanged, startsInitialLoad: reason == nil) }
        let request: Task<Void, Never>?
        if reason == nil, let initialLoad, !initialLoad.isCancelled {
            ensembleLog.ensembleDebug(.reloadJoinedInitial(source: logSource, generation: revision))
            request = initialLoad
        } else {
            if task == nil || connectionValidity?.isValid == false {
                reconnect(startsLoading: false, reason: .completedSource)
            }
            request = startLoad(.reload(reason ?? .automatic))
        }
        guard let request else { return }
        await withTaskCancellationHandler {
            await request.value
        } onCancel: {
            request.cancel()
        }
    }

    private func startLoad(_ request: ViewDataLoadRequest) -> Task<Void, Never>? {
        let currentRevision = revision
        guard task != nil, accepts(currentRevision), let source = loadableSource, let destination else { return nil }
        let token = destination.beginLoading()
        loadingToken = token
        let load = Task { [weak self] in
            defer {
                if let self, self.accepts(currentRevision) {
                    self.loadTasks[token] = nil
                    if request == .initial { self.initialLoad = nil }
                    if self.loadingToken == token { self.finishLoading() }
                }
            }
            guard !Task.isCancelled, self?.accepts(currentRevision) == true else { return }
            await source.load(request)
        }
        loadTasks[token] = load
        return load
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
        loadableSource = nil
    }

    private func start(reason: EnsembleConnectionReason, startsInitialLoad: Bool = true) {
        switch reloadBehavior {
        case .resubscribe, .disabled:
            reconnect(startsLoading: true, reason: reason)
        case .refresh:
            reconnect(startsLoading: false, reason: reason)
        case .loadable:
            reconnect(startsLoading: false, reason: reason)
            if startsInitialLoad { initialLoad = startLoad(.initial) }
        }
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
                    await self?.reload(reason: .userInitiated, trigger: .retry)
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
        for load in loadTasks.values { load.cancel() }
        loadTasks.removeAll()
        initialLoad = nil
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
        if changed {
            loadableSource = nil
            if isConnected {
                needsRebind = true
                connectionValidity?.invalidate()
                cancelRetry()
            }
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

// Capture the iterator at subscription time, before a load can publish an update. Iteration
// continues through the same for-await path as a regular sequence.
private nonisolated struct SourceSubscription<AsyncIterator: AsyncIteratorProtocol>: AsyncSequence {
    let iterator: AsyncIterator

    func makeAsyncIterator() -> AsyncIterator { iterator }
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
