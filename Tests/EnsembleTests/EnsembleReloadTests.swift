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

@Suite("Managed source reload")
struct EnsembleReloadTests {
    @Test("A batch joins the initial loads of heterogeneous cold sources")
    func coldStartup() async {
        let integers = ColdBatchSource<Int>()
        let strings = ColdBatchSource<String>()
        let numberFixture = SourceFixture<Int, _>(make: integers.values)
        let textFixture = SourceFixture<String, _>(make: strings.values)
        defer { withExtendedLifetime((numberFixture, textFixture)) {} }
        let number = numberFixture.data
        number.connect()
        let text = textFixture.data
        text.connect()
        let batch = Task { await Ensemble.reload(number, text) }
        #expect(await eventually { integers.producers.count == 1 && strings.producers.count == 1 })
        integers.producers[0].yield(.success(42))
        integers.producers[0].finish()
        strings.producers[0].yield(.success("Ready"))
        strings.producers[0].finish()
        await batch.value
        #expect(integers.producers.count == 1 && strings.producers.count == 1)
        #expect(number.latestValue == .available(42))
        #expect(text.latestValue == .available("Ready"))
    }

    @Test("A failure does not cancel siblings and completion waits for every cold request")
    func partialFailure() async {
        let failure = ColdBatchSource<Int>()
        let success = ColdBatchSource<String>()
        let empty = ColdBatchSource<[Int]>()
        let failedDataFixture = SourceFixture(.available(7), make: failure.values)
        defer { withExtendedLifetime(failedDataFixture) {} }
        let failedData = failedDataFixture.data
        failedData.connect()
        let textFixture = SourceFixture<String, _>(make: success.values)
        defer { withExtendedLifetime(textFixture) {} }
        let text = textFixture.data
        text.connect()
        let listFixture = SourceFixture<[Int], _>(make: empty.values)
        defer { withExtendedLifetime(listFixture) {} }
        let list = listFixture.data
        list.connect()
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
        let numberFixture = SourceFixture(.available(7), make: first.values, refresh: first.refresh)
        defer { withExtendedLifetime(numberFixture) {} }
        let number = numberFixture.data
        number.connect()
        let textFixture = SourceFixture(.available("Cached"), make: second.values, refresh: second.refresh)
        defer { withExtendedLifetime(textFixture) {} }
        let text = textFixture.data
        text.connect()
        var returned = false
        let batch = Task { await Ensemble.reload(number, text); returned = true }
        #expect(await eventually { first.requests.count == 1 && second.requests.count == 1 })
        #expect(first.connections == 1 && second.connections == 1)
        #expect(first.requestHadSubscription && second.requestHadSubscription)
        #expect(number.phase.kind == .loading && text.phase.kind == .loading)
        #expect(!returned)
        first.requests[0].finish()
        #expect(await eventually { first.completed == 1 })
        #expect(number.binding?.isConnected == true)
        #expect(!returned)
        second.requests[0].finish()
        await batch.value
        #expect(returned)
        #expect(number.latestValue == .available(7))
        #expect(text.latestValue == .available("Cached"))
    }

    @Test("Immediate hot outcomes arrive after reload returns without a view consumer")
    func immediateHotOutcome() async {
        let (stream, producer) = AsyncStream<Result<Int, BatchFailure>>.makeStream()
        let dataFixture = SourceFixture<Int, _>(make: { stream }, refresh: { producer.yield(.success(42)) })
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        data.connect()
        await Ensemble.reload(data)
        #expect(await eventually { data.latestValue == .available(42) })
    }

    @Test("Completed requests keep receiving updates and retries remain local")
    func existingObservationAndRetry() async throws {
        let source = ColdBatchSource<Int>()
        let dataFixture = SourceFixture(.available(7), make: source.values)
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        data.connect()
        #expect(await eventually { source.producers.count == 1 })
        source.producers[0].yield(.success(8))
        #expect(await eventually { data.latestValue == .available(8) })
        let batch = Task { await Ensemble.reload(data) }
        #expect(await eventually { source.producers.count == 2 })
        source.producers[1].yield(.failure(.offline))
        source.producers[1].finish()
        await batch.value
        #expect(data.binding?.isConnected == true)
        #expect(data.latestValue == .available(8))
        let retry = try #require(data.retryAction)
        retry()
        #expect(await eventually { source.producers.count == 3 })
        source.producers[2].yield(.success(42))
        source.producers[2].finish()
        #expect(await eventually { data.latestValue == .available(42) })
        #expect(data.binding?.isConnected == true)
    }

