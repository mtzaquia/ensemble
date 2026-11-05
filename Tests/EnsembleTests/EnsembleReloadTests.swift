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

import Testing
@testable import Ensemble

@Suite("Concurrent batch reload")
struct EnsembleReloadTests {
    @Test("A startup batch connects heterogeneous cold sources exactly once")
    func coldStartup() async {
        var integerConnections = 0
        var textConnections = 0
        let number = ViewData<Int>(make: {
            integerConnections += 1
            return AsyncStream<Result<Int, BatchFailure>> { continuation in
                continuation.yield(.success(42))
                continuation.finish()
            }
        })
        let text = ViewData<String>(make: {
            textConnections += 1
            return AsyncStream<Result<String, BatchFailure>> { continuation in
                continuation.yield(.success("Ready"))
                continuation.finish()
            }
        })
        #expect(integerConnections == 0 && textConnections == 0)
        await Ensemble.reload(number, text)
        #expect(integerConnections == 1 && textConnections == 1)
        #expect(number.latestValue == .available(42))
        #expect(text.latestValue == .available("Ready"))
        #expect(number.binding?.observerCount == 0)
        #expect(text.binding?.observerCount == 0)
    }

    @Test("A failure does not cancel siblings and completion waits for every cold request")
    func partialFailure() async {
        let failure = ColdBatchSource<Int>()
        let success = ColdBatchSource<String>()
        let empty = ColdBatchSource<[Int]>()
        let failedData = ViewData(.available(7), make: failure.values)
        let text = ViewData<String>(make: success.values)
        let list = ViewData<[Int]>(make: empty.values)
        var returned = false
        let batch = Task {
            await Ensemble.reload(failedData, text, list)
            returned = true
        }
        #expect(await eventually { failure.producers.count == 1 && success.producers.count == 1 && empty.producers.count == 1 })
        failure.producers[0].yield(.failure(.offline))
        failure.producers[0].finish()
        #expect(await eventually { failedData.phase.kind == .failure })
        #expect(failedData.latestValue == .available(7))
        #expect(!returned)
        success.producers[0].yield(.success("Fresh"))
        success.producers[0].finish()
        #expect(await eventually { text.latestValue == .available("Fresh") })
        #expect(!returned)
        empty.producers[0].yield(.success([]))
        empty.producers[0].finish()
        await batch.value
        #expect(returned)
        #expect(list.latestValue == .available([]))
        #expect(failedData.phase.kind == .failure)
        #expect(text.phase.kind == .success)
        #expect(list.phase.kind == .success)
    }

    @Test("Hot requests start together after subscription and await their actions")
    func concurrentHotRequests() async {
        let first = HotBatchSource<Int>()
        let second = HotBatchSource<String>()
        let number = ViewData(.available(7), make: first.values, refresh: first.refresh)
        let text = ViewData(.available("Cached"), make: second.values, refresh: second.refresh)
        var returned = false
        let batch = Task { await Ensemble.reload(number, text); returned = true }
        #expect(await eventually { first.requests.count == 1 && second.requests.count == 1 })
        #expect(first.connections == 1 && second.connections == 1)
        #expect(first.requestHadSubscription && second.requestHadSubscription)
        #expect(number.phase.kind == .loading && text.phase.kind == .loading)
        #expect(!returned)
        first.requests[0].finish()
        #expect(await eventually { first.completed == 1 })
        #expect(!returned)
        second.requests[0].finish()
        await batch.value
        #expect(returned)
        #expect(number.latestValue == .available(7))
        #expect(text.latestValue == .available("Cached"))
        #expect(number.binding?.observerCount == 0 && text.binding?.observerCount == 0)
    }

    @Test("Immediate hot outcomes continue reaching an existing consumer after batch completion")
    func immediateHotOutcome() async {
        let (stream, producer) = AsyncStream<Result<Int, BatchFailure>>.makeStream()
        let data = ViewData<Int>(make: { stream }, refresh: { producer.yield(.success(42)) })
        let consumer = Task { await data.observe() }
        defer { consumer.cancel() }
        #expect(await eventually { data.binding?.observerCount == 1 })
        await Ensemble.reload(data)
        #expect(await eventually { data.latestValue == .available(42) })
        #expect(data.binding?.observerCount == 1)
    }

