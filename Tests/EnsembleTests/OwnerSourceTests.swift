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
import SwiftUI
import Testing
@testable import Ensemble

@Suite("Owner-derived source callbacks")
struct OwnerSourceTests {
    @Test("Owner-derived seeds are synchronous, one-shot, and precede source work")
    func synchronousSeed() async {
        let model = OwnerSeedModel()
        defer { withExtendedLifetime(model) {} }
        #expect(model.seedReads == 0)
        let data = model.data
        data.connect()
        #expect(model.seedReads == 1)
        #expect(data.latestValue == .available(7))
        #expect(data.phase.kind == .success)
        #expect(model.source.connections == 0)
        let content = AsyncContent(data) { value, _ in Text("\(value)") }
        guard case .content(7, .latest) = content.rendering else {
            Issue.record("An owner-derived seed must be present in the first rendering")
            return
        }
        #expect(await eventually { model.source.connections == 1 })
        await data.reload()
        #expect(await eventually { data.latestValue == .available(42) })
        data.reset()
        #expect(model.data === data)
        #expect(data.latestValue == .unavailable)
        let replacement = OwnerSeedSource()
        model.source = replacement
        #expect(await eventually { replacement.connections == 1 })
        #expect(model.seedReads == 1)
        #expect(data.latestValue == .unavailable)
    }

    @Test("Owner seeds preserve unavailable, empty, and successful nil")
    func seedAvailability() {
        let unavailable = AvailabilitySeedModel<Int>(.unavailable)
        let empty = AvailabilitySeedModel<[Int]>(.available([]))
        let absent = AvailabilitySeedModel<Int?>(.available(nil))
        let unavailableData = unavailable.data
        let emptyData = empty.data
        let absentData = absent.data
        #expect(unavailableData.phase.kind == .empty)
        #expect(unavailableData.latestValue == .unavailable)
        #expect(emptyData.phase.kind == .success)
        #expect(emptyData.latestValue == .available([]))
        #expect(absentData.phase.kind == .success)
        #expect(absentData.latestValue == .available(nil))
    }

    @Test("Custom-element sources use the same owner seed and adapter")
    func customElements() async {
        let model = OwnerSeedModel()
        defer { withExtendedLifetime(model) {} }
        let data = model.custom
        data.connect()
        #expect(data.latestValue == .available(7))
        model.observedData = data
        #expect(await eventually { model.source.connections == 1 })
        model.source.emit(.success(23))
        #expect(await eventually { model.valuesAfterReceive == [.available(23)] })
        #expect(model.seedReads == 1)
    }

    @Test("Owner-aware adapters apply updates before model-side reads and stop after owner release")
    func ownerAdapter() async throws {
        var model: OwnerSeedModel? = OwnerSeedModel()
        weak let weakModel = model
        let source = model!.source
        let data = model!.adapted
        data.connect()
        #expect(await eventually { source.connections == 1 })
        model!.observedData = data
        source.emit(.success(21))
        #expect(await eventually { model?.valuesAfterReceive == [.available(21)] })
        #expect(data.latestValue == .available(21))
        let obsoleteSink = model!.lastSink
        let replacement = OwnerSeedSource()
        model!.source = replacement
        try #require(await eventually { replacement.connections == 1 })
        obsoleteSink?.reset()
        #expect(data.latestValue == .available(21))
        replacement.emit(.success(100))
        #expect(await eventually { data.latestValue == .available(100) })
        model = nil
        #expect(weakModel == nil)
        source.emit(.success(99))
        replacement.emit(.success(101))
        replacement.producers[0].finish()
        #expect(await eventually { data.binding?.isRunning == false })
        #expect(data.latestValue == .available(100))
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
private final class OwnerSeedModel {
    var sourceID: ObjectIdentifier { ObjectIdentifier(source) }
    var source = OwnerSeedSource()
    var seedReads = 0
    var valuesAfterReceive: [ViewDataAvailability<Int>] = []
    var lastSink: ViewDataSink<Int>?
    weak var observedData: ViewData<Int>?

    @ViewDataSource(
        id: \.sourceID,
        initial: { (model: Self) in model.initial() },
        make: { model in model.source.values() },
        refresh: { model, _ in model.source.refresh() }
    )
    @ObservationIgnored
    var data: ViewData<Int>

    @ViewDataSource(
        id: \.sourceID,
        initial: { _ in .available(7) },
        make: { (model: Self) in model.source.values() },
        refresh: { model, _ in model.source.refresh() },
        receive: { (model: Self, result, sink) in model.receive(result, sink: sink) }
    )
    @ObservationIgnored
    var adapted: ViewData<Int>

    @ViewDataSource(
        id: \.sourceID,
        initial: { (model: Self) in model.initial() },
        make: { model in model.source.values().map(OwnerSeedUpdate.result) },
        refresh: { model, _ in model.source.refresh() },
        receive: { model, update, sink in model.receive(update.result, sink: sink) }
    )
    @ObservationIgnored
    var custom: ViewData<Int>

    func initial() -> ViewDataAvailability<Int> {
        seedReads += 1
        return .available(7)
    }

    func receive(_ result: Result<Int, Never>, sink: ViewDataSink<Int>) {
        sink.receive(result)
        valuesAfterReceive.append(observedData?.latestValue ?? .unavailable)
        lastSink = sink
    }
}

private struct OwnerSeedUpdate {
    let result: Result<Int, Never>
    static func result(_ value: Result<Int, Never>) -> Self { Self(result: value) }
}

private final class AvailabilitySeedModel<Value: Sendable> {
    let seed: ViewDataAvailability<Value>

    @ViewDataSource(
        initial: { (model: Self) in model.seed },
        make: { model in model.values() }
    )
    var data: ViewData<Value>

    init(_ seed: ViewDataAvailability<Value>) { self.seed = seed }

    func values() -> AsyncStream<Result<Value, Never>> { AsyncStream { $0.finish() } }

}

private final class OwnerSeedSource {
    var connections = 0
    var producers: [AsyncStream<Result<Int, Never>>.Continuation] = []

    func values() -> AsyncStream<Result<Int, Never>> {
        connections += 1
        let (stream, producer) = AsyncStream<Result<Int, Never>>.makeStream()
        producers.append(producer)
        return stream
    }

    func refresh() { emit(.success(42)) }
    func emit(_ result: Result<Int, Never>) {
        for producer in producers { producer.yield(result) }
    }
}