    @Test("Cancellation reaches requests without ending model-owned hot updates")
    func cancellation() async {
        let hot = HotBatchSource<Int>()
        let cold = ColdBatchSource<String>()
        let numberFixture = SourceFixture(.available(7), make: hot.values, refresh: hot.refresh)
        defer { withExtendedLifetime(numberFixture) {} }
        let number = numberFixture.data
        number.connect()
        let textFixture = SourceFixture(.available("Cached"), make: cold.values)
        defer { withExtendedLifetime(textFixture) {} }
        let text = textFixture.data
        text.connect()
        #expect(await eventually { hot.connections == 1 })
        let batch = Task { await Ensemble.reload(number, text) }
        #expect(await eventually { hot.requests.count == 1 && cold.producers.count == 1 })
        batch.cancel()
        await batch.value
        #expect(hot.cancelled == 1)
        #expect(number.latestValue == .available(7))
        #expect(text.latestValue == .available("Cached"))
        #expect(number.phase.kind == .success && text.phase.kind == .success)
        #expect(number.binding?.isConnected == true)
        #expect(text.binding?.isConnected == true)
        if case .terminated = cold.producers[0].yield(.success("Late")) {} else {
            Issue.record("The cancelled cold request must stop")
        }
        hot.emit(.success(42))
        #expect(await eventually { number.latestValue == .available(42) })
    }

    @Test("Overlapping hot requests share the model-owned connection", arguments: ReloadCall.allCases)
    func hotOverlap(_ firstCall: ReloadCall) async {
        let source = HotBatchSource<Int>()
        let dataFixture = SourceFixture(.available(7), make: source.values, refresh: source.refresh)
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        data.connect()
        let first = Task { await firstCall.run(data) }
        #expect(await eventually { source.requests.count == 1 })
        var secondReturned = false
        let second = Task { await firstCall.other.run(data); secondReturned = true }
        #expect(await eventually { source.requests.count == 2 })
        source.requests[0].finish()
        await first.value
        #expect(!secondReturned)
        #expect(data.binding?.isConnected == true)
        source.emit(.success(42))
        #expect(await eventually { data.latestValue == .available(42) })
        source.requests[1].finish()
        await second.value
        #expect(source.completed == 2)
        #expect(source.cancelled == 0)
        #expect(source.connections == 1)
    }

    @Test("A later cold request supersedes the earlier request", arguments: ReloadCall.allCases)
    func coldOverlap(_ firstCall: ReloadCall) async throws {
        let source = ColdBatchSource<Int>()
        let dataFixture = SourceFixture(.available(7), make: source.values)
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        data.connect()
        try #require(await eventually { source.producers.count == 1 })
        source.producers[0].yield(.success(7))
        source.producers[0].finish()
        try #require(await eventually { data.latestValue == .available(7) && data.binding?.isRunning == false })
        let first = Task { await firstCall.run(data) }
        defer { first.cancel() }
        try #require(await eventually { source.producers.count == 2 })
        var secondReturned = false
        let second = Task { await firstCall.other.run(data); secondReturned = true }
        defer { second.cancel() }
        try #require(await eventually { source.producers.count == 3 })
        await first.value
        #expect(!secondReturned)
        #expect(data.binding?.isConnected == true)
        source.producers[2].yield(.success(42))
        source.producers[2].finish()
        await second.value
        #expect(data.latestValue == .available(42))
        #expect(data.phase.kind == .success)
    }

    @Test("Immediate cold reload awaits the initial result", arguments: ReloadCall.allCases)
    func coldStartupParity(_ call: ReloadCall) async {
        var connections = 0
        let dataFixture = SourceFixture<Int, _>(make: {
            connections += 1
            return AsyncStream<Result<Int, BatchFailure>> { producer in
                producer.yield(.success(42))
                producer.finish()
            }
        })
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        await call.run(data)
        #expect(connections == 1)
        #expect(data.latestValue == .available(42))
        #expect(data.phase.kind == .success)
        #expect(data.binding?.isConnected == true)
    }

    @Test("Immediate hot reload connects before refresh and continues after it ends", arguments: ReloadCall.allCases)
    func hotStartupParity(_ call: ReloadCall) async {
        let source = HotBatchSource<Int>()
        let fixture = SourceFixture(.available(7), make: source.values, refresh: source.refresh)
        defer { withExtendedLifetime(fixture) {} }
        let data = fixture.data
        let request = Task { await call.run(data) }
        #expect(await eventually { source.requests.count == 1 })
        #expect(source.connections == 1)
        #expect(source.requestHadSubscription)
        #expect(data.phase.kind == .loading)
        source.emit(.success(42))
        #expect(await eventually { data.latestValue == .available(42) })
        source.requests[0].finish()
        await request.value
        #expect(source.completed == 1)
        #expect(data.phase.kind == .success)
        #expect(data.binding?.isConnected == true)
    }

