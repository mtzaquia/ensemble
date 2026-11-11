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

@Suite("Loadable sources")
struct LoadableSourceTests {
    @Test("A first read creates one dormant producer and reads its seed once")
    func dormantSeed() throws {
        let model = LoadableModel(seeds: [0: .available(7)])
        #expect(model.producers.isEmpty)
        let data = model.data
        let source = try #require(model.producers.first)
        #expect(model.data === data)
        #expect(model.producers.count == 1)
        #expect(source.availabilityReads == 1)
        #expect(source.subscriptions == 0)
        #expect(source.requests.isEmpty)
        #expect(data.latestValue == .available(7))
        #expect(data.phase.kind == .success)
    }

    @Test("Connect and concurrent reloads await the same initial load")
    func joinsInitialLoad() async throws {
        let model = LoadableModel(seeds: [0: .available(7)])
        defer { withExtendedLifetime(model) {} }
        let data = model.data
        let source = try #require(model.producers.first)
        data.connect()
        data.connect()
        try await source.events.wait(.started(0))

        // Even after an update, explicit reloads join work that is still in flight.
        try await observeChange(in: data) { source.send(.outcome(.success(8))) }
        let callers = LoadEvents()
        let first = Task {
            callers.record(.started(0))
            await data.reload()
            callers.record(.finished(0))
        }
        let second = Task {
            callers.record(.started(1))
            await data.reload()
            callers.record(.finished(1))
        }
        defer { first.cancel(); second.cancel() }
        try await callers.wait(.started(0))
        try await callers.wait(.started(1))
        #expect(!callers.contains(.finished(0)))
        #expect(!callers.contains(.finished(1)))
        #expect(source.requests == [.initial])
        #expect(source.subscriptionAtRequest == [1])
        source.finishLoad(0)
        try await callers.wait(.finished(0))
        try await callers.wait(.finished(1))
        #expect(model.producers.count == 1)
        #expect(source.availabilityReads == 1)
        #expect(data.latestValue == .available(8))
    }

    @Test("Reload before connection awaits initial, then reload awaits work on the same producer")
    func reloadAwaitsWork() async throws {
        let model = LoadableModel()
        defer { withExtendedLifetime(model) {} }
        let data = model.data
        let source = try #require(model.producers.first)
        try await load(data, source: source, at: 0)
        #expect(source.requests == [.initial])
        #expect(data.phase.kind == .empty)

        try await load(data, source: source, at: 1)
        #expect(source.requests == [.initial, .reload(.automatic)])
        #expect(source.subscriptionAtRequest == [1, 1])
        #expect(model.producers.count == 1)
        try await observeChange(in: data) { source.send(.outcome(.success(42))) }
        #expect(data.latestValue == .available(42))
    }

    @Test("An explicit reason reaches the producer while the initial load is active", arguments: [
        ViewDataReloadReason.automatic, .userInitiated,
    ])
    func reasonedReloadDuringInitialLoad(reason: ViewDataReloadReason) async throws {
        let model = LoadableModel()
        defer { withExtendedLifetime(model) {} }
        let data = model.data
        let source = try #require(model.producers.first)
        data.connect()
        try await source.events.wait(.started(0))

        let callers = LoadEvents()
        let reload = Task {
            await data.reload(reason)
            callers.record(.finished(0))
        }
        defer { reload.cancel() }
        try await source.events.wait(.started(1))
        #expect(source.requests == [.initial, .reload(reason)])
        #expect(source.subscriptionAtRequest == [1, 1])
        source.finishLoad(1)
        try await callers.wait(.finished(0))
        #expect(!source.events.contains(.finished(0)))
        source.finishLoad(0)
    }

