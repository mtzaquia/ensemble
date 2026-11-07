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

@Suite("Adapted sources and async reload")
struct ViewDataReceiveTests {
    @Test("A macro adapter preserves successful, failed, and reset outcomes")
    func macroUpdates() async {
        let source = AdaptedSource()
        let model = AdaptedModel(source: source)
        defer { withExtendedLifetime(model) {} }
        #expect(model.data.latestValue == .available(7))
        #expect(source.connections == 0)
        model.data.connect()
        #expect(await eventually { source.connections == 1 })
        #expect(source.requests.isEmpty)
        source.emit(.result(.failure(.offline)))
        #expect(await eventually { model.data.phase.kind == .failure })
        #expect(model.data.latestValue == .available(7))
        source.emit(.reset)
        #expect(await eventually { model.data.latestValue == .unavailable })
        source.emit(.result(.success(42)))
        #expect(await eventually { model.data.latestValue == .available(42) })
    }

    @Test("Macro adapters skip updates after the owning model is released")
    func ownerInitializer() async {
        let source = AdaptedSource()
        var model: AdaptedModel? = AdaptedModel(source: source)
        weak var weakModel: AdaptedModel?
        weakModel = model
        let data = model!.data
        data.connect()
        #expect(await eventually { source.connections == 1 })
        model = nil
        #expect(weakModel == nil)
        source.emit(.reset)
        source.emit(.result(.success(42)))
        source.continuations[0].finish()
        #expect(await eventually { data.binding?.isRunning == false })
        #expect(data.latestValue == .available(7))
    }

    @Test("Adapters become obsolete when factory inputs change")
    func adapterRebinding() async throws {
        let source = AdaptedSource()
        var oldSink: ViewDataSink<Int>?
        let dataFixture = SourceFixture<Int, _>(.available(7), make: source.values, refresh: source.reload) { _, update, sink in
            oldSink = sink
            apply(update, sink)
        }
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        data.connect()
        #expect(await eventually { source.connections == 1 })
        source.emit(.result(.success(10)))
        #expect(await eventually { data.latestValue == .available(10) })
        let obsolete = try #require(oldSink)
        let replacement = AdaptedSource()
        dataFixture.factory = replacement.values
        try #require(await eventually { replacement.connections == 1 })
        obsolete.reset()
        obsolete.receive(Result<Int, AdaptedFailure>.success(999))
        #expect(data.latestValue == .available(10))
        replacement.emit(.reset)
        #expect(await eventually { data.latestValue == .unavailable })
        replacement.emit(.result(.success(20)))
        #expect(await eventually { data.latestValue == .available(20) })
    }

    @Test("Result adapters are optional and can override the default mapping")
    func resultAdapter() async {
        let (stream, producer) = AsyncStream<Result<Int, AdaptedFailure>>.makeStream()
        let dataFixture = SourceFixture<Int, _>(make: { stream }, receive: { _, result, sink in
            sink.receive(result.map { $0 * 2 })
        })
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        data.connect()
        producer.yield(.success(21))
        #expect(await eventually { data.latestValue == .available(42) })
    }

    @Test("Async macro refresh waits for producer work and publishes through receive")
    func asyncMacroRefresh() async {
        let source = AdaptedSource()
        let model = AdaptedModel(source: source)
        defer { withExtendedLifetime(model) {} }
        model.data.connect()
        #expect(await eventually { source.connections == 1 })
        var returned = false
        let reload = Task {
            await model.data.reload()
            returned = true
        }
        #expect(await eventually { source.requests.count == 1 })
        #expect(!returned)
        #expect(model.data.phase.kind == .loading)
        #expect(model.data.latestValue == .available(7))
        source.requests[0].finish()
        await reload.value
        #expect(returned)
        #expect(await eventually { model.data.latestValue == .available(1) })
    }

    @Test("Cancelling an awaited hot reload reaches the producer and settles loading")
    func cancelledHotRefresh() async {
        let source = AdaptedSource()
        let dataFixture = SourceFixture<Int, _>(.available(7), make: source.values, refresh: source.reload, receive: { _, update, sink in apply(update, sink) })
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        data.connect()
        #expect(await eventually { source.connections == 1 })
        let reload = Task { await data.reload() }
        #expect(await eventually { source.requests.count == 1 })
        reload.cancel()
        await reload.value
        #expect(source.cancelledRequests == 1)
        #expect(data.phase.kind == .success)
        #expect(data.latestValue == .available(7))
    }

    @Test("Cold reload waits for completion and cancellation stops that request")
    func coldRequestLifetime() async {
        var producers: [AsyncStream<Result<Int, AdaptedFailure>>.Continuation] = []
        let dataFixture = SourceFixture<Int, _>(make: {
            let (stream, producer) = AsyncStream<Result<Int, AdaptedFailure>>.makeStream()
            producers.append(producer)
            return stream
        })
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        data.connect()
        #expect(await eventually { producers.count == 1 })
        producers[0].yield(.success(7))
        #expect(await eventually { data.latestValue == .available(7) })
        var returned = false
        let reload = Task { await data.reload(); returned = true }
        #expect(await eventually { producers.count == 2 })
        #expect(!returned)
        producers[1].yield(.success(42))
        producers[1].finish()
        await reload.value
        #expect(returned)
        #expect(data.latestValue == .available(42))
        let cancelled = Task { await data.reload() }
        #expect(await eventually { producers.count == 3 })
        cancelled.cancel()
        await cancelled.value
        #expect(data.phase.kind == .success)
        if case .terminated = producers[2].yield(.success(99)) {} else {
            Issue.record("Cancelling cold reload must stop its replacement subscription")
        }
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

private enum AdaptedFailure: Error { case offline }
private enum AdaptedUpdate {
    case result(Result<Int, AdaptedFailure>)
    case reset
}

private func apply(_ update: AdaptedUpdate, _ sink: ViewDataSink<Int>) {
    switch update {
    case .result(let result): sink.receive(result)
    case .reset: sink.reset()
    }
}

@Observable
private final class AdaptedModel {
    let source: AdaptedSource

    @ViewDataSource(
        initial: { _ in .available(7) },
        make: { (model: Self) in model.source.values() },
        refresh: { model in await model.source.reload() },
        receive: { _, update, sink in
            switch update {
            case .result(let result): sink.receive(result)
            case .reset: sink.reset()
            }
        }
    )
    @ObservationIgnored
    var data: ViewData<Int>

    init(source: AdaptedSource) {
        self.source = source
    }
}

private final class AdaptedSource {
    var connections = 0
    var cancelledRequests = 0
    var requests: [AsyncStream<Void>.Continuation] = []
    var continuations: [AsyncStream<AdaptedUpdate>.Continuation] = []

    func values() -> AsyncStream<AdaptedUpdate> {
        connections += 1
        let (stream, producer) = AsyncStream<AdaptedUpdate>.makeStream()
        continuations.append(producer)
        return stream
    }

    func reload() async {
        let (gate, finish) = AsyncStream<Void>.makeStream()
        requests.append(finish)
        for await _ in gate {}
        guard !Task.isCancelled else { cancelledRequests += 1; return }
        emit(.result(.success(requests.count)))
    }

    func emit(_ update: AdaptedUpdate) {
        for producer in continuations { producer.yield(update) }
    }
}
