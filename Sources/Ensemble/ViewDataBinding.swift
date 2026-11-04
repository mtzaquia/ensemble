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

// One binding belongs to one ViewData. The configuration survives observation, while each
// connection has its own revision so obsolete producers, sinks, and retries cannot update state.
final class ViewDataBinding<Value> {
    private typealias Connect = @MainActor (ViewDataBinding, UInt) -> Bool

    private var connect: Connect
    private var reloadBehavior: ViewDataReloadBehavior
    private weak var destination: ViewData<Value>?
    private var observers: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var task: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryRevision: UInt = 0
    private var revision: UInt = 0
    private(set) var isConnected = false
    private var loadingToken: UInt?

    var observerCount: Int { observers.count }
    var isRunning: Bool { task != nil }

    init<Source: AsyncSequence>(
        make: @escaping @MainActor () -> Source?,
        reload: ViewDataReloadBehavior,
        receive: @escaping @MainActor (Source.Element, ViewDataSink<Value>) -> Void
    ) {
        self.reloadBehavior = reload
        self.connect = Self.connection(make: make, receive: receive)
    }

    func observe(_ destination: ViewData<Value>) async {
        guard !Task.isCancelled else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                self.destination = destination
                observers[id] = continuation
                if observers.count == 1 { start() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(id) }
        }
    }

    func reload() async {
        guard !Task.isCancelled, isConnected, !observers.isEmpty, let destination else { return }
        let identifier = ObjectIdentifier(destination)
        switch reloadBehavior {
        case .resubscribe:
            ensembleLog.ensembleDebug(.reloadRequested(destination: identifier, mode: .resubscribe))
            reconnect(startsLoading: true)
            let connection = task
            await withTaskCancellationHandler {
                await connection?.value
            } onCancel: {
                connection?.cancel()
            }
        case .refresh(let refresh):
            ensembleLog.ensembleDebug(.reloadRequested(destination: identifier, mode: .refresh))
            if task == nil {
                reconnect(startsLoading: true)
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

    func replace<Source: AsyncSequence>(
        make: @escaping @MainActor () -> Source,
        reload: ViewDataReloadBehavior,
        receive: @escaping @MainActor (Source.Element, ViewDataSink<Value>) -> Void
    ) {
        cancelRetry()
        disconnect()
        connect = Self.connection(make: make, receive: receive)
        reloadBehavior = reload
        if !observers.isEmpty { start() }
    }

    private func release(_ id: UUID) {
        guard let continuation = observers.removeValue(forKey: id) else { return }
        if observers.isEmpty {
            cancelRetry()
            disconnect()
        }
        continuation.resume()
    }

    private func start() {
        // Observing a hot source only subscribes. Its refresh action is invoked explicitly by
        // reload/retry. Cold sequences start their work when connected.
        let startsLoading: Bool
        if case .refresh = reloadBehavior { startsLoading = false } else { startsLoading = true }
        reconnect(startsLoading: startsLoading)
    }

    private func reconnect(startsLoading: Bool) {
        disconnect()
        guard let destination else { return }
        isConnected = true
        let currentRevision = revision
        ensembleLog.ensembleDebug(.bindingStarted(
            destination: ObjectIdentifier(destination), reload: reloadBehavior.logMode
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
                    await self?.reload()
                    if let self, self.retryRevision == request { self.retryTask = nil }
                }
            })
        }
        if startsLoading { beginLoading() }
        if !connect(self, currentRevision), accepts(currentRevision) { disconnect() }
    }

    private func disconnect() {
        revision &+= 1
        task?.cancel()
        task = nil
        guard isConnected else { return }
        isConnected = false
        destination?.removeRetryAction()
        finishLoading()
        if let destination {
            ensembleLog.ensembleDebug(.bindingCancelled(destination: ObjectIdentifier(destination)))
        }
    }

    private func accepts(_ revision: UInt) -> Bool {
        isConnected && self.revision == revision
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
            let identifier = ObjectIdentifier(destination)
            switch action {
            case .value(let value):
                ensembleLog.ensembleDebug(.bindingReceivedValue(destination: identifier))
                destination.set(value)
            case .failure(let error):
                ensembleLog.ensembleDebug(.bindingReceivedFailure(destination: identifier, error: error))
                destination.fail(error)
            case .reset:
                ensembleLog.ensembleDebug(.bindingReceivedReset(destination: identifier))
                destination.reset()
            }
        }
        task = Task { [weak self] in
            defer {
                if let self, self.accepts(revision) {
                    self.finishLoading()
                    self.task = nil
                    if let destination = self.destination {
                        ensembleLog.ensembleDebug(.bindingCompleted(destination: ObjectIdentifier(destination)))
                    }
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
        cancelRetry()
        disconnect()
    }
}