    @Test("A reasoned batch forwards the reason to loadable and hot sources", arguments: [
        ViewDataReloadReason.automatic, .userInitiated,
    ])
    func batchReloadReasons(reason: ViewDataReloadReason) async throws {
        let model = LoadableModel()
        defer { withExtendedLifetime(model) {} }
        let data = model.data
        let hot = model.hot
        let source = try #require(model.producers.first)
        let callers = LoadEvents()
        let reload = Task {
            await Ensemble.reload(reason, data, hot, data)
            callers.record(.finished(0))
        }
        defer { reload.cancel() }
        try await source.events.wait(.started(0))
        try await model.hotEvents.wait(.finished(0))
        #expect(source.requests == [.reload(reason)])
        #expect(source.subscriptionAtRequest == [1])
        #expect(model.hotReasons == [reason])
        source.finishLoad(0)
        try await callers.wait(.finished(0))

        await hot.reload()
        #expect(model.hotReasons == [reason, .automatic])
        try await observeChange(in: hot) {
            model.hotUpdates.continuation.yield(.failure(Offline()))
        }
        let retry = try #require(hot.retryAction)
        retry()
        try await model.hotEvents.wait(.finished(2))
        #expect(model.hotReasons == [reason, .automatic, .userInitiated])
    }

    @Test("Failure retains success, retry reloads, and a native reset clears success")
    func failureRetryAndReset() async throws {
        let model = LoadableModel(seeds: [0: .available(7)])
        defer { withExtendedLifetime(model) {} }
        let data = model.data
        let source = try #require(model.producers.first)
        data.connect()
        try await source.events.wait(.started(0))
        try await observeChange(in: data) { source.send(.outcome(.failure(Offline()))) }
        #expect(data.phase.kind == .failure)
        #expect(data.latestValue == .available(7))

        let retry = try #require(data.retryAction)
        retry()
        try await source.events.wait(.started(1))
        #expect(source.requests == [.initial, .reload(.userInitiated)])
        #expect(source.subscriptionAtRequest == [1, 1])
        source.finishLoad(0)
        source.finishLoad(1)
        try await source.events.wait(.finished(1))
        try await observeChange(in: data) { source.send(.invalidate) }
        #expect(data.phase.kind == .empty)
        #expect(data.latestValue == .unavailable)
    }

    @Test("Retry after iteration fails resubscribes to the same producer")
    func reconnectsAfterCompletion() async throws {
        let model = LoadableModel()
        defer { withExtendedLifetime(model) {} }
        let data = model.data
        let source = try #require(model.producers.first)
        try await load(data, source: source, at: 0)
        try await observeChange(in: data) { source.endSubscription(throwing: Offline()) }
        #expect(data.binding?.isRunning == false)
        let retry = try #require(data.retryAction)
        retry()
        try await source.events.wait(.started(1))
        #expect(source.requests == [.initial, .reload(.userInitiated)])
        #expect(source.subscriptionAtRequest == [1, 2])
        #expect(model.producers.count == 1)
        #expect(source.availabilityReads == 1)
        source.finishLoad(1)
    }

    @Test("A dormant identity change is resolved when connecting")
    func changedBeforeConnection() async throws {
        let model = LoadableModel(seeds: [0: .available(7), 1: .available(8)])
        defer { withExtendedLifetime(model) {} }
        let data = model.data
        let original = try #require(model.producers.first)
        model.id = 1
        #expect(model.data === data)
        #expect(data.latestValue == .available(7))
        #expect(model.producers.count == 1)

        data.connect()
        try await model.events.wait(.started(1))
        let replacement = try #require(model.producers.last)
        try await replacement.events.wait(.started(0))
        #expect(model.producers.count == 2)
        #expect(original.subscriptions == 0)
        #expect(original.requests.isEmpty)
        #expect(data.latestValue == .available(8))
        replacement.finishLoad(0)
    }

