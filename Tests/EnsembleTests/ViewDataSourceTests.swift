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

@Suite("Model-owned source lifetime")
struct ViewDataSourceTests {
    @Test("First access seeds synchronously and schedules one activation")
    func lazyConstruction() async {
        let useCase = SourceUseCase()
        let model = SourceModel(useCase: useCase, initial: .available(41))
        defer { withExtendedLifetime(model) {} }
        for _ in 0..<10 { await Task.yield() }
        #expect(useCase.connections == 0)
        let data = model.value
        #expect(model.value === data)
        #expect(data.latestValue == .available(41))
        #expect(data.phase.kind == .success)
        #expect(useCase.connections == 0)
        let content = AsyncContent(data, loading: .placeholder(0)) { value, _ in Text("\(value)") }
        guard case .content(41, .latest) = content.rendering else {
            Issue.record("The first presentation must use the seed")
            return
        }
        #expect(await eventually { useCase.connections == 1 })
        #expect(useCase.refreshes == 0)
        #expect(data.phase.kind == .success)
    }

    @Test("Repeated reads and multiple consumers reuse the model's source")
    func sharedConnection() async {
        let useCase = SourceUseCase()
        let model = SourceModel(useCase: useCase)
        defer { withExtendedLifetime(model) {} }
        let data = model.value
        #expect(await eventually { useCase.connections == 1 })
        for _ in 0..<10 {
            #expect(model.value === data)
            _ = AsyncContent(data) { value, _ in Text("\(value)") }
            await Task.yield()
        }
        useCase.continuations[0].yield(.success(42))
        #expect(await eventually { data.latestValue == .available(42) })
        #expect(useCase.connections == 1)
        #expect(useCase.refreshes == 0)
    }

    @Test("Badge and conditional-gate reads activate without AsyncContent")
    func derivedReads() async {
        let useCase = SourceUseCase()
        let model = SourceModel(useCase: useCase)
        defer { withExtendedLifetime(model) {} }
        #expect(model.badgeCount == 0)
        #expect(!model.canShowContent)
        #expect(await eventually { useCase.connections == 1 })
        useCase.continuations[0].yield(.success(42))
        #expect(await eventually { model.badgeCount == 42 && model.canShowContent })
    }

    @Test("Each declaration activates independently on its own first access")
    func declaredSeeds() async {
        let useCase = SourceUseCase()
        let model = SourceModel(useCase: useCase)
        defer { withExtendedLifetime(model) {} }
        #expect(model.seeded.latestValue == .available(7))
        #expect(await eventually { useCase.connections == 1 })
        #expect(useCase.refreshes == 0)
        #expect(model.empty.latestValue == .unavailable)
        #expect(await eventually { useCase.connections == 2 })
        #expect(model.empty.phase.kind == .empty)
    }

    @Test("A hot producer replays on activation without refreshing")
    func producerOwnsInitialEmission() async {
        let useCase = SourceUseCase()
        useCase.valueOnSubscription = 42
        let model = SourceModel(useCase: useCase)
        defer { withExtendedLifetime(model) {} }
        let data = model.value
        #expect(await eventually { data.latestValue == .available(42) })
        #expect(useCase.refreshes == 0)
    }

    @Test("Observed inputs rebind without any view consumer and retain successful content")
    func activeRebinding() async throws {
        let original = SourceUseCase()
        let replacement = SourceUseCase()
        let model = SourceModel(useCase: original)
        defer { withExtendedLifetime(model) {} }
        let data = model.seeded
        #expect(await eventually { original.connections == 1 })
        await data.reload()
        #expect(await eventually { data.latestValue == .available(1) })
        let obsoleteRetry = try #require(data.retryAction)
        let obsoleteProducer = original.continuations[0]
        model.useCase = replacement
        try #require(await eventually { replacement.connections == 1 })
        #expect(model.seeded === data)
        #expect(data.latestValue == .available(1))
        #expect(replacement.refreshes == 0)
        await data.reload()
        obsoleteProducer.yield(.success(999))
        obsoleteRetry()
        replacement.continuations[0].yield(.success(42))
        #expect(await eventually { data.latestValue == .available(42) })
        #expect(original.refreshes == 1)
    }