    @Test("A refresh inherits the caller's task locals", arguments: ReloadCall.allCases)
    func taskLocalParity(_ call: ReloadCall) async {
        var received: String?
        let fixture = SourceFixture<Int, _>(make: {
            AsyncStream<Result<Int, BatchFailure>> { _ in }
        }, refresh: { received = ReloadContext.requestID })
        defer { withExtendedLifetime(fixture) {} }
        await ReloadContext.$requestID.withValue("request-42") {
            await call.run(fixture.data)
        }
        #expect(received == "request-42")
    }

    @Test("Unmanaged state stays passive and reload-disabled sources still activate", arguments: ReloadCall.allCases)
    func inertParity(_ call: ReloadCall) async {
        var connections = 0
        let fixture = SourceFixture<Int, _>(make: {
            connections += 1
            return AsyncStream<Result<Int, BatchFailure>> { _ in }
        }, allowsReload: false, receive: { _, result, sink in sink.receive(result) })
        defer { withExtendedLifetime(fixture) {} }
        let data = fixture.data
        data.connect()
        let passive = ViewData(.available(7))
        #expect(await eventually { connections == 1 })
        await call.run(data)
        await call.run(passive)
        #expect(connections == 1)
        #expect(data.retryAction == nil)
        #expect(passive.latestValue == .available(7))
    }

    @Test("Repeated instances reload once and inert inputs remain inert")
    func duplicateAndInertInputs() async {
        var refreshes = 0
        var connections = 0
        var disabledConnections = 0
        let dataFixture = SourceFixture<Int, _>(make: {
            connections += 1
            return AsyncStream<Result<Int, BatchFailure>> { _ in }
        }, refresh: { refreshes += 1 })
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        data.connect()
        let passive = ViewData(.available("Passive"))
        let disabledFixture = SourceFixture<Int, _>(make: {
            disabledConnections += 1
            return AsyncStream<Result<Int, BatchFailure>> { _ in }
        }, allowsReload: false, receive: { _, result, sink in sink.receive(result) })
        defer { withExtendedLifetime(disabledFixture) {} }
        let disabled = disabledFixture.data
        disabled.connect()
        await Ensemble.reload(data, passive, data, disabled)
        #expect(refreshes == 1 && connections == 1)
        #expect(disabledConnections == 1)
        #expect(passive.latestValue == .available("Passive"))
        await Ensemble.reload()
    }

    @Test("Releasing the owner after reload releases its data and binding")
    func releasesOperationCaptures() async {
        weak var weakData: ViewData<Int>?
        weak var weakBinding: ViewDataBinding<Int>?
        do {
            let dataFixture = SourceFixture<Int, _>(make: {
                AsyncStream<Result<Int, BatchFailure>> { producer in
                    producer.yield(.success(42))
                    producer.finish()
                }
            })
            defer { withExtendedLifetime(dataFixture) {} }
            let data = dataFixture.data
            data.connect()
            weakData = data
            weakBinding = data.binding
            await Ensemble.reload(data)
            #expect(data.latestValue == .available(42))
        }
        #expect(weakData == nil)
        #expect(weakBinding == nil)
    }

    @Test("Cancelled reload and passive reads start no source work", arguments: ReloadCall.allCases)
    func alreadyCancelled(_ call: ReloadCall) async {
        var connections = 0
        var refreshes = 0
        let dataFixture = SourceFixture<Int, _>(make: {
            connections += 1
            return AsyncStream<Result<Int, BatchFailure>> { _ in }
        }, refresh: { refreshes += 1 })
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        let batch = Task { await call.run(data) }
        batch.cancel()
        await batch.value
        #expect(refreshes == 0)
        #expect(connections == 0)
    }

    private func eventually(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
}

enum ReloadCall: CaseIterable, Sendable {
    case direct, ensemble

    var other: Self { self == .direct ? .ensemble : .direct }

    func run<Value>(_ data: ViewData<Value>) async {
        switch self {
        case .direct: await data.reload()
        case .ensemble: await Ensemble.reload(data)
        }
    }
}

private enum ReloadContext {
    @TaskLocal static var requestID: String?
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
