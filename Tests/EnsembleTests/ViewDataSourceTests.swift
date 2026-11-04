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

@Suite("Managed view data sources")
struct ViewDataSourceTests {
    @Test("Macro construction and reads are lazy and expose seeds synchronously")
    func lazyConstruction() {
        let useCase = SourceUseCase()
        let model = SourceModel(useCase: useCase, initial: .available(41))
        let data = model.value
        #expect(model.value === data)
        #expect(data.latestValue == .available(41))
        #expect(data.phase.kind == .success)
        #expect(useCase.connections == 0)
        #expect(useCase.refreshes == 0)
        let content = AsyncContent(data, loading: .placeholder(0)) { value, _ in Text("\(value)") }
        guard case .content(41, .latest) = content.rendering else {
            Issue.record("The first presentation must use the seed")
            return
        }
        #expect(useCase.connections == 0)
    }

    @Test("Two observers share a connection and only the last cancellation stops it")
    func sharedObservation() async {
        let useCase = SourceUseCase()
        let model = SourceModel(useCase: useCase)
        let data = model.value
        let first = Task { await data.observe() }
        let second = Task { await data.observe() }
        #expect(await eventually { data.binding?.observerCount == 2 })
        #expect(useCase.refreshes == 0)
        await data.reload()
        #expect(await eventually { data.latestValue == .available(1) })
        #expect(useCase.connections == 1)
        #expect(useCase.refreshes == 1)
        first.cancel()
        await first.value
        #expect(data.binding?.isConnected == true)
        second.cancel()
        await second.value
        #expect(data.binding?.isConnected == false)
        #expect(data.latestValue == .available(1))
        #expect(data.phase.kind == .success)

        let third = Task { await data.observe() }
        #expect(await eventually { useCase.connections == 2 })
        #expect(useCase.refreshes == 1)
        third.cancel()
        await third.value
    }

    @Test("Seeded data still connects without requesting an unnecessary refresh")
    func seededConnection() async {
        let useCase = SourceUseCase()
        // Retain the owner while a macro factory needs to invoke it.
        let model = SourceModel(useCase: useCase, initial: .available(41))
        let retainedData = model.value
        let observation = Task { await retainedData.observe() }
        #expect(await eventually { useCase.connections == 1 })
        #expect(useCase.refreshes == 0)
        #expect(retainedData.latestValue == .available(41))
        #expect(retainedData.phase.kind == .success)
        observation.cancel()
        await observation.value
    }

    @Test("Declaration-site seeds and property initializers connect without refreshing")
    func declaredSeeds() async {
        let useCase = SourceUseCase()
        let model = SourceModel(useCase: useCase)
        #expect(model.seeded.latestValue == .available(7))
        let seeded = Task { await model.seeded.observe() }
        #expect(await eventually { useCase.connections == 1 })
        #expect(useCase.refreshes == 0)
        #expect(model.seeded.phase.kind == .success)
        seeded.cancel()
        await seeded.value
        let empty = Task { await model.empty.observe() }
        #expect(await eventually { useCase.connections == 2 })
        #expect(useCase.refreshes == 0)
        #expect(model.empty.phase.kind == .empty)
        empty.cancel()
        await empty.value
    }

    @Test("Hot sources reconnect without refreshing even when no value is available")
    func unseededObservation() async {
        let useCase = SourceUseCase()
        let model = SourceModel(useCase: useCase)
        let data = model.value
        let first = Task { await data.observe() }
        #expect(await eventually { useCase.connections == 1 })
        #expect(useCase.refreshes == 0)
        #expect(data.phase.kind == .empty)
        first.cancel()
        await first.value
        let second = Task { await data.observe() }
        #expect(await eventually { useCase.connections == 2 })
        #expect(useCase.refreshes == 0)
        await data.reload()
        #expect(useCase.refreshes == 1)
        #expect(await eventually { data.latestValue == .available(1) })
        second.cancel()
        await second.value
    }

    @Test("A hot producer can replay its snapshot on subscription without invoking refresh")
    func producerOwnsInitialEmission() async {
        let useCase = SourceUseCase()
        useCase.valueOnSubscription = 42
        let model = SourceModel(useCase: useCase)
        let observation = Task { await model.value.observe() }
        #expect(await eventually { model.value.latestValue == .available(42) })
        #expect(useCase.refreshes == 0)
        observation.cancel()
        await observation.value
    }