    @Test("Batch leases preserve existing consumers and retry remains local to a failed source")
    func existingObservationAndRetry() async throws {
        let source = ColdBatchSource<Int>()
        let data = ViewData(.available(7), make: source.values)
        let observation = Task { await data.observe() }
        defer { observation.cancel() }
        #expect(await eventually { source.producers.count == 1 })
        let batch = Task { await Ensemble.reload(data) }
        #expect(await eventually { source.producers.count == 2 })
        source.producers[1].yield(.failure(.offline))
        source.producers[1].finish()
        await batch.value
        #expect(data.binding?.observerCount == 1)
        #expect(data.binding?.isConnected == true)
        #expect(data.latestValue == .available(7))
        let retry = try #require(data.retryAction)
        retry()
        #expect(await eventually { source.producers.count == 3 })
        source.producers[2].yield(.success(42))
        source.producers[2].finish()
        #expect(await eventually { data.latestValue == .available(42) })
        observation.cancel()
        await observation.value
        #expect(data.binding?.isConnected == false)
    }

    @Test("Cancellation reaches every request and releases only the batch leases")
    func cancellation() async {
        let hot = HotBatchSource<Int>()
        let cold = ColdBatchSource<String>()
        let number = ViewData(.available(7), make: hot.values, refresh: hot.refresh)
        let text = ViewData(.available("Cached"), make: cold.values)
        let consumer = Task { await number.observe() }
        defer { consumer.cancel() }
        #expect(await eventually { hot.connections == 1 })
        let batch = Task { await Ensemble.reload(number, text) }
        #expect(await eventually { hot.requests.count == 1 && cold.producers.count == 1 })
        batch.cancel()
        await batch.value
        #expect(hot.cancelled == 1)
        #expect(number.latestValue == .available(7))
        #expect(text.latestValue == .available("Cached"))
        #expect(number.phase.kind == .success && text.phase.kind == .success)
        #expect(number.binding?.observerCount == 1)
        #expect(text.binding?.observerCount == 0)
        #expect(number.binding?.isConnected == true)
        #expect(text.binding?.isConnected == false)
        if case .terminated = cold.producers[0].yield(.success("Late")) {} else {
            Issue.record("The cancelled cold request must stop")
        }
        hot.emit(.success(42))
        #expect(await eventually { number.latestValue == .available(42) })
    }

    @Test("A hot direct request stays observed after an overlapping batch finishes")
    func hotOverlap() async {
        let source = HotBatchSource<Int>()
        let data = ViewData(.available(7), make: source.values, refresh: source.refresh)
        let batch = Task { await Ensemble.reload(data) }
        #expect(await eventually { source.requests.count == 1 })
        var directReturned = false
        let direct = Task { await data.reload(); directReturned = true }
        #expect(await eventually { source.requests.count == 2 })
        source.requests[0].finish()
        await batch.value
        #expect(!directReturned)
        #expect(data.binding?.isConnected == true)
        #expect(data.binding?.observerCount == 1)
        source.emit(.success(42))
        #expect(await eventually { data.latestValue == .available(42) })
        source.requests[1].finish()
        await direct.value
        #expect(source.completed == 2)
        #expect(source.cancelled == 0)
        #expect(source.connections == 1)
        #expect(data.binding?.observerCount == 0)
    }

    @Test("A later cold direct request supersedes the batch request and retains its own lease")
    func coldOverlap() async {
        let source = ColdBatchSource<Int>()
        let data = ViewData(.available(7), make: source.values)
        let batch = Task { await Ensemble.reload(data) }
        #expect(await eventually { source.producers.count == 1 })
        var directReturned = false
        let direct = Task { await data.reload(); directReturned = true }
        #expect(await eventually { source.producers.count == 2 })
        await batch.value
        #expect(!directReturned)
        #expect(data.binding?.isConnected == true)
        #expect(data.binding?.observerCount == 1)
        source.producers[1].yield(.success(42))
        source.producers[1].finish()
        await direct.value
        #expect(data.latestValue == .available(42))
        #expect(data.phase.kind == .success)
        #expect(data.binding?.observerCount == 0)
    }

