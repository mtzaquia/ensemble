import Testing
@testable import Ensemble

@MainActor
struct RestartTests {
    enum Failure: Error { case old }

    @Test func clearsAllBeforeFactoriesAndPreservesConfiguration() async {
        let context = ViewDataContext()
        let first = ViewData(1)
        let second = ViewData(2)
        let cancelled = ViewData(3)
        var factories = 0
        var refreshing = 0
        let restarting = Flag()
        var streams: [AsyncStream<Int>.Continuation] = []
        let received = Gate<Void>()
        var sinks: [ViewDataSink<Int>] = []
        for data in [first, second, cancelled] {
            context.bind({
                factories += 1
                if restarting.value {
                    for destination in [first, second, cancelled] {
                        #expect(destination.latestValue == .unavailable)
                        #expect(destination.loadingFailure == nil)
                    }
                }
                let (stream, continuation) = AsyncStream<Int>.makeStream()
                streams.append(continuation)
                return stream
            }, to: data, reload: .refresh { refreshing += 1 }) { value, sink in
                sinks.append(sink)
                sink.receive(Result<Int, Failure>.success(value))
                received.send(())
            }
        }
        streams[0].yield(10)
        await received.next()
        let obsoleteRetry = first.retryAction
        second.fail(Failure.old)
        cancelled.fail(Failure.old)
        context.cancel(cancelled)
        restarting.value = true
        context.restart()
        restarting.value = false
        #expect(factories == 5)
        #expect(first.phase.kind == .loading)
        #expect(second.phase.kind == .loading)
        #expect(cancelled.phase.kind == .empty)
        #expect(cancelled.retryAction == nil)
        sinks[0].receive(Result<Int, Failure>.success(99))
        sinks[0].receive(Result<Int, Failure>.failure(.old))
        sinks[0].reset()
        obsoleteRetry?()
        #expect(first.phase.kind == .loading)
        #expect(refreshing == 0)
        // Both replacement factories must remain usable with their custom handlers.
        for continuation in streams.suffix(2) { continuation.yield(20) }
        await received.next()
        await received.next()
        #expect(first.latestValue == .available(20))
        #expect(second.latestValue == .available(20))
        context.reload(first)
        #expect(refreshing == 1)
        #expect(factories == 5)
        #expect(first.latestValue == .available(20))
        context.restart()
        #expect(factories == 7)
        context.cancelAll()
        for continuation in streams { continuation.finish() }
    }

    @Test(arguments: [false, true])
    func ignoresLateLoadsAndCleanup(fails: Bool) async {
        let context = ViewDataContext()
        let data = ViewData(1)
        let started = Gate<Void>()
        let result = Gate<Result<Int, Failure>>()
        let task = Task {
            await context.load({
                started.send(())
                return try await result.next().get()
            }, to: data)
        }
        await started.next()
        context.bind({ AsyncStream<Result<Int, Failure>> { _ in } }, to: data)
        context.restart()
        let revision = data.presentationRevision
        task.cancel()
        result.send(fails ? .failure(.old) : .success(99))
        await task.value
        #expect(data.presentationRevision == revision)
        #expect(data.phase.kind == .loading)
        #expect(data.latestValue == .unavailable)
    }

    @Test(arguments: [false, true])
    func ignoresUncancelledLateLoads(fails: Bool) async {
        let context = ViewDataContext()
        let data = ViewData(1)
        let started = Gate<Void>()
        let result = Gate<Result<Int, Failure>>()
        var calls = 0
        let task = Task {
            await context.load({
                calls += 1
                started.send(())
                return try await result.next().get()
            }, to: data)
        }
        await started.next()
        context.restart()
        result.send(fails ? .failure(.old) : .success(99))
        await task.value
        #expect(calls == 1)
        #expect(data.phase.kind == .empty)
        #expect(data.latestValue == .unavailable)
    }