    @Test("Rebinding uses the new availability and cancels old work", arguments: [
        ViewDataAvailability<Int>.available(9), .unavailable,
    ])
    func rebinds(seed: ViewDataAvailability<Int>) async throws {
        let model = LoadableModel(seeds: [0: .available(7), 1: seed])
        defer { withExtendedLifetime(model) {} }
        let data = model.data
        let first = try #require(model.producers.first)
        data.connect()
        try await first.events.wait(.started(0))
        let oldRetry = try #require(data.retryAction)

        // Queue an old update before the mutation, then attempt another from the cancelled load.
        first.send(.outcome(.success(99)))
        first.lateValueOnCancellation = 100
        model.id = 1
        oldRetry()
        try await model.events.wait(.started(1))
        let second = try #require(model.producers.last)
        try await second.events.wait(.started(0))
        try await first.events.wait(.cancelled(0))
        try await first.events.wait(.terminated(0))
        #expect(model.data === data)
        #expect(model.producers.count == 2)
        #expect(data.latestValue == seed)
        #expect(first.requests == [.initial])
        #expect(second.availabilityReads == 1)
        #expect(second.requests == [.initial])
        #expect(second.subscriptionAtRequest == [1])
        try await observeChange(in: data) { second.send(.outcome(.success(42))) }
        #expect(data.latestValue == .available(42))
        second.finishLoad(0)
    }

    @Test("Owner release cancels iteration and all in-flight loads even when data is retained")
    func releasesOwner() async throws {
        var model: LoadableModel? = LoadableModel(seeds: [0: .available(7)])
        weak let owner = model
        let data = try #require(model?.data)
        let source = try #require(model?.producers.first)
        data.connect()
        try await source.events.wait(.started(0))
        try await observeChange(in: data) { source.send(.outcome(.failure(Offline()))) }
        let retry = try #require(data.retryAction)
        retry()
        try await source.events.wait(.started(1))
        source.lateValueOnCancellation = 99

        model = nil
        #expect(owner == nil)
        try await source.events.wait(.terminated(0))
        try await source.events.wait(.cancelled(0))
        try await source.events.wait(.cancelled(1))
        retry()
        await data.reload()
        #expect(data.latestValue == .available(7))
        #expect(data.retryAction == nil)
        #expect(source.requests == [.initial, .reload(.userInitiated)])
    }

    @Test("A fixed source can override native element handling")
    func customReceive() async throws {
        let model = LoadableModel()
        defer { withExtendedLifetime(model) {} }
        let data = model.adapted
        let source = try #require(model.producers.first)
        try await load(data, source: source, at: 0)
        try await observeChange(in: data) { source.send(.outcome(.success(42))) }
        #expect(model.received == [42])
        #expect(data.latestValue == .available(84))
    }

    private func load(_ data: ViewData<Int>, source: LoadProducer<Int>, at index: Int) async throws {
        let callers = LoadEvents()
        let task = Task {
            await data.reload()
            callers.record(.finished(0))
        }
        defer { task.cancel() }
        try await source.events.wait(.started(index))
        #expect(!callers.contains(.finished(0)))
        source.finishLoad(index)
        try await callers.wait(.finished(0))
    }

    private func observeChange<Value>(in data: ViewData<Value>, send: () -> Void) async throws {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        withObservationTracking {
            _ = data.phase
            _ = data.latestValue
        } onChange: {
            continuation.yield(())
            continuation.finish()
        }
        send()
        try #require(await receivedSignal(stream))
    }
}

@Observable
private final class LoadableModel {
    var id = 0
    @ObservationIgnored private(set) var producers: [LoadProducer<Int>] = []
    @ObservationIgnored var received: [Int] = []
    let events = LoadEvents()
    let hotEvents = LoadEvents()
    let hotUpdates = AsyncStream<Result<String, Offline>>.makeStream()
    @ObservationIgnored private(set) var hotReasons: [ViewDataReloadReason] = []
    private let seeds: [Int: ViewDataAvailability<Int>]

    init(seeds: [Int: ViewDataAvailability<Int>] = [:]) { self.seeds = seeds }

    @ViewDataSource(id: \.id, updates: { (model: Self) in model.makeProducer() })
    @ObservationIgnored var data: ViewData<Int>

    @ViewDataSource(
        updates: { (model: Self) in model.makeProducer() },
        receive: { model, element, sink in
            if case .outcome(.success(let value)) = element {
                model.received.append(value)
                sink.receive(Result<Int, Never>.success(value * 2))
            }
        }
    )
    @ObservationIgnored var adapted: ViewData<Int>

