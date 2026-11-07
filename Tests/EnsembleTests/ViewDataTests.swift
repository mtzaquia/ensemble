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

@Suite("View data")
struct ViewDataTests {
    enum TestError: Error {
        case expected
    }

    enum TestUpdate {
        case result(Result<Int, TestError>)
        case reset
    }

    @Test("An initial value starts as successful presentation state")
    func initialValue() {
        let data = ViewData(.available(42))

        #expect(data.isSuccessful)
        #expect(data.latestValue == .available(42))
        #expect(data.phase.kind == .success)
    }

    @Test("Unavailable initialization starts empty and accepts a later value")
    func unavailableInitialValue() {
        let data = ViewData<Int?>(.unavailable)

        #expect(data.isEmpty)
        #expect(data.latestValue == .unavailable)

        data.set(nil)

        #expect(data.isSuccessful)
        #expect(data.latestValue == .available(nil))
    }

    @Test("An available empty collection starts successful")
    func emptyInitialValue() {
        let data = ViewData<[Int]>(.available([]))

        #expect(data.isSuccessful)
        #expect(data.latestValue == .available([]))
    }

    @Test("Phase kind omits the failure's associated error")
    func phaseKind() {
        let data = ViewData<Int>()

        #expect(data.phase.kind == .empty)
        data.beginLoading()
        #expect(data.phase.kind == .loading)
        data.set(42)
        #expect(data.phase.kind == .success)
        data.fail(TestError.expected)
        #expect(data.phase.kind == .failure)
    }

    @Test("Latest-value revisions identify their ViewData instance")
    func latestValueRevisionIdentity() {
        let data = ViewData<Int>()
        let initial = data.latestValueRevision

        #expect(initial == data.latestValueRevision)
        #expect(initial != ViewData<Int>().latestValueRevision)

        data.set(1)
        #expect(data.latestValueRevision == initial)

        data.set(2)
        #expect(data.latestValueRevision != initial)
    }

    @Test("Initial-value construction does not artificially advance the revision")
    func initialValueRevision() {
        let data = ViewData(.available(1))
        let initial = data.latestValueRevision

        data.beginLoading()
        data.set(1)

        #expect(data.latestValueRevision == initial)
    }

    @Test("Internal transitions preserve the latest value while loading and failed")
    func internalTransitions() {
        let data = ViewData<Int>()

        #expect(data.isEmpty)
        #expect(data.latestValue == .unavailable)

        data.set(41)
        #expect(data.isSuccessful)
        #expect(data.latestValue == .available(41))

        data.beginLoading()
        #expect(data.isLoading)
        #expect(data.latestValue == .available(41))

        data.fail(TestError.expected)
        #expect(data.isFailed)
        #expect(data.latestValue == .available(41))

        data.set(42)
        #expect(data.isSuccessful)
        #expect(data.latestValue == .available(42))

        data.reset()
        #expect(data.isEmpty)
        #expect(data.latestValue == .unavailable)
    }

    @Test("An optional nil is an available successful value")
    func optionalNilAvailability() {
        let data = ViewData<Int?>(.available(nil))

        #expect(data.isSuccessful)
        #expect(data.latestValue == .available(nil))

        let loadingToken = data.beginLoading()
        #expect(data.isLoading)
        #expect(data.latestValue == .available(nil))

        data.finishLoading(loadingToken)
        #expect(data.isSuccessful)
        #expect(data.latestValue == .available(nil))

        data.fail(TestError.expected)
        #expect(data.isFailed)
        #expect(data.latestValue == .available(nil))

        data.reset()
        #expect(data.isEmpty)
        #expect(data.latestValue == .unavailable)
    }