    @Test("Inputs changed before first access stay lazy; reset keeps the active source")
    func unreadInputs() async {
        let original = SourceUseCase()
        let replacement = SourceUseCase()
        let model = SourceModel(useCase: original, initial: .available(41))
        defer { withExtendedLifetime(model) {} }
        model.useCase = replacement
        for _ in 0..<10 { await Task.yield() }
        #expect(original.connections == 0 && replacement.connections == 0)
        let data = model.value
        #expect(await eventually { replacement.connections == 1 })
        data.reset()
        #expect(data.latestValue == .unavailable)
        replacement.continuations[0].yield(.success(42))
        #expect(await eventually { data.latestValue == .available(42) })
        #expect(replacement.refreshes == 0)
    }

    @Test("Releasing the owner before scheduled activation starts no work")
    func releasedBeforeActivation() async {
        let useCase = SourceUseCase()
        var model: SourceModel? = SourceModel(useCase: useCase, initial: .available(41))
        weak let weakModel = model
        let data = model!.value
        model = nil
        #expect(weakModel == nil)
        await data.reload()
        for _ in 0..<10 { await Task.yield() }
        #expect(useCase.connections == 0)
        #expect(useCase.refreshes == 0)
        #expect(data.latestValue == .available(41))
        #expect(data.retryAction == nil)
    }

    @Test("Owner release cancels a waiting stream even when ViewData is retained")
    func releasedOwnerCancelsSource() async {
        let useCase = SourceUseCase()
        var model: SourceModel? = SourceModel(useCase: useCase, initial: .available(41))
        weak let weakModel = model
        let data = model!.value
        #expect(await eventually { useCase.connections == 1 })
        model = nil
        #expect(weakModel == nil)
        #expect(data.binding?.isConnected == false)
        #expect(data.binding?.isRunning == false)
        #expect(data.retryAction == nil)
        #expect(await eventually {
            if case .terminated = useCase.continuations[0].yield(.success(99)) { return true }
            return false
        })
        let revision = data.presentationRevision
        await data.reload()
        #expect(data.presentationRevision == revision)
        #expect(data.latestValue == .available(41))
    }

    @Test("A completed source stays complete across reads and reload starts fresh work")
    func completedSource() async {
        let model = ColdSourceModel()
        defer { withExtendedLifetime(model) {} }
        let data = model.value
        #expect(await eventually { data.latestValue == .available(1) && data.binding?.isRunning == false })
        for _ in 0..<10 { _ = model.value; await Task.yield() }
        #expect(model.requests == 1)
        await data.reload()
        #expect(model.requests == 2)
        #expect(data.latestValue == .available(2))
    }

    @Test("Immediate cold reload shares initial activation instead of fetching twice")
    func immediateColdReload() async {
        let model = ColdSourceModel()
        defer { withExtendedLifetime(model) {} }
        await model.value.reload()
        #expect(model.requests == 1)
        #expect(model.value.latestValue == .available(1))
    }

    @Test("Self resolves generic owners without rewriting strings or metatypes")
    func genericOwnerInference() async {
        let model = GenericSourceModel<Int>()
        defer { withExtendedLifetime(model) {} }
        let data = model.value
        #expect(await eventually { data.latestValue == .available(1) })
    }

    @Test("Ordinary state remains passive")
    func passiveData() async {
        let data = ViewData<Int>()
        await data.reload()
        #expect(data.phase.kind == .empty)
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
    var useCase: SourceUseCase

    var badgeCount: Int {
        if case .available(let count) = value.latestValue { count } else { 0 }
    }
    var canShowContent: Bool { badgeCount > 0 }
    let initial: ViewDataAvailability<Int>

    @ViewDataSource(
        initial: { (model: Self) in model.initial },
        make: { (model: Self) in model.useCase.values() },
        refresh: { model in model.useCase.reload() }
    )
    @ObservationIgnored
    var value: ViewData<Int>

    @ViewDataSource(
        initial: { _ in .available(7) },
        make: { (model: Self) in model.useCase.values() },
        refresh: { (model: Self) in model.useCase.reload() }
    )
    @ObservationIgnored
    var seeded: ViewData<Int>

    @ViewDataSource(
        make: { (model: Self) in model.useCase.values() },
        refresh: { model in model.useCase.reload() }
    )
    @ObservationIgnored
    var empty: ViewData<Int>

    init(useCase: SourceUseCase, initial: ViewDataAvailability<Int> = .unavailable) {
        self.useCase = useCase
        self.initial = initial
    }
}

private final class ColdSourceModel {
    var requests = 0

    @ViewDataSource(make: { (model: Self) in model.values() })
    var value: ViewData<Int>

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
    var value: ViewData<Int>

    func values(label: String, type: Element.Type) -> AsyncStream<Result<Int, SourceFailure>> {
        AsyncStream { continuation in
            continuation.yield(.success(1))
            continuation.finish()
        }
    }
}
