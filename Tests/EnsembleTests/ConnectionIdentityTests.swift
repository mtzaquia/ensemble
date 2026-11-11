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

@Suite("Connection identity")
struct ConnectionIdentityTests {
    @Test("Producer reads and nested tracking never become connection inputs", arguments: [false, true])
    func producerReadsAreUntracked(_ keyed: Bool) async throws {
        let model = ProducerIdentityModel()
        defer { withExtendedLifetime(model) {} }
        let data = keyed ? model.keyed : model.fixed
        data.connect()
        try #require(await eventually { data.latestValue == .available(0) })
        #expect(model.producer.connections == 1)
        model.producer.publish(5)
        try #require(await eventually {
            data.latestValue == .available(5) && model.producer.nestedChanges == 1
        })
        #expect(model.producer.connections == 1)
        model.selection = 1
        if keyed {
            #expect(await eventually { model.producer.connections == 2 })
        } else {
            for _ in 0..<10 { await Task.yield() }
            #expect(model.producer.connections == 1)
        }
    }

    @Test("Equal optional identities preserve sinks and retry across phase and payload changes")
    func presentationIdentity() async throws {
        let model = PresentationIdentityModel()
        defer { withExtendedLifetime(model) {} }
        let data = model.data
        data.connect()
        try #require(await eventually { model.source.producers.count == 1 })
        #expect(model.source.ids == [nil])
        model.source.producers[0].yield(.success(41))
        try #require(await eventually { data.latestValue == .available(41) })
        let firstSink = try #require(model.lastSink)
        let firstRetry = try #require(data.retryAction)

        model.hero.beginLoading()
        firstSink.receive(Result<Int, IdentityFailure>.success(42))
        #expect(data.latestValue == .available(42))
        firstRetry()
        try #require(await eventually { model.source.refreshes == 1 })
        model.hero.fail(IdentityFailure.offline)
        firstSink.receive(Result<Int, IdentityFailure>.success(43))
        for _ in 0..<10 { await Task.yield() }
        #expect(model.source.ids == [nil])
        #expect(data.latestValue == .available(43))

        model.hero.set(Wallet(id: 7, title: "First"))
        firstSink.reset()
        firstRetry()
        #expect(data.latestValue == .available(43))
        try #require(await eventually { model.source.producers.count == 2 })
        #expect(model.source.ids == [nil, 7])
        #expect(model.source.refreshes == 1)
        model.source.producers[1].yield(.success(44))
        try #require(await eventually { data.latestValue == .available(44) })
        let secondSink = try #require(model.lastSink)
        let secondRetry = try #require(data.retryAction)

        model.hero.beginLoading()
        model.hero.set(Wallet(id: 7, title: "Renamed"))
        secondSink.receive(Result<Int, IdentityFailure>.success(45))
        secondRetry()
        try #require(await eventually { model.source.refreshes == 2 })
        #expect(model.source.ids == [nil, 7])
        #expect(data.latestValue == .available(45))

        model.hero.reset()
        secondSink.reset()
        #expect(data.latestValue == .available(45))
        try #require(await eventually { model.source.producers.count == 3 })
        #expect(model.source.ids == [nil, 7, nil])
        model.hero.beginLoading()
        for _ in 0..<10 { await Task.yield() }
        #expect(model.source.producers.count == 3)
    }

    @Test("Equal IDs keep completed sources complete and retry usable")
    func completedConnection() async throws {
        let model = PresentationIdentityModel()
        defer { withExtendedLifetime(model) {} }
        let data = model.data
        data.connect()
        try #require(await eventually { model.source.producers.count == 1 })
        model.source.producers[0].yield(.success(7))
        model.source.producers[0].finish()
        try #require(await eventually { data.latestValue == .available(7) && data.binding?.isRunning == false })
        let retry = try #require(data.retryAction)
        model.hero.beginLoading()
        model.hero.fail(IdentityFailure.offline)
        for _ in 0..<10 { await Task.yield() }
        #expect(model.source.producers.count == 1)
        #expect(data.binding?.isRunning == false)
        retry()
        try #require(await eventually { model.source.refreshes == 1 })
        #expect(model.source.producers.count == 2)
    }

    @Test("Equal IDs preserve a pending cold request until its result arrives")
    func pendingRequest() async throws {
        let model = PresentationIdentityModel()
        defer { withExtendedLifetime(model) {} }
        let data = model.cold
        var returned = false
        let request = Task { await data.reload(); returned = true }
        defer { request.cancel() }
        try #require(await eventually { model.source.producers.count == 1 })
        model.source.producers[0].yield(.success(7))
        try #require(await eventually { data.latestValue == .available(7) })
        let sink = try #require(model.lastSink)
        model.hero.beginLoading()
        model.hero.fail(IdentityFailure.offline)
        sink.receive(Result<Int, IdentityFailure>.success(8))
        for _ in 0..<10 { await Task.yield() }
        #expect(!returned)
        #expect(model.source.producers.count == 1)
        #expect(data.latestValue == .available(8))
        model.source.producers[0].yield(.success(9))
        model.source.producers[0].finish()
        await request.value
        #expect(returned)
        #expect(data.latestValue == .available(9))
        #expect(model.source.producers.count == 1)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

private enum IdentityFailure: Error { case offline }

@Observable
private final class TrackingProducer {
    var value = 0
    @ObservationIgnored var connections = 0
    @ObservationIgnored var nestedChanges = 0
    @ObservationIgnored private var producers: [AsyncStream<Result<Int, IdentityFailure>>.Continuation] = []

    func values() -> AsyncStream<Result<Int, IdentityFailure>> {
        connections += 1
        let snapshot = withObservationTracking { value } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.nestedChanges += 1
            }
        }
        let (stream, producer) = AsyncStream<Result<Int, IdentityFailure>>.makeStream()
        producers.append(producer)
        producer.yield(.success(snapshot))
        return stream
    }

    func publish(_ value: Int) {
        self.value = value
        for producer in producers { producer.yield(.success(value)) }
    }
}