    @Test("Unequal replacements advance while successful, loading, or failed")
    func unequalReplacementsAdvanceRevision() {
        let data = ViewData(.available(1))
        let initial = data.latestValueRevision

        data.set(2)
        let successfulReplacement = data.latestValueRevision
        #expect(successfulReplacement != initial)

        data.beginLoading()
        data.set(3)
        let loadingReplacement = data.latestValueRevision
        #expect(loadingReplacement != successfulReplacement)

        data.fail(TestError.expected)
        data.set(4)
        #expect(data.latestValueRevision != loadingReplacement)
    }

    @Test("Equal replacements retain the supplied instance without advancing")
    func equalReplacementDoesNotAdvanceRevision() {
        final class Model: Equatable {
            let id: Int

            init(id: Int) {
                self.id = id
            }

            static func == (lhs: Model, rhs: Model) -> Bool {
                lhs.id == rhs.id
            }
        }

        let initial = Model(id: 42)
        let replacement = Model(id: 42)
        let data = ViewData(.available(initial))
        let latestValueRevision = data.latestValueRevision
        let presentationRevision = data.presentationRevision
        let observation = ViewDataPresentationObservation(data)
        observation.start()

        data.set(replacement)

        #expect(observation.cycles == 1)
        #expect(data.latestValueRevision == latestValueRevision)
        #expect(data.presentationRevision != presentationRevision)
        if case .available(let latest) = data.latestValue {
            #expect(latest === replacement)
        } else {
            Issue.record("Expected the equivalent replacement to remain available")
        }
    }

    @Test("Equal recovery from loading or failure does not advance")
    func equalRecoveryDoesNotAdvanceRevision() {
        let data = ViewData(.available(42))
        let initial = data.latestValueRevision

        data.beginLoading()
        data.set(42)
        #expect(data.isSuccessful)
        #expect(data.latestValueRevision == initial)

        data.fail(TestError.expected)
        data.set(42)
        #expect(data.isSuccessful)
        #expect(data.latestValueRevision == initial)
    }

    @Test("Lifecycle, failure, retry, and finish-loading changes do not advance")
    func lifecycleDoesNotAdvanceRevision() {
        let data = ViewData(.available(42))
        let initial = data.latestValueRevision

        let token = data.beginLoading()
        #expect(data.latestValueRevision == initial)
        data.finishLoading(token)
        #expect(data.latestValueRevision == initial)
        data.fail(TestError.expected)
        #expect(data.latestValueRevision == initial)
        data.fail(TestError.expected)
        #expect(data.latestValueRevision == initial)
        data.installRetryAction(ViewDataRetryAction {})
        #expect(data.latestValueRevision == initial)
        data.removeRetryAction()
        #expect(data.latestValueRevision == initial)
    }

    @Test("Reset and the first value after reset do not advance")
    func resetDoesNotAdvanceRevision() {
        let data = ViewData(.available(1))
        data.set(2)
        let changed = data.latestValueRevision

        data.reset()
        #expect(data.latestValueRevision == changed)
        data.set(3)
        #expect(data.latestValueRevision == changed)
        data.set(4)
        #expect(data.latestValueRevision != changed)
    }

    @Test("Available optional nil follows equality semantics")
    func optionalNilRevision() {
        let data = ViewData<Int?>(.available(nil))
        let initial = data.latestValueRevision

        data.set(nil)
        #expect(data.latestValueRevision == initial)
        data.set(1)
        let nonNil = data.latestValueRevision
        #expect(nonNil != initial)
        data.set(nil)
        #expect(data.latestValueRevision != nonNil)
    }

    @Test("Non-equatable values advance only after their first success")
    func nonEquatableRevision() {
        struct Value {}
        let data = ViewData<Value>()
        let initial = data.latestValueRevision

        data.set(Value())
        #expect(data.latestValueRevision == initial)
        data.set(Value())
        #expect(data.latestValueRevision != initial)
    }

