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
        let data = ViewData(42)

        #expect(data.isSuccessful)
        #expect(data.latest == 42)
    }

    @Test("Internal transitions preserve the latest value while loading and failed")
    func internalTransitions() {
        let data = ViewData<Int>()

        #expect(data.isEmpty)
        #expect(data.latest == nil)

        data.set(41)
        #expect(data.isSuccessful)
        #expect(data.latest == 41)

        data.beginLoading()
        #expect(data.isLoading)
        #expect(data.latest == 41)

        data.fail(TestError.expected)
        #expect(data.isFailed)
        #expect(data.latest == 41)

        data.set(42)
        #expect(data.isSuccessful)
        #expect(data.latest == 42)

        data.reset()
        #expect(data.isEmpty)
        #expect(data.latest == nil)
    }

    @Test("Animation values identify their source and every accepted transition")
    func animationValues() {
        struct NonEquatable {}

        let data = ViewData<NonEquatable>()
        let empty = data.animationValue
        #expect(empty == data.animationValue)
        #expect(empty != ViewData<NonEquatable>().animationValue)

        data.beginLoading()
        let loading = data.animationValue
        #expect(empty != loading)

        data.set(NonEquatable())
        let success = data.animationValue
        #expect(loading != success)

        data.beginLoading()
        let cachedLoading = data.animationValue
        #expect(success != cachedLoading)

        data.fail(TestError.expected)
        let cachedFailure = data.animationValue
        #expect(cachedLoading != cachedFailure)

        data.set(NonEquatable())
        let replacement = data.animationValue
        #expect(cachedFailure != replacement)

        data.reset()
        let reset = data.animationValue
        #expect(replacement != reset)

        data.fail(TestError.expected)
        let failure = data.animationValue
        #expect(reset != failure)

        data.fail(TestError.expected)
        let repeatedFailure = data.animationValue
        #expect(failure != repeatedFailure)
    }

    @Test("A failure result does not end the subscription")
    func sourceCanRecoverAfterFailure() async {
        let (stream, continuation) = AsyncStream<Result<Int, TestError>>.makeStream()
        let data = ViewData<Int>()
        let context = ViewDataContext()

        context.bind({ stream }, to: data)
        #expect(data.isLoading)

        continuation.yield(.failure(.expected))
        #expect(await eventually { data.isFailed })

        continuation.yield(.success(42))
        #expect(await eventually { data.isSuccessful && data.latest == 42 })

        continuation.finish()
    }

    @Test("Bindings accept transformed asynchronous sequences")
    func transformedSequence() async {
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        let data = ViewData<Int>()
        let context = ViewDataContext()

        context.bind({
            stream.map { Result<Int, TestError>.success($0) }
        }, to: data)

        continuation.yield(42)
        #expect(await eventually { data.isSuccessful && data.latest == 42 })

        continuation.finish()
    }

    @Test("A sequence iteration error enters failure")
    func throwingSequence() async {
        let (stream, continuation) =
            AsyncThrowingStream<Result<Int, TestError>, any Error>.makeStream()
        let data = ViewData<Int>()
        let context = ViewDataContext()

        context.bind({ stream }, to: data)
        continuation.finish(throwing: TestError.expected)

        #expect(await eventually { data.isFailed })
    }

    @Test("Custom element handling can reset without ending the binding")
    func customElementsResetPresentation() async {
        let (stream, continuation) =
            AsyncStream<TestUpdate>.makeStream()
        let data = ViewData<Int>()
        let context = ViewDataContext()

        context.bind({ stream }, to: data) { update, sink in
            switch update {
            case .result(let result):
                sink.receive(result)
            case .reset:
                sink.reset()
            }
        }
        #expect(data.isLoading)
        #expect(data.retryAction != nil)

        continuation.yield(.result(.success(42)))
        #expect(await eventually { data.isSuccessful && data.latest == 42 })

        continuation.yield(.reset)
        #expect(await eventually { data.isEmpty && data.latest == nil })
        #expect(data.retryAction != nil)

        continuation.yield(.result(.success(43)))
        #expect(await eventually { data.isSuccessful && data.latest == 43 })

        continuation.finish()
    }

    @Test("A retained sink ignores updates after its binding is replaced")
    func staleSink() async throws {
        let (firstStream, firstContinuation) = AsyncStream<TestUpdate>.makeStream()
        let (secondStream, secondContinuation) =
            AsyncStream<Result<Int, TestError>>.makeStream()
        let data = ViewData<Int>()
        let context = ViewDataContext()
        var retainedSink: ViewDataSink<Int>?

        context.bind({ firstStream }, to: data) { update, sink in
            retainedSink = sink
            if case .result(let result) = update {
                sink.receive(result)
            }
        }
        firstContinuation.yield(.result(.success(41)))
        #expect(await eventually { retainedSink != nil && data.latest == 41 })

        context.bind({ secondStream }, to: data)
        secondContinuation.yield(.success(42))
        #expect(await eventually { data.isSuccessful && data.latest == 42 })

        let sink = try #require(retainedSink)
        sink.receive(Result<Int, TestError>.success(99))
        sink.reset()
        #expect(data.isSuccessful)
        #expect(data.latest == 42)

        firstContinuation.finish()
        secondContinuation.finish()
    }

    @Test("A load and binding update the same destination in arrival order")
    func loadAndBindingWorkInTandem() async {
        let (source, sourceContinuation) =
            AsyncStream<Result<Int, TestError>>.makeStream()
        let (loadValues, loadContinuation) = AsyncStream<Int>.makeStream()
        let data = ViewData<Int>()
        let context = ViewDataContext()

        context.bind({ source }, to: data)
        let loadTask = Task {
            await context.load({
                for await value in loadValues {
                    return value
                }
                throw TestError.expected
            }, to: data)
        }

        #expect(await eventually { data.isLoading })

        sourceContinuation.yield(.success(1))
        #expect(await eventually { data.isSuccessful && data.latest == 1 })

        loadContinuation.yield(2)
        loadContinuation.finish()
        await loadTask.value
        #expect(data.isSuccessful)
        #expect(data.latest == 2)
        #expect(data.retryAction != nil)

        sourceContinuation.yield(.success(3))
        #expect(await eventually { data.isSuccessful && data.latest == 3 })

        sourceContinuation.finish()
    }

    @Test("A load presents failure while preserving the latest value")
    func loadFailure() async {
        let data = ViewData(41)
        let context = ViewDataContext()

        await context.load({ () async throws -> Int in
            throw TestError.expected
        }, to: data)

        #expect(data.isFailed)
        #expect(data.latest == 41)
    }

    @Test("Cancelling a load does not replace a later bound result")
    func loadCancellationPreservesLaterUpdate() async {
        let (source, continuation) = AsyncStream<Result<Int, TestError>>.makeStream()
        let data = ViewData<Int>()
        let context = ViewDataContext()

        context.bind({ source }, to: data)
        let loadTask = Task {
            await context.load({
                try await Task.sleep(for: .seconds(60))
                return 1
            }, to: data)
        }

        #expect(await eventually { data.isLoading })
        continuation.yield(.success(42))
        #expect(await eventually { data.isSuccessful && data.latest == 42 })

        loadTask.cancel()
        await loadTask.value
        #expect(data.isSuccessful)
        #expect(data.latest == 42)

        continuation.finish()
    }

    @Test("Reset clears presentation without cancelling a binding")
    func resetPreservesBinding() async {
        let (source, continuation) = AsyncStream<Result<Int, TestError>>.makeStream()
        let data = ViewData(41)
        let context = ViewDataContext()

        context.bind({ source }, to: data)
        data.reset()
        #expect(data.isEmpty)
        #expect(data.latest == nil)

        continuation.yield(.success(42))
        #expect(await eventually { data.isSuccessful && data.latest == 42 })

        continuation.finish()
    }

    @Test("Retry creates a fresh subscription and ignores the replaced source")
    func retryResubscribes() async throws {
        var continuations: [AsyncStream<Result<Int, TestError>>.Continuation] = []
        let data = ViewData<Int>()
        let context = ViewDataContext()

        context.bind({
            let (stream, continuation) = AsyncStream<Result<Int, TestError>>.makeStream()
            continuations.append(continuation)
            return stream
        }, to: data)

        #expect(continuations.count == 1)
        continuations[0].yield(.failure(.expected))
        #expect(await eventually { data.isFailed })

        let retry = try #require(data.retryAction)
        retry()

        #expect(await eventually { continuations.count == 2 && data.isLoading })
        continuations[1].yield(.success(42))
        #expect(await eventually { data.isSuccessful && data.latest == 42 })

        continuations[0].yield(.success(1))
        await Task.yield()
        #expect(data.latest == 42)

        continuations[1].finish()
    }

    @Test("A retry that completes without a result restores its failure")
    func emptyRetryRestoresFailure() async throws {
        var continuations: [AsyncStream<Result<Int, TestError>>.Continuation] = []
        let data = ViewData<Int>()
        let context = ViewDataContext()

        context.bind({
            let (stream, continuation) = AsyncStream<Result<Int, TestError>>.makeStream()
            continuations.append(continuation)
            return stream
        }, to: data)

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
        let data = ViewData<Int>()
        let context = ViewDataContext()

        context.bind({
            let (stream, continuation) = AsyncStream<Result<Int, TestError>>.makeStream()
            continuations.append(continuation)
            return stream
        }, to: data)

        #expect(continuations.count == 1)
        context.reload(data)
        #expect(continuations.count == 2)
        #expect(data.isLoading)

        continuations[1].yield(.success(42))
        #expect(await eventually { data.isSuccessful && data.latest == 42 })

        continuations[0].yield(.success(1))
        await Task.yield()
        #expect(data.latest == 42)

        continuations[1].finish()
    }

    @Test("Refresh reload keeps an active subscription")
    func reloadRefreshesActiveSource() async throws {
        let (stream, continuation) = AsyncStream<Result<Int, TestError>>.makeStream()
        var sourceCount = 0
        var refreshCount = 0
        let data = ViewData<Int>()
        let context = ViewDataContext()

        context.bind({
            sourceCount += 1
            return stream
        }, to: data, reload: .refresh {
            refreshCount += 1
            continuation.yield(.success(refreshCount))
        })

        context.reload(data)
        #expect(data.isLoading)
        #expect(sourceCount == 1)
        #expect(refreshCount == 1)
        #expect(await eventually { data.isSuccessful && data.latest == 1 })

        continuation.yield(.failure(.expected))
        #expect(await eventually { data.isFailed })

        let retry = try #require(data.retryAction)
        retry()
        #expect(data.isLoading)
        #expect(sourceCount == 1)
        #expect(refreshCount == 2)
        #expect(await eventually { data.isSuccessful && data.latest == 2 })

        continuation.finish()
    }

    @Test("Refresh reload reattaches after source completion")
    func reloadRefreshesCompletedSource() async {
        var continuations: [AsyncStream<Result<Int, TestError>>.Continuation] = []
        let data = ViewData<Int>()
        let context = ViewDataContext()

        context.bind({
            let (stream, continuation) = AsyncStream<Result<Int, TestError>>.makeStream()
            continuations.append(continuation)
            return stream
        }, to: data, reload: .refresh {
            continuations.last?.yield(.success(42))
        })

        continuations[0].finish()
        #expect(await eventually { data.isEmpty })

        context.reload(data)
        #expect(continuations.count == 2)
        #expect(data.isLoading)
        #expect(await eventually { data.isSuccessful && data.latest == 42 })

        continuations[1].finish()
    }

    @Test("Disabled reload exposes no retry action")
    func disabledReload() async {
        let (stream, continuation) = AsyncStream<Result<Int, TestError>>.makeStream()
        var sourceCount = 0
        let data = ViewData<Int>()
        let context = ViewDataContext()

        context.bind({
            sourceCount += 1
            return stream
        }, to: data, reload: .disabled)

        #expect(data.retryAction == nil)
        continuation.yield(.failure(.expected))
        #expect(await eventually { data.isFailed })

        context.reload(data)
        #expect(sourceCount == 1)
        #expect(data.isFailed)
        #expect(data.retryAction == nil)

        continuation.finish()
    }

    @Test("Removing retry availability advances presentation while failure remains")
    func cancellingFailedBindingAdvancesPresentation() async {
        let (stream, continuation) = AsyncStream<Result<Int, TestError>>.makeStream()
        let data = ViewData<Int>()
        let context = ViewDataContext()

        context.bind({ stream }, to: data)
        continuation.yield(.failure(.expected))
        #expect(await eventually { data.isFailed && data.retryAction != nil })
        let retryableFailure = data.animationValue

        context.cancel(data)

        #expect(data.isFailed)
        #expect(data.retryAction == nil)
        #expect(data.animationValue != retryableFailure)
        continuation.finish()
    }

    @Test("Cancelling removes retry and finishes the loading phase")
    func cancel() throws {
        let (stream, continuation) = AsyncStream<Result<Int, TestError>>.makeStream()
        var sourceCount = 0
        let data = ViewData<Int>()
        let context = ViewDataContext()

        context.bind({
            sourceCount += 1
            return stream
        }, to: data)
        let staleRetry = try #require(data.retryAction)
        context.cancel(data)

        #expect(data.isEmpty)
        #expect(data.retryAction == nil)
        staleRetry()
        context.reload(data)
        #expect(sourceCount == 1)
        continuation.finish()
    }

    @Test("Context deallocation cancels a refresh binding")
    func contextDeallocation() {
        let (stream, continuation) = AsyncStream<Result<Int, TestError>>.makeStream()
        let data = ViewData<Int>()
        weak var weakContext: ViewDataContext?

        do {
            let context = ViewDataContext()
            weakContext = context
            context.bind({ stream }, to: data, reload: .refresh {})
            #expect(data.retryAction != nil)
        }

        #expect(weakContext == nil)
        #expect(data.isEmpty)
        #expect(data.retryAction == nil)
        continuation.finish()
    }

    @Test("A source that completes without another result restores cached success")
    func emptyRefreshPreservesSuccess() async {
        let (stream, continuation) = AsyncStream<Result<Int, TestError>>.makeStream()
        let data = ViewData(42)
        let context = ViewDataContext()

        context.bind({ stream }, to: data)
        continuation.finish()

        #expect(await eventually { data.isSuccessful })
        #expect(data.latest == 42)
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
