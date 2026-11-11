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

@testable import Ensemble
import Observation
import Testing

@Suite("Source callback context")
struct SourceContextTests {
    @Test("Seeds, source tasks, refresh, and retry use their documented context")
    func callbackContexts() async throws {
        let model = SourceContext.$name.withValue("creation") { ContextModel() }
        defer { withExtendedLifetime(model) {} }
        let data = SourceContext.$name.withValue("first-read") { model.data }
        #expect(model.creation == "creation")
        #expect(model.seedContext == "first-read")
        #expect(model.makeContexts.isEmpty)

        SourceContext.$name.withValue("connect") { data.connect() }
        try #require(await eventually { model.makeContexts == ["connect"] })
        SourceContext.$name.withValue("publisher") { model.producers[0].yield(.success(42)) }
        try #require(await eventually { data.latestValue == .available(42) })
        #expect(model.receiveContexts == ["connect"])

        await SourceContext.$name.withValue("reload") { await data.reload() }
        #expect(model.refreshContexts == ["reload", "reload"])
        let retry = try #require(data.retryAction)
        SourceContext.$name.withValue("retry") { retry() }
        try #require(await eventually { model.refreshContexts.count == 4 })
        #expect(model.refreshContexts == ["reload", "reload", "retry", "retry"])
        #expect(model.seedContext == "first-read")
    }

    @Test("Rebinding takes the mutator's context, independently of creation and initial connection")
    func rebindContext() async throws {
        let model = SourceContext.$name.withValue("creation") { ContextModel() }
        defer { withExtendedLifetime(model) {} }
        SourceContext.$name.withValue("connect") { model.data.connect() }
        try #require(await eventually { model.producers.count == 1 })
        SourceContext.$name.withValue("mutation") { model.selection = 1 }
        try #require(await eventually { model.producers.count == 2 })
        #expect(model.makeContexts == ["connect", "mutation"])
        SourceContext.$name.withValue("publisher") { model.producers[1].yield(.success(43)) }
        try #require(await eventually { model.data.latestValue == .available(43) })
        #expect(model.receiveContexts == ["mutation"])
    }

    @Test("The testing guide's finite harness keeps reads passive and joins initial work")
    func documentationHarness() async {
        let model = EntriesHarness()
        defer { withExtendedLifetime(model) {} }
        #expect(model.entries.latestValue == .available([1]))
        #expect(model.entries.phase.kind == .success)
        #expect(model.subscriptions == 0)
        model.start()
        #expect(model.subscriptions == 0)
        await model.entries.reload()
        #expect(model.subscriptions == 1)
        #expect(model.entries.latestValue == .available([2]))
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

private enum SourceContext {
    @TaskLocal static var name = "unset"
}

@Observable
private final class ContextModel {
    let creation = SourceContext.name
    var selection = 0
    @ObservationIgnored var seedContext = ""
    @ObservationIgnored var makeContexts: [String] = []
    @ObservationIgnored var receiveContexts: [String] = []
    @ObservationIgnored var refreshContexts: [String] = []
    @ObservationIgnored var producers: [AsyncStream<Result<Int, Never>>.Continuation] = []

    @ViewDataSource(
        id: \.selection,
        initial: { (model: Self) in
            model.seedContext = SourceContext.name
            return .available(1)
        },
        make: { model in model.values() },
        refresh: { model, _ in await model.refresh() },
        receive: { model, result, sink in
            model.receiveContexts.append(SourceContext.name)
            sink.receive(result)
        }
    )
    @ObservationIgnored
    var data: ViewData<Int>

    func values() -> AsyncStream<Result<Int, Never>> {
        makeContexts.append(SourceContext.name)
        let (stream, continuation) = AsyncStream<Result<Int, Never>>.makeStream()
        producers.append(continuation)
        return stream
    }

    func refresh() async {
        refreshContexts.append(SourceContext.name)
        await Task.yield()
        refreshContexts.append(SourceContext.name)
    }
}

@MainActor
private final class EntriesHarness {
    private(set) var subscriptions = 0

    @ViewDataSource(
        initial: { _ in .available([1]) },
        make: { (model: Self) in model.values() }
    )
    var entries: ViewData<[Int]>

    func start() { entries.connect() }

    private func values() -> AsyncStream<Result<[Int], Never>> {
        subscriptions += 1
        return AsyncStream { continuation in
            continuation.yield(.success([2]))
            continuation.finish()
        }
    }
}