    @Test("Active replacement preserves real model state and rejects obsolete results and retries")
    func activeReplacement() async throws {
        let original = SourceUseCase()
        let replacement = SourceUseCase()
        let model = SourceModel(useCase: original)
        let data = model.seeded
        let observation = Task { await data.observe() }
        #expect(await eventually { data.binding?.observerCount == 1 })
        await data.reload()
        #expect(await eventually { data.latestValue == .available(1) })
        let obsoleteRetry = try #require(data.retryAction)
        let obsoleteProducer = original.continuations[0]
        data.replaceSource(make: replacement.values, refresh: replacement.reload)
        #expect(model.seeded === data)
        #expect(data.latestValue == .available(1))
        #expect(data.phase.kind == .success)
        #expect(replacement.connections == 1)
        #expect(replacement.refreshes == 0)
        await data.reload()
        #expect(data.phase.kind == .loading)
        #expect(replacement.refreshes == 1)
        obsoleteProducer.yield(.success(999))
        obsoleteRetry()
        #expect(original.refreshes == 1)
        replacement.continuations[0].yield(.success(42))
        #expect(await eventually { data.latestValue == .available(42) })
        await data.reload()
        #expect(replacement.refreshes == 2)
        observation.cancel()
        await observation.value
    }

    @Test("Inactive replacement stays lazy and resetting does not request a refresh")
    func inactiveReplacement() async {
        let original = SourceUseCase()
        let replacement = SourceUseCase()
        let model = SourceModel(useCase: original, initial: .available(41))
        model.value.replaceSource(make: replacement.values, refresh: replacement.reload)
        #expect(replacement.connections == 0)
        let observation = Task { await model.value.observe() }
        #expect(await eventually { replacement.connections == 1 })
        #expect(original.connections == 0)
        #expect(replacement.refreshes == 0)
        #expect(model.value.latestValue == .available(41))
        model.value.reset()
        model.value.replaceSource(make: replacement.values, refresh: replacement.reload)
        #expect(replacement.refreshes == 0)
        #expect(model.value.phase.kind == .empty)
        await model.value.reload()
        #expect(replacement.refreshes == 1)
        #expect(await eventually { model.value.latestValue == .available(1) })
        observation.cancel()
        await observation.value
    }

    @Test("Source-aware initialization provides the same lazy lifecycle without a macro")
    func sourceInitialization() async {
        let useCase = SourceUseCase()
        let data = ViewData(.available(41), make: useCase.values, refresh: useCase.reload)
        #expect(useCase.connections == 0)
        let lifecycle = AsyncContentSourceObservation()
        lifecycle.bind(to: data)
        #expect(await eventually { useCase.connections == 1 })
        #expect(useCase.refreshes == 0)
        #expect(data.latestValue == .available(41))
    }

    @Test("Owner-based initialization matches macro timing, retention, and cancellation")
    func ownerInitialization() async {
        let useCase = SourceUseCase()
        let data = ViewData(
            .available(41), owner: useCase,
            make: { $0.values() }, refresh: { $0.reload() }
        )
        #expect(useCase.connections == 0)
        #expect(useCase.refreshes == 0)
        let content = AsyncContent(data, loading: .placeholder(0)) { value, _ in Text("\(value)") }
        guard case .content(41, .latest) = content.rendering else {
            Issue.record("The owner initializer must expose its seed on the first presentation")
            return
        }
        let observation = Task { await data.observe() }
        #expect(await eventually { data.binding?.observerCount == 1 })
        await data.reload()
        #expect(await eventually { data.latestValue == .available(1) })
        #expect(useCase.connections == 1)
        #expect(useCase.refreshes == 1)
        useCase.continuations[0].yield(.failure(.offline))
        #expect(await eventually { data.phase.kind == .failure })
        #expect(data.latestValue == .available(1))
        await data.reload()
        #expect(await eventually { data.latestValue == .available(2) })
        observation.cancel()
        await observation.value
        #expect(data.binding?.isConnected == false)
        #expect(data.latestValue == .available(2))
    }

    @Test("Owner initializer does not retain its owner or reconnect after it is released")
    func initializerWeakOwner() async {
        var model: SourceModel? = SourceModel(useCase: SourceUseCase())
        weak var weakModel: SourceModel?
        weakModel = model
        let data = ViewData(
            .available(41), owner: model!,
            make: { $0.useCase.values() }, refresh: { $0.useCase.reload() }
        )
        let useCase = model!.useCase
        let observation = Task { await data.observe() }
        #expect(await eventually { data.binding?.observerCount == 1 })
        await data.reload()
        #expect(await eventually { data.latestValue == .available(1) })
        model = nil
        #expect(weakModel == nil)
        await data.reload()
        #expect(useCase.refreshes == 1)
        observation.cancel()
        await observation.value
        let reconnection = Task { await data.observe() }
        #expect(await eventually { data.binding?.observerCount == 1 })
        #expect(useCase.connections == 1)
        #expect(data.binding?.isConnected == false)
        #expect(data.latestValue == .available(1))
        reconnection.cancel()
        await reconnection.value
    }

    @Test("Self resolves the owner in generic models without rewriting strings or metatypes")
    func genericOwnerInference() async {
        let model = GenericSourceModel<Int>()
        let observation = Task { await model.value.observe() }
        #expect(await eventually { model.value.latestValue == .available(1) })
        observation.cancel()
        await observation.value
    }