    @Test("A successful update invalidates presentation coherently")
    func successfulUpdateIsCoherent() {
        let data = ViewData(.available([1, 2, 3]))
        let initialLatestValueRevision = data.latestValueRevision
        let initialPresentationRevision = data.presentationRevision
        let observation = ViewDataPresentationObservation(data)

        observation.start()
        data.set([3, 2, 1])

        #expect(observation.cycles == 1)
        #expect(data.isSuccessful)
        #expect(data.latestValue == .available([3, 2, 1]))
        #expect(data.latestValueRevision != initialLatestValueRevision)
        #expect(data.presentationRevision != initialPresentationRevision)
    }

    @Test("Every accepted presentation transition invalidates once")
    func presentationTransitionsAreCoherent() {
        let data = ViewData<Int>()
        let observation = ViewDataPresentationObservation(data)
        observation.start()

        let emptyLoading = data.beginLoading()
        #expect(observation.cycles == 1)
        data.finishLoading(emptyLoading)
        #expect(observation.cycles == 2)

        data.set(42)
        #expect(observation.cycles == 3)
        let retainedLoading = data.beginLoading()
        #expect(observation.cycles == 4)
        data.finishLoading(retainedLoading)
        #expect(observation.cycles == 5)

        data.fail(TestError.expected)
        #expect(observation.cycles == 6)
        let failedLoading = data.beginLoading()
        #expect(observation.cycles == 7)
        data.finishLoading(failedLoading)
        #expect(observation.cycles == 8)

        data.installRetryAction(ViewDataRetryAction {})
        #expect(observation.cycles == 9)
        data.removeRetryAction()
        #expect(observation.cycles == 10)

        data.reset()
        #expect(observation.cycles == 11)
    }

    @Test("A failure result does not end the subscription")
    func sourceCanRecoverAfterFailure() async {
        let (stream, continuation) = AsyncStream<Result<Int, TestError>>.makeStream()

        let dataFixture = SourceFixture<Int, _>(make: { stream })
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        #expect(await eventually { data.binding?.isConnected == true })
        #expect(data.isLoading)

        continuation.yield(.failure(.expected))
        #expect(await eventually { data.isFailed })

        continuation.yield(.success(42))
        #expect(await eventually { data.isSuccessful && data.latestValue == .available(42) })

        continuation.finish()
    }

    @Test("Bindings accept transformed asynchronous sequences")
    func transformedSequence() async {
        let (stream, continuation) = AsyncStream<Int>.makeStream()

        let dataFixture = SourceFixture<Int, _>(make: {
            stream.map { Result<Int, TestError>.success($0) }
        })
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        #expect(await eventually { data.binding?.isConnected == true })

        continuation.yield(42)
        #expect(await eventually { data.isSuccessful && data.latestValue == .available(42) })

        continuation.finish()
    }

    @Test("A sequence iteration error enters failure")
    func throwingSequence() async {
        let (stream, continuation) =
            AsyncThrowingStream<Result<Int, TestError>, any Error>.makeStream()

        let dataFixture = SourceFixture<Int, _>(make: { stream })
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        #expect(await eventually { data.binding?.isConnected == true })
        continuation.finish(throwing: TestError.expected)

        #expect(await eventually { data.isFailed })
    }

    @Test("Source cancellation settles loading and permits refresh", arguments: [
        ViewData<Int>.Phase.Kind.empty, .success, .failure,
    ])
    func sourceCancellationCanRefresh(initialState: ViewData<Int>.Phase.Kind) async {
        var continuations: [AsyncThrowingStream<Result<Int, TestError>, any Error>.Continuation] = []

        let dataFixture = SourceFixture<Int, _>(make: {
            let (stream, continuation) =
                AsyncThrowingStream<Result<Int, TestError>, any Error>.makeStream()
            continuations.append(continuation)
            return stream
        }, refresh: {
            continuations.last?.yield(.success(42))
        })
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        if initialState == .success { data.set(41) }
        if initialState == .failure { data.fail(TestError.expected) }
        #expect(await eventually { data.binding?.isConnected == true })

        continuations[0].finish(throwing: CancellationError())
        #expect(await eventually { data.binding?.isRunning == false && data.phase.kind == initialState })
        #expect(data.latestValue == (initialState == .success ? .available(41) : .unavailable))

        await data.reload()
        #expect(continuations.count == 2)
        #expect(data.isLoading)
        #expect(await eventually { data.latestValue == .available(42) && data.isSuccessful })
        continuations.last?.finish()
    }