    @ViewDataSource(
        make: { (model: Self) in model.hotUpdates.stream },
        refresh: { model, reason in
            model.hotReasons.append(reason)
            model.hotEvents.record(.finished(model.hotReasons.count - 1))
        }
    )
    @ObservationIgnored var hot: ViewData<String>

    private func makeProducer() -> LoadProducer<Int> {
        let producer = LoadProducer(seeds[id] ?? .unavailable)
        producers.append(producer)
        events.record(.started(producers.count - 1))
        return producer
    }
}

private struct Offline: Error {}

private enum NativeUpdate<Value: Sendable>: Sendable {
    case outcome(Result<Value, any Error>)
    case invalidate
}

// The producer is generic over its own native update element, without an Ensemble-specific constraint.
private final class LoadProducer<Value: Sendable> {
    let events = LoadEvents()
    let seed: ViewDataAvailability<Value>
    private(set) var availabilityReads = 0
    private(set) var subscriptions = 0
    private(set) var requests: [ViewDataLoadRequest] = []
    private(set) var subscriptionAtRequest: [Int] = []
    var lateValueOnCancellation: Value?
    private var gates: [AsyncStream<Void>.Continuation] = []
    private var continuation: AsyncThrowingStream<NativeUpdate<Value>, any Error>.Continuation?

    init(_ seed: ViewDataAvailability<Value>) { self.seed = seed }

    func finishLoad(_ index: Int) { gates[index].finish() }
    func send(_ update: NativeUpdate<Value>) { continuation?.yield(update) }
    func endSubscription(throwing error: any Error) { continuation?.finish(throwing: error) }
}

extension LoadProducer: ViewDataLoadableSource {
    var availability: ViewDataAvailability<Value> {
        availabilityReads += 1
        return seed
    }

    func viewDataUpdates() -> AsyncThrowingStream<NativeUpdate<Value>, any Error> {
        let (stream, continuation) = AsyncThrowingStream<NativeUpdate<Value>, any Error>.makeStream()
        let index = subscriptions
        subscriptions += 1
        self.continuation = continuation
        continuation.onTermination = { [events] _ in
            Task { @MainActor in events.record(.terminated(index)) }
        }
        return stream
    }

    func viewDataUpdate(for element: NativeUpdate<Value>) -> ViewDataUpdate<Value> {
        switch element {
        case .outcome(let result): .result(result)
        case .invalidate: .reset
        }
    }

    func viewDataLoad(_ request: ViewDataLoadRequest) async {
        let index = requests.count
        requests.append(request)
        subscriptionAtRequest.append(subscriptions)
        let (stream, gate) = AsyncStream<Void>.makeStream()
        gates.append(gate)
        let subscription = continuation
        events.record(.started(index))
        for await _ in stream {}
        if Task.isCancelled {
            if let lateValueOnCancellation { subscription?.yield(.outcome(.success(lateValueOnCancellation))) }
            events.record(.cancelled(index))
        }
        events.record(.finished(index))
    }
}

private final class LoadEvents {
    enum Event: Hashable, Sendable {
        case started(Int), finished(Int), cancelled(Int), terminated(Int)
    }

    private var recorded: Set<Event> = []
    private var waiters: [Event: [AsyncStream<Void>.Continuation]] = [:]

    func contains(_ event: Event) -> Bool { recorded.contains(event) }

    func record(_ event: Event) {
        recorded.insert(event)
        for continuation in waiters.removeValue(forKey: event) ?? [] {
            continuation.yield(())
            continuation.finish()
        }
    }

    func wait(_ event: Event) async throws {
        guard !contains(event) else { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        waiters[event, default: []].append(continuation)
        defer { continuation.finish() }
        try #require(await receivedSignal(stream), "Timed out waiting for \(event)")
    }
}

private func receivedSignal(_ stream: AsyncStream<Void>) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await _ in stream { return true }
            return false
        }
        group.addTask {
            // A deadline bounds a missing signal. Fixture progress depends only on explicit gates.
            try? await Task.sleep(for: .seconds(5))
            return false
        }
        let received = await group.next() ?? false
        group.cancelAll()
        return received
    }
}