    @Test func replacedBindingsAndWeakOwnership() {
        var context: ViewDataContext? = ViewDataContext()
        weak let weakContext = context
        var data: ViewData<Int>? = ViewData(1)
        weak let weakData = data
        var oldCalls = 0
        var newCalls = 0
        context?.bind({
            oldCalls += 1
            return AsyncStream<Result<Int, Failure>> { _ in }
        }, to: data!)
        context?.bind({
            newCalls += 1
            return AsyncStream<Result<Int, Failure>> { _ in }
        }, to: data!, reload: .disabled)
        for _ in 0..<4 { context?.restart() }
        #expect(oldCalls == 1)
        #expect(newCalls == 5)
        #expect(data?.retryAction == nil)
        data = nil
        #expect(weakData == nil)
        context?.restart()
        #expect(newCalls == 5)
        context = nil
        #expect(weakContext == nil)
    }

    @Test func completedBindingsRestartAndLateEmissionsAreRejected() async {
        let context = ViewDataContext()
        let data = ViewData(1)
        var sources: [ControlledSource] = []
        let received = Gate<Void>()
        context.bind({
            let source = ControlledSource()
            sources.append(source)
            return source
        }, to: data) { value, sink in
            sink.receive(Result<Int, Failure>.success(value))
            received.send(())
        }
        await sources[0].requested.next()
        context.restart()
        await sources[1].requested.next()
        // The old iterator deliberately ignores task cancellation.
        sources[0].results.send(99)
        await sources[0].returned.next()
        #expect(data.latestValue == .unavailable)
        #expect(data.phase.kind == .loading)
        sources[1].results.send(2)
        await received.next()
        await sources[1].requested.next()
        sources[1].results.send(nil)
        await sources[1].returned.next()
        // Drain the return signal for the preceding value, then the terminal return.
        await sources[1].returned.next()
        #expect(data.latestValue == .available(2))
        context.restart()
        #expect(sources.count == 3)
        #expect(data.phase.kind == .loading)
        await sources[2].requested.next()
        sources[2].results.send(3)
        await received.next()
        #expect(data.latestValue == .available(3))
        await sources[2].requested.next()
        sources[2].results.send(nil)
        await sources[2].returned.next()
        await sources[2].returned.next()
    }

    @Test func deallocationAfterRestartSettlesLiveDestination() {
        let data = ViewData(1)
        weak var weakContext: ViewDataContext?
        do {
            let context = ViewDataContext()
            weakContext = context
            context.bind({ AsyncStream<Result<Int, Failure>> { _ in } }, to: data)
            context.restart()
            #expect(data.phase.kind == .loading)
        }
        #expect(weakContext == nil)
        #expect(data.phase.kind == .empty)
        #expect(data.retryAction == nil)
    }

    @Test func callerCancellationStillReachesOperation() async {
        let context = ViewDataContext()
        let data = ViewData(1)
        let started = Gate<Void>()
        let release = Gate<Void>()
        let task = Task {
            await context.load({
                started.send(())
                await release.next()
                #expect(Task.isCancelled)
                throw CancellationError()
            }, to: data)
        }
        await started.next()
        task.cancel()
        release.send(())
        await task.value
        #expect(data.phase.kind == .success)
        #expect(data.latestValue == .available(1))
    }
}

/// A main-actor rendezvous that also buffers signals sent before their waiter arrives.
@MainActor
private final class Gate<Value: Sendable> {
    private var values: [Value] = []
    private var waiters: [CheckedContinuation<Value, Never>] = []

    func send(_ value: Value) {
        if waiters.isEmpty { values.append(value) }
        else { waiters.removeFirst().resume(returning: value) }
    }

    func next() async -> Value {
        if !values.isEmpty { return values.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

@MainActor
private final class ControlledSource: AsyncSequence {
    typealias Element = Int
    let requested = Gate<Void>()
    let returned = Gate<Void>()
    let results = Gate<Int?>()

    struct AsyncIterator: AsyncIteratorProtocol {
        let source: ControlledSource
        mutating func next() async -> Int? {
            source.requested.send(())
            let result = await source.results.next()
            source.returned.send(())
            return result
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(source: self) }
}

@MainActor
private final class Flag { var value = false }