    @Test("Custom element handling can reset without ending the binding")
    func customElementsResetPresentation() async {
        let (stream, continuation) =
            AsyncStream<TestUpdate>.makeStream()

        let dataFixture = SourceFixture<Int, _>(make: { stream }) { _, update, sink in
            switch update {
            case .result(let result):
                sink.receive(result)
            case .reset:
                sink.reset()
            }
        }
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        #expect(await eventually { data.binding?.isConnected == true })
        #expect(data.isLoading)
        #expect(data.retryAction != nil)

        continuation.yield(.result(.success(42)))
        #expect(await eventually { data.isSuccessful && data.latestValue == .available(42) })

        continuation.yield(.reset)
        #expect(await eventually { data.isEmpty && data.latestValue == .unavailable })
        #expect(data.retryAction != nil)

        continuation.yield(.result(.success(43)))
        #expect(await eventually { data.isSuccessful && data.latestValue == .available(43) })

        continuation.finish()
    }

    @Test("A retained sink ignores updates after its factory input changes")
    func staleSink() async throws {
        let (firstStream, firstContinuation) = AsyncStream<TestUpdate>.makeStream()
        let (secondStream, secondContinuation) =
            AsyncStream<TestUpdate>.makeStream()
        var retainedSink: ViewDataSink<Int>?

        let dataFixture = SourceFixture<Int, _>(make: { firstStream }) { _, update, sink in
            retainedSink = sink
            if case .result(let result) = update {
                sink.receive(result)
            }
        }
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        #expect(await eventually { data.binding?.isConnected == true })
        firstContinuation.yield(.result(.success(41)))
        #expect(await eventually { retainedSink != nil && data.latestValue == .available(41) })

        let sink = try #require(retainedSink)
        dataFixture.factory = { secondStream }
        secondContinuation.yield(.result(.success(42)))
        #expect(await eventually { data.isSuccessful && data.latestValue == .available(42) })

        sink.receive(Result<Int, TestError>.success(99))
        sink.reset()
        #expect(data.isSuccessful)
        #expect(data.latestValue == .available(42))

        firstContinuation.finish()
        secondContinuation.finish()
    }

    @Test("A load and binding update the same destination in arrival order")
    func loadAndBindingWorkInTandem() async {
        let (source, sourceContinuation) =
            AsyncStream<Result<Int, TestError>>.makeStream()
        let (loadValues, loadContinuation) = AsyncStream<Int>.makeStream()

        let dataFixture = SourceFixture<Int, _>(make: { source })
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        #expect(await eventually { data.binding?.isConnected == true })
        let loadTask = Task {
            await data.load({
                for await value in loadValues {
                    return value
                }
                throw TestError.expected
            })
        }

        #expect(await eventually { data.isLoading })

        sourceContinuation.yield(.success(1))
        #expect(await eventually { data.isSuccessful && data.latestValue == .available(1) })

        loadContinuation.yield(2)
        loadContinuation.finish()
        await loadTask.value
        #expect(data.isSuccessful)
        #expect(data.latestValue == .available(2))
        #expect(data.retryAction != nil)

        sourceContinuation.yield(.success(3))
        #expect(await eventually { data.isSuccessful && data.latestValue == .available(3) })

        sourceContinuation.finish()
    }

    @Test("A load presents failure while preserving the latest value")
    func loadFailure() async {
        let data = ViewData(.available(41))

        await data.load({ () async throws -> Int in
            throw TestError.expected
        })

        #expect(data.isFailed)
        #expect(data.latestValue == .available(41))
    }