    @Test("A direct call before activation stays inert; the batch establishes startup observation")
    func directBeforeBatch() async {
        var connections = 0
        let data = ViewData<Int>(make: {
            connections += 1
            return AsyncStream<Result<Int, BatchFailure>> { producer in
                producer.yield(.success(42))
                producer.finish()
            }
        })
        await data.reload()
        #expect(connections == 0)
        await Ensemble.reload(data)
        #expect(connections == 1)
        #expect(data.latestValue == .available(42))
    }

    @Test("Repeated instances reload once and inert inputs remain inert")
    func duplicateAndInertInputs() async {
        var refreshes = 0
        var connections = 0
        var disabledConnections = 0
        let data = ViewData<Int>(make: {
            connections += 1
            return AsyncStream<Result<Int, BatchFailure>> { _ in }
        }, refresh: { refreshes += 1 })
        let passive = ViewData(.available("Passive"))
        let disabled = ViewData<Int>(make: {
            disabledConnections += 1
            return AsyncStream<Result<Int, BatchFailure>> { _ in }
        }, reload: .disabled, receive: { result, sink in sink.receive(result) })
        await Ensemble.reload(data, passive, data, disabled)
        #expect(refreshes == 1 && connections == 1)
        #expect(disabledConnections == 0)
        #expect(passive.latestValue == .available("Passive"))
        await Ensemble.reload()
    }

    @Test("Finishing a batch releases its data and binding captures")
    func releasesOperationCaptures() async {
        weak var weakData: ViewData<Int>?
        weak var weakBinding: ViewDataBinding<Int>?
        do {
            let data = ViewData<Int>(make: {
                AsyncStream<Result<Int, BatchFailure>> { producer in
                    producer.yield(.success(42))
                    producer.finish()
                }
            })
            weakData = data
            weakBinding = data.binding
            await Ensemble.reload(data)
            #expect(data.latestValue == .available(42))
        }
        #expect(weakData == nil)
        #expect(weakBinding == nil)
    }

    @Test("A batch cancelled before entry starts no work")
    func alreadyCancelled() async {
        var connections = 0
        var refreshes = 0
        let data = ViewData<Int>(make: {
            connections += 1
            return AsyncStream<Result<Int, BatchFailure>> { _ in }
        }, refresh: { refreshes += 1 })
        let batch = Task { await Ensemble.reload(data) }
        batch.cancel()
        await batch.value
        #expect(connections == 0 && refreshes == 0)
        #expect(data.binding?.observerCount == 0)
    }

    private func eventually(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
}

private enum BatchFailure: Error { case offline }

private final class ColdBatchSource<Value: Sendable> {
    var producers: [AsyncStream<Result<Value, BatchFailure>>.Continuation] = []
    func values() -> AsyncStream<Result<Value, BatchFailure>> {
        let (stream, producer) = AsyncStream<Result<Value, BatchFailure>>.makeStream()
        producers.append(producer)
        return stream
    }
}

private final class HotBatchSource<Value: Sendable> {
    var connections = 0
    var requestHadSubscription = false
    var requests: [AsyncStream<Void>.Continuation] = []
    var producers: [AsyncStream<Result<Value, BatchFailure>>.Continuation] = []
    var completed = 0
    var cancelled = 0

    func values() -> AsyncStream<Result<Value, BatchFailure>> {
        connections += 1
        let (stream, producer) = AsyncStream<Result<Value, BatchFailure>>.makeStream()
        producers.append(producer)
        return stream
    }

    func refresh() async {
        requestHadSubscription = !producers.isEmpty
        let (gate, finish) = AsyncStream<Void>.makeStream()
        requests.append(finish)
        for await _ in gate {}
        if Task.isCancelled { cancelled += 1 } else { completed += 1 }
    }

    func emit(_ result: Result<Value, BatchFailure>) {
        for producer in producers { producer.yield(result) }
    }
}
