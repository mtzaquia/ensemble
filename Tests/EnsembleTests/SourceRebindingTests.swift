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
import Testing
@testable import Ensemble

@Suite("Observed source inputs")
struct SourceRebindingTests {
    @Test("Changing a factory input rebinds once and rejects old sinks immediately")
    func activeInputs() async throws {
        let model = RebindingModel()
        defer { withExtendedLifetime(model) {} }
        let data = model.data
        #expect(await eventually { model.source.requests.count == 1 })
        model.source.requests[0].producer.yield(.success(41))
        #expect(await eventually { data.latestValue == .available(41) })
        let oldSink = try #require(model.lastSink)
        let oldRetry = try #require(data.retryAction)
        model.query = 1
        model.query = 2
        oldSink.reset()
        oldRetry()
        #expect(data.latestValue == .available(41))
        try #require(await eventually { model.source.requests.count == 2 })
        #expect(model.source.requests.map(\.query) == [0, 2])
        #expect(model.source.refreshes == 0)
        #expect(model.data === data)
        #expect(data.latestValue == .available(41))
        model.source.requests[0].producer.yield(.success(999))
        model.source.requests[1].producer.yield(.success(42))
        #expect(await eventually { data.latestValue == .available(42) })
        #expect(model.receivedValues == [41, 42])
    }

    @Test("Unread declarations stay lazy and active declarations follow current inputs")
    func unreadInputs() async {
        let model = RebindingModel()
        defer { withExtendedLifetime(model) {} }
        model.query = 3
        for _ in 0..<10 { await Task.yield() }
        #expect(model.source.requests.isEmpty)
        let data = model.data
        #expect(await eventually { model.source.requests.count == 1 })
        model.query = 4
        #expect(await eventually { model.source.requests.map(\.query) == [3, 4] })
        #expect(model.data === data)
    }

    @Test("Completed streams still rebind while the model lives")
    func completedSource() async {
        let model = RebindingModel()
        defer { withExtendedLifetime(model) {} }
        let data = model.data
        #expect(await eventually { model.source.requests.count == 1 })
        model.source.requests[0].producer.yield(.success(41))
        model.source.requests[0].producer.finish()
        #expect(await eventually { data.binding?.isRunning == false })
        model.query = 1
        #expect(await eventually { model.source.requests.count == 2 })
        #expect(data.latestValue == .available(41))
    }

    @Test("Receive and refresh reads do not become factory dependencies")
    func callbackReads() async {
        let model = RebindingModel()
        defer { withExtendedLifetime(model) {} }
        _ = model.data
        #expect(await eventually { model.source.requests.count == 1 })
        await model.data.reload()
        model.source.requests[0].producer.yield(.success(41))
        #expect(await eventually { model.receivedValues == [41] })
        model.callbackInput = 1
        model.seedInput = 99
        for _ in 0..<10 { await Task.yield() }
        #expect(model.source.requests.count == 1)
        #expect(model.data.latestValue == .available(41))
    }

    @Test("Conditional dependencies are renewed on each connection")
    func conditionalInputs() async throws {
        let model = RebindingModel()
        defer { withExtendedLifetime(model) {} }
        _ = model.data
        try #require(await eventually { model.source.requests.count == 1 })
        model.alternateQuery = 20
        for _ in 0..<10 { await Task.yield() }
        #expect(model.source.requests.map(\.query) == [0])
        model.usesAlternate = true
        try #require(await eventually { model.source.requests.count == 2 })
        model.query = 30
        for _ in 0..<10 { await Task.yield() }
        #expect(model.source.requests.map(\.query) == [0, 20])
        model.alternateQuery = 21
        try #require(await eventually { model.source.requests.count == 3 })
        #expect(model.source.requests.map(\.query) == [0, 20, 21])
    }

    @Test("An immediate reload observes the new inputs before requesting a hot refresh")
    func reloadAfterInputChange() async throws {
        let model = RebindingModel()
        defer { withExtendedLifetime(model) {} }
        _ = model.data
        try #require(await eventually { model.source.requests.count == 1 })
        model.query = 4
        await model.data.reload()
        #expect(model.source.requests.map(\.query) == [0, 4])
        #expect(model.source.refreshedQueries == [4])
        #expect(model.source.refreshHadSubscription)
        for _ in 0..<10 { await Task.yield() }
        #expect(model.source.requests.count == 2)
    }

    @Test("Owner release disarms input changes and pending callbacks")
    func ownerReleased() async throws {
        var model: RebindingModel? = RebindingModel()
        weak let weakModel = model
        let source = model!.source
        let data = model!.data
        try #require(await eventually { source.requests.count == 1 })
        model!.query = 1
        model = nil
        #expect(weakModel == nil)
        let connections = source.requests.count
        for _ in 0..<10 { await Task.yield() }
        #expect(source.requests.count == connections)
        #expect(data.binding?.isConnected == false)
        #expect(data.retryAction == nil)
    }

    @Test("Reload-disabled sources still activate and rebind their inputs")
    func disabledReload() async throws {
        let model = RebindingModel()
        defer { withExtendedLifetime(model) {} }
        let data = model.passive
        try #require(await eventually { model.source.requests.count == 1 })
        #expect(data.retryAction == nil)
        await data.reload()
        model.query = 1
        try #require(await eventually { model.source.requests.count == 2 })
        #expect(data.retryAction == nil)
        #expect(model.source.refreshes == 0)
        model.source.requests[1].producer.yield(.success(42))
        #expect(await eventually { data.latestValue == .available(42) })
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

@Observable
private final class RebindingModel {
    var query = 0
    var seedInput = 7
    var alternateQuery = 10
    var usesAlternate = false
    var callbackInput = 0
    var source = RebindingSource()
    @ObservationIgnored var lastSink: ViewDataSink<Int>?
    @ObservationIgnored var receivedValues: [Int] = []

    var selectedQuery: Int { usesAlternate ? alternateQuery : query }

    @ViewDataSource(
        initial: { (model: Self) in .available(model.seedInput) },
        make: { (model: Self) in model.source.values(for: model.selectedQuery) },
        refresh: { model in
            _ = model.callbackInput
            model.source.refresh(for: model.selectedQuery)
        },
        receive: { model, result, sink in
            _ = model.callbackInput
            model.lastSink = sink
            sink.receive(result)
            if case .success(let value) = result { model.receivedValues.append(value) }
        }
    )
    @ObservationIgnored
    var data: ViewData<Int>

    @ViewDataSource(
        make: { (model: Self) in model.source.values(for: model.selectedQuery) },
        allowsReload: false
    )
    @ObservationIgnored
    var passive: ViewData<Int>
}

private final class RebindingSource {
    struct Request {
        let query: Int
        let producer: AsyncStream<Result<Int, Never>>.Continuation
    }

    var requests: [Request] = []
    var refreshes = 0
    var refreshedQueries: [Int] = []
    var refreshHadSubscription = true

    func refresh(for query: Int) {
        refreshes += 1
        refreshedQueries.append(query)
        refreshHadSubscription = refreshHadSubscription && requests.last?.query == query
    }

    func values(for query: Int) -> AsyncStream<Result<Int, Never>> {
        let (stream, producer) = AsyncStream<Result<Int, Never>>.makeStream()
        requests.append(Request(query: query, producer: producer))
        return stream
    }
}