    @Test("Cancelling a load does not replace a later bound result")
    func loadCancellationPreservesLaterUpdate() async {
        let (source, continuation) = AsyncStream<Result<Int, TestError>>.makeStream()

        let dataFixture = SourceFixture<Int, _>(make: { source })
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        #expect(await eventually { data.binding?.isConnected == true })
        let loadTask = Task {
            await data.load({
                try await Task.sleep(for: .seconds(60))
                return 1
            })
        }

        #expect(await eventually { data.isLoading })
        continuation.yield(.success(42))
        #expect(await eventually { data.isSuccessful && data.latestValue == .available(42) })

        loadTask.cancel()
        await loadTask.value
        #expect(data.isSuccessful)
        #expect(data.latestValue == .available(42))

        continuation.finish()
    }

    @Test("Reset clears presentation without cancelling a binding")
    func resetPreservesBinding() async {
        let (source, continuation) = AsyncStream<Result<Int, TestError>>.makeStream()

        let dataFixture = SourceFixture<Int, _>(.available(41), make: { source })
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        #expect(await eventually { data.binding?.isConnected == true })
        data.reset()
        #expect(data.isEmpty)
        #expect(data.latestValue == .unavailable)

        continuation.yield(.success(42))
        #expect(await eventually { data.isSuccessful && data.latestValue == .available(42) })

        continuation.finish()
    }

    @Test("Retry creates a fresh subscription and ignores the replaced source")
    func retryResubscribes() async throws {
        var continuations: [AsyncStream<Result<Int, TestError>>.Continuation] = []

        let dataFixture = SourceFixture<Int, _>(make: {
            let (stream, continuation) = AsyncStream<Result<Int, TestError>>.makeStream()
            continuations.append(continuation)
            return stream
        })
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        #expect(await eventually { data.binding?.isConnected == true })

        #expect(continuations.count == 1)
        continuations[0].yield(.failure(.expected))
        #expect(await eventually { data.isFailed })

        let retry = try #require(data.retryAction)
        retry()

        #expect(await eventually { continuations.count == 2 && data.isLoading })
        continuations[1].yield(.success(42))
        #expect(await eventually { data.isSuccessful && data.latestValue == .available(42) })

        continuations[0].yield(.success(1))
        await Task.yield()
        #expect(data.latestValue == .available(42))

        continuations[1].finish()
    }

    @Test("A retry that completes without a result restores its failure")
    func emptyRetryRestoresFailure() async throws {
        var continuations: [AsyncStream<Result<Int, TestError>>.Continuation] = []

        let dataFixture = SourceFixture<Int, _>(make: {
            let (stream, continuation) = AsyncStream<Result<Int, TestError>>.makeStream()
            continuations.append(continuation)
            return stream
        })
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        #expect(await eventually { data.binding?.isConnected == true })

        continuations[0].yield(.failure(.expected))
        #expect(await eventually { data.isFailed })

        let retry = try #require(data.retryAction)
        retry()
        #expect(await eventually { continuations.count == 2 && data.isLoading })

        continuations[1].finish()
        #expect(await eventually { data.isFailed })
    }

    @Test("Programmatic reload resubscribes by default")
    func reloadResubscribes() async {
        var continuations: [AsyncStream<Result<Int, TestError>>.Continuation] = []

        let dataFixture = SourceFixture<Int, _>(make: {
            let (stream, continuation) = AsyncStream<Result<Int, TestError>>.makeStream()
            continuations.append(continuation)
            return stream
        })
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        #expect(await eventually { data.binding?.isConnected == true })

        #expect(continuations.count == 1)
        continuations[0].yield(.success(41))
        #expect(await eventually { data.latestValue == .available(41) })
        let reload = Task { await data.reload() }
        #expect(await eventually { continuations.count == 2 })
        #expect(data.isLoading)

        continuations[1].yield(.success(42))
        #expect(await eventually { data.isSuccessful && data.latestValue == .available(42) })

        continuations[0].yield(.success(1))
        await Task.yield()
        #expect(data.latestValue == .available(42))

        continuations[1].finish()
        await reload.value
    }