@Observable
private final class ProducerIdentityModel {
    var selection = 0
    let producer = TrackingProducer()

    @ViewDataSource(make: { (model: Self) in
        _ = model.selection
        return model.producer.values()
    })
    @ObservationIgnored
    var fixed: ViewData<Int>

    @ViewDataSource(id: \.selection, make: { (model: Self) in model.producer.values() })
    @ObservationIgnored
    var keyed: ViewData<Int>
}

private struct Wallet: Equatable {
    let id: Int
    let title: String
}

private final class IdentitySource {
    var ids: [Int?] = []
    var producers: [AsyncStream<Result<Int, IdentityFailure>>.Continuation] = []
    var refreshes = 0

    func values(for id: Int?) -> AsyncStream<Result<Int, IdentityFailure>> {
        let (stream, producer) = AsyncStream<Result<Int, IdentityFailure>>.makeStream()
        ids.append(id)
        producers.append(producer)
        return stream
    }

    func refresh() { refreshes += 1 }
}

private final class PresentationIdentityModel {
    let hero = ViewData<Wallet>()
    let source = IdentitySource()
    var lastSink: ViewDataSink<Int>?

    @ViewDataSource(
        id: \.walletID,
        make: { (model: Self) in model.source.values(for: model.walletID) },
        receive: { model, result, sink in
            model.lastSink = sink
            sink.receive(result)
        }
    )
    var cold: ViewData<Int>

    var walletID: Int? {
        if case .available(let wallet) = hero.latestValue { wallet.id } else { nil }
    }

    @ViewDataSource(
        id: \.walletID,
        make: { (model: Self) in model.source.values(for: model.walletID) },
        refresh: { model, _ in model.source.refresh() },
        receive: { model, result, sink in
            model.lastSink = sink
            sink.receive(result)
        }
    )
    var data: ViewData<Int>
}