    @Test("Cold sources resubscribe on reload without a refresh callback")
    func coldSource() async {
        let model = ColdSourceModel()
        let observation = Task { await model.value.observe() }
        #expect(await eventually { model.value.latestValue == .available(1) })
        await model.value.reload()
        #expect(await eventually { model.value.latestValue == .available(2) })
        observation.cancel()
        await observation.value
    }

    @Test("Retry uses the active producer and a cancelled observer never connects")
    func retryAndEarlyCancellation() async {
        let useCase = SourceUseCase()
        let model = SourceModel(useCase: useCase)
        let cancelled = Task { await model.value.observe() }
        cancelled.cancel()
        await cancelled.value
        #expect(useCase.connections == 0)
        let observation = Task { await model.value.observe() }
        #expect(await eventually { useCase.connections == 1 })
        useCase.continuations[0].yield(.failure(.offline))
        #expect(await eventually { model.value.phase.kind == .failure })
        model.value.retryAction?()
        #expect(await eventually { useCase.refreshes == 1 })
        #expect(await eventually { model.value.latestValue == .available(1) })
        observation.cancel()
        await observation.value
    }

    @Test("Factories do not keep the owning observable model alive")
    func weakOwner() async {
        let useCase = SourceUseCase()
        var model: SourceModel? = SourceModel(useCase: useCase)
        weak var weakModel: SourceModel?
        weakModel = model
        let data = model!.value
        let observation = Task { await data.observe() }
        #expect(await eventually { useCase.connections == 1 })
        model = nil
        #expect(weakModel == nil)
        await data.reload()
        observation.cancel()
        await observation.value
    }

    @Test("Ordinary data remains passive")
    func passiveData() async {
        let data = ViewData<Int>()
        await data.observe()
        await data.reload()
        #expect(data.phase.kind == .empty)
    }

    @Test("Lifecycle storage notices a source installed after an initially passive read")
    func lateSourceInstallation() async {
        let data = ViewData<Int>()
        let lifecycle = AsyncContentSourceObservation()
        lifecycle.bind(to: data)
        let useCase = SourceUseCase()
        data._installSource(
            owner: useCase,
            make: { $0.values() },
            refresh: { $0.reload() },
            receive: { result, sink in sink.receive(result) }
        )
        lifecycle.bind(to: data)
        #expect(await eventually { useCase.connections == 1 })
        #expect(useCase.refreshes == 0)
        await data.reload()
        #expect(await eventually { data.latestValue == .available(1) })
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

private enum SourceFailure: Error { case offline }

@Observable
private final class SourceModel {
    let useCase: SourceUseCase
    var selection = 0

    @ViewDataSource(
        make: { (model: Self) in model.useCase.values() },
        refresh: { model in model.useCase.reload() }
    )
    @ObservationIgnored
    var value: ViewData<Int>

    @ViewDataSource(
        make: { (model: Self) in model.useCase.values() },
        refresh: { (model: Self) in model.useCase.reload() },
        initialValue: .available(7)
    )
    @ObservationIgnored
    var seeded: ViewData<Int>

    @ViewDataSource(
        make: { (model: Self) in model.useCase.values() },
        refresh: { model in model.useCase.reload() }
    )
    @ObservationIgnored
    var empty: ViewData<Int> = ViewData()

    init(useCase: SourceUseCase, initial: ViewDataAvailability<Int> = .unavailable) {
        self.useCase = useCase
        value = ViewData(initial)
    }
}

private final class ColdSourceModel {
    var requests = 0

    @ViewDataSource(make: { (model: Self) in model.values() })
    var value: ViewData<Int> = ViewData()

    func values() -> AsyncStream<Result<Int, SourceFailure>> {
        requests += 1
        let request = requests
        return AsyncStream { continuation in
            continuation.yield(.success(request))
            continuation.finish()
        }
    }
}

private final class SourceUseCase {
    var connections = 0
    var refreshes = 0
    var valueOnSubscription: Int?
    var continuations: [AsyncStream<Result<Int, SourceFailure>>.Continuation] = []

    func values() -> AsyncStream<Result<Int, SourceFailure>> {
        connections += 1
        let (stream, continuation) = AsyncStream<Result<Int, SourceFailure>>.makeStream()
        continuations.append(continuation)
        if let valueOnSubscription { continuation.yield(.success(valueOnSubscription)) }
        return stream
    }

    func reload() {
        refreshes += 1
        continuations.last?.yield(.success(refreshes))
    }
}

private final class GenericSourceModel<Element> {
    @ViewDataSource(make: { (model: Self) in
        // A comment mentioning self and a metatype must not be treated as captures.
        model.values(label: "self", type: Element.self)
    })
    var value: ViewData<Int> = ViewData()

    func values(label: String, type: Element.Type) -> AsyncStream<Result<Int, SourceFailure>> {
        AsyncStream { continuation in
            continuation.yield(.success(1))
            continuation.finish()
        }
    }
}