    @Test("Refresh reload keeps an active subscription")
    func reloadRefreshesActiveSource() async throws {
        let (stream, continuation) = AsyncStream<Result<Int, TestError>>.makeStream()
        var sourceCount = 0
        var refreshCount = 0

        let dataFixture = SourceFixture<Int, _>(make: {
            sourceCount += 1
            return stream
        }, refresh: {
            refreshCount += 1
            continuation.yield(.success(refreshCount))
        })
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        #expect(await eventually { data.binding?.isConnected == true })

        await data.reload()
        #expect(data.isLoading)
        #expect(sourceCount == 1)
        #expect(refreshCount == 1)
        #expect(await eventually { data.isSuccessful && data.latestValue == .available(1) })

        continuation.yield(.failure(.expected))
        #expect(await eventually { data.isFailed })

        let retry = try #require(data.retryAction)
        retry()
        #expect(await eventually { refreshCount == 2 })
        #expect(sourceCount == 1)
        #expect(await eventually { data.isSuccessful && data.latestValue == .available(2) })

        continuation.finish()
    }

    @Test("Refresh reload reattaches after source completion")
    func reloadRefreshesCompletedSource() async {
        var continuations: [AsyncStream<Result<Int, TestError>>.Continuation] = []

        let dataFixture = SourceFixture<Int, _>(make: {
            let (stream, continuation) = AsyncStream<Result<Int, TestError>>.makeStream()
            continuations.append(continuation)
            return stream
        }, refresh: {
            continuations.last?.yield(.success(42))
        })
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        #expect(await eventually { data.binding?.isConnected == true })

        continuations[0].finish()
        #expect(await eventually { data.binding?.isRunning == false && data.isEmpty })

        await data.reload()
        #expect(continuations.count == 2)
        #expect(data.isLoading)
        #expect(await eventually { data.isSuccessful && data.latestValue == .available(42) })

        continuations[1].finish()
    }

    @Test("Disabled reload exposes no retry action")
    func disabledReload() async {
        let (stream, continuation) = AsyncStream<Result<Int, TestError>>.makeStream()
        var sourceCount = 0

        let dataFixture = SourceFixture<Int, _>(make: {
            sourceCount += 1
            return stream
        }, allowsReload: false) { _, result, sink in sink.receive(result) }
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        #expect(await eventually { data.binding?.isConnected == true })

        #expect(data.retryAction == nil)
        continuation.yield(.failure(.expected))
        #expect(await eventually { data.isFailed })

        await data.reload()
        #expect(sourceCount == 1)
        #expect(data.isFailed)
        #expect(data.retryAction == nil)

        continuation.finish()
    }

    @Test("Owner release removes retry without changing the latest-value revision")
    func ownerReleasePreservesLatestValueRevision() async {
        let (stream, continuation) = AsyncStream<Result<Int, TestError>>.makeStream()
        var fixture: SourceFixture<Int, _>? = SourceFixture(make: { stream })
        let data = fixture!.data
        #expect(await eventually { data.binding?.isConnected == true })
        continuation.yield(.failure(.expected))
        #expect(await eventually { data.isFailed && data.retryAction != nil })
        let revision = data.latestValueRevision
        fixture = nil
        #expect(data.isFailed)
        #expect(data.retryAction == nil)
        #expect(data.latestValueRevision == revision)
    }

    @Test("Owner release settles cold loading and disarms reload and retained retry")
    func cancel() async throws {
        var connections = 0
        var fixture: SourceFixture<Int, _>? = SourceFixture(make: {
            connections += 1
            return AsyncStream<Result<Int, TestError>> { _ in }
        })
        let data = fixture!.data
        #expect(await eventually { data.isLoading })
        let staleRetry = try #require(data.retryAction)
        fixture = nil
        #expect(data.isEmpty)
        #expect(data.retryAction == nil)
        staleRetry()
        await data.reload()
        #expect(connections == 1)
        #expect(data.binding?.isConnected == false)
    }

    @Test("Cold cancellation invalidates retained sinks and keeps factory-input tracking")
    func cancelledConnectionStaysObsolete() async throws {
        var producers: [AsyncStream<Int>.Continuation] = []
        var sinks: [ViewDataSink<Int>] = []
        let make: @MainActor () -> AsyncStream<Int> = {
            let (stream, continuation) = AsyncStream<Int>.makeStream()
            producers.append(continuation)
            return stream
        }
        let fixture = SourceFixture<Int, _>(make: make) { _, value, sink in
            sinks.append(sink)
            sink.receive(Result<Int, TestError>.success(value))
        }
        defer { withExtendedLifetime(fixture) {} }
        let data = fixture.data
        #expect(await eventually { producers.count == 1 })
        producers[0].yield(1)
        #expect(await eventually { data.latestValue == .available(1) })
        let reload = Task { await data.reload() }
        #expect(await eventually { producers.count == 2 })
        producers[1].yield(2)
        #expect(await eventually { data.latestValue == .available(2) })
        let cancelledSink = try #require(sinks.last)
        reload.cancel()
        await reload.value
        cancelledSink.reset()
        cancelledSink.receive(Result<Int, TestError>.success(99))
        #expect(data.latestValue == .available(2))
        fixture.factory = make
        #expect(await eventually { producers.count == 3 })
        producers[2].yield(3)
        #expect(await eventually { data.latestValue == .available(3) })
    }

    @Test("Owner teardown cannot settle a newer one-shot loading transition")
    func bindingCancellationPreservesLoad() async {
        var fixture: SourceFixture<Int, _>? = SourceFixture(make: {
            AsyncStream<Result<Int, TestError>> { _ in }
        })
        let data = fixture!.data
        #expect(await eventually { data.binding?.isConnected == true })
        var loadStarted = false
        let load = Task {
            await data.load {
                loadStarted = true
                try await Task.sleep(for: .seconds(60))
                return 42
            }
        }
        #expect(await eventually { loadStarted })
        fixture = nil
        #expect(data.isLoading)
        load.cancel()
        await load.value
        #expect(data.isEmpty)
    }

    @Test("A source that completes without another result restores retained success")
    func emptyRefreshPreservesSuccess() async {
        let (stream, continuation) = AsyncStream<Result<Int, TestError>>.makeStream()

        let dataFixture = SourceFixture<Int, _>(.available(42), make: { stream })
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        #expect(await eventually { data.binding?.isConnected == true })
        continuation.finish()

        #expect(await eventually { data.isSuccessful })
        #expect(data.latestValue == .available(42))
    }

    @Test("Rebinding disables old sinks and retries while keeping the same model-owned state")
    func rebindingConnection() async throws {
        let (oldSource, oldProducer) = AsyncStream<TestUpdate>.makeStream()
        var oldSink: ViewDataSink<Int>?
        var oldConnections = 0
        let dataFixture = SourceFixture<Int, _>(make: {
            oldConnections += 1
            return oldSource
        }) { _, update, sink in
            oldSink = sink
            if case .result(let result) = update { sink.receive(result) }
        }
        defer { withExtendedLifetime(dataFixture) {} }
        let data = dataFixture.data
        #expect(await eventually { data.binding?.isConnected == true })
        oldProducer.yield(.result(.success(1)))
        #expect(await eventually { data.latestValue == .available(1) })
        let retry = try #require(data.retryAction)
        let sink = try #require(oldSink)
        var newProducers: [AsyncStream<TestUpdate>.Continuation] = []
        dataFixture.factory = {
            let (stream, continuation) = AsyncStream<TestUpdate>.makeStream()
            newProducers.append(continuation)
            return stream
        }
        try #require(await eventually { newProducers.count == 1 })
        #expect(data.binding?.isConnected == true)
        #expect(data.latestValue == .available(1))
        #expect(await eventually {
            if case .terminated = oldProducer.yield(.reset) { return true }
            return false
        })
        retry()
        sink.receive(Result<Int, TestError>.success(99))
        sink.reset()
        #expect(oldConnections == 1)
        #expect(data.latestValue == .available(1))
        newProducers[0].yield(.result(.success(2)))
        #expect(await eventually { data.latestValue == .available(2) })
        let reload = Task { await data.reload() }
        #expect(await eventually { newProducers.count == 2 })
        newProducers[1].yield(.result(.success(3)))
        newProducers[1].finish()
        await reload.value
        #expect(data.latestValue == .available(3))
    }

    @Test("A source skips callbacks after its owning model is released")
    func sourceCaptureReleasesOwner() async {
        var owner: CaptureOwner? = CaptureOwner()
        weak var weakOwner: CaptureOwner?
        weakOwner = owner
        let data = owner!.entries
        let producer = owner!.source.continuation
        #expect(await eventually { data.binding?.isConnected == true })
        owner = nil
        #expect(weakOwner == nil)
        producer.yield(.success(42))
        producer.finish()
        #expect(await eventually { data.binding?.isRunning == false })
        #expect(data.latestValue == .unavailable)
        #expect(data.retryAction == nil)
    }

    @Test("Releasing the model releases its data, binding, and source captures")
    func bindingDeallocation() async {
        weak var weakData: ViewData<Int>?
        weak var weakBinding: ViewDataBinding<Int>?
        weak var weakSource: CaptureSource?
        let producer: AsyncStream<Result<Int, TestError>>.Continuation
        do {
            let source = CaptureSource()
            weakSource = source
            producer = source.continuation
            let dataFixture = SourceFixture(make: source.values, refresh: {})
            defer { withExtendedLifetime(dataFixture) {} }
            let data = dataFixture.data
            weakData = data
            weakBinding = data.binding
            #expect(await eventually { data.binding?.isConnected == true })
            #expect(data.retryAction != nil)
        }
        #expect(weakData == nil)
        #expect(weakBinding == nil)
        #expect(weakSource == nil)
        #expect(await eventually {
            if case .terminated = producer.yield(.success(99)) { return true }
            return false
        })
    }
}

@MainActor
private final class ViewDataPresentationObservation<Value> {
    let data: ViewData<Value>
    private(set) var cycles = 0

    init(_ data: ViewData<Value>) {
        self.data = data
    }

    func start() {
        withObservationTracking {
            _ = data.phase
            _ = data.latestValue
            _ = data.latestValueRevision
            _ = data.presentationRevision
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cycles += 1
                self.start()
            }
        }
    }
}

private extension ViewData {
    var isEmpty: Bool {
        if case .empty = phase { true } else { false }
    }

    var isLoading: Bool {
        if case .loading = phase { true } else { false }
    }

    var isSuccessful: Bool {
        if case .success = phase { true } else { false }
    }

    var isFailed: Bool {
        if case .failure = phase { true } else { false }
    }
}

private func eventually(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if predicate() { return true }
        await Task.yield()
    }
    return predicate()
}

private final class CaptureSource {
    let stream: AsyncStream<Result<Int, ViewDataTests.TestError>>
    let continuation: AsyncStream<Result<Int, ViewDataTests.TestError>>.Continuation

    init() { (stream, continuation) = AsyncStream.makeStream() }
    func values() -> AsyncStream<Result<Int, ViewDataTests.TestError>> { stream }
}

private final class CaptureOwner {
    let source = CaptureSource()
    @ViewDataSource(make: { (model: Self) in model.source.values() })
    var entries: ViewData<Int>
}
