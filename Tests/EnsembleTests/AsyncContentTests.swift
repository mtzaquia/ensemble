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

@Suite("Async content")
struct AsyncContentTests {
    enum TestError: Error, Equatable {
        case expected
        case subsequent
    }

    @Test("The content and failure builder API composes")
    func buildersCompose() {
        let data = ViewData<Int>()

        _ = AsyncContent(data) { value, _ in
            Text("\(value)")
        }

        _ = AsyncContent(data) { value, _ in
            Text("\(value)")
        } failure: { error, _ in
            Text(error.localizedDescription)
        }

        _ = AsyncContent(
            data,
            loading: .placeholder(0),
            failure: .failureContent
        ) { value, source in
            Text("\(value)-\(String(describing: source))")
        } failure: { error, retry in
            Button(error.localizedDescription) {
                retry?()
            }
        }

        _ = AsyncContent(data, loading: .retained, failure: .retained) { value, _ in
            Text("\(value)")
        }

        _ = AsyncContent(data, failure: .retained) { value, _ in
            Text("\(value)")
        } failure: { error, _ in
            Text(error.localizedDescription)
        }

        _ = AsyncContent(data, failure: .hidden) { value, _ in
            Text("\(value)")
        }

        let optionalData = ViewData<Int?>(42)

        _ = AsyncContent(unwrapping: optionalData) { value, _ in
            Text("\(value)")
        }

        _ = AsyncContent(unwrapping: optionalData) { value, _ in
            Text("\(value)")
        } failure: { error, _ in
            Text(error.localizedDescription)
        }
    }

    @Test("The phase animation modifier composes across every initializer family")
    func phaseAnimationModifierComposes() {
        let data = ViewData<Int>()
        let optionalData = ViewData<Int?>(42)

        for animation in [Animation.default, nil] {
            _ = AsyncContent(data) { value, _ in
                Text("\(value)")
            }
            .phaseAnimation(animation)

            _ = AsyncContent(data) { value, _ in
                Text("\(value)")
            } failure: { error, _ in
                Text(error.localizedDescription)
            }
            .phaseAnimation(animation)

            _ = AsyncContent(unwrapping: optionalData) { value, _ in
                Text("\(value)")
            }
            .phaseAnimation(animation)

            _ = AsyncContent(unwrapping: optionalData) { value, _ in
                Text("\(value)")
            } failure: { error, _ in
                Text(error.localizedDescription)
            }
            .phaseAnimation(animation)
        }
    }

    @Test("Constructing AsyncContent does not observe presentation state")
    func constructionDoesNotObservePresentation() {
        let data = ViewData(1)
        let observation = ObservationCounter()

        observation.track {
            _ = AsyncContent(data) { value, _ in
                Text("\(value)")
            }
            .phaseAnimation(.snappy)
        }

        data.reset()

        #expect(observation.cycles == 0)
    }

    @Test("AsyncContent observation forwards accepted presentation changes")
    func bodyObservesPresentation() {
        let data = ViewData(1)
        let content = AsyncContentObservation()
        content.bind(to: data, animation: nil)
        let observation = ObservationCounter()

        observation.track {
            _ = content.revision
        }

        data.reset()

        #expect(observation.cycles == 1)
    }

    @Test("AsyncContent observation rebinds without duplicate or stale notifications")
    func observationRebinding() {
        let first = ViewData(1)
        let second = ViewData(2)
        let observation = AsyncContentObservation()
        observation.bind(to: first, animation: .snappy)
        observation.bind(to: first, animation: nil)
        first.set(3)
        #expect(observation.revision == 1)

        observation.bind(to: second, animation: .snappy)
        first.reset()
        #expect(observation.revision == 1)
        second.reset()
        #expect(observation.revision == 2)
    }

    @Test("Presentation observation does not retain its view adapter or data")
    func observationLifetime() {
        let observation = AsyncContentObservation()
        weak var weakData: ViewData<Int>?
        do {
            let data = ViewData(1)
            weakData = data
            observation.bind(to: data, animation: nil)
        }
        #expect(weakData == nil)

        let data = ViewData(1)
        weak var weakObservation: AsyncContentObservation?
        do {
            let temporary = AsyncContentObservation()
            weakObservation = temporary
            temporary.bind(to: data, animation: nil)
        }
        #expect(weakObservation == nil)
        data.reset()
    }

    @Test("AsyncContent resolves the current presentation")
    func resolvesCurrentPresentation() throws {
        let data = ViewData(1)
        let content = AsyncContent(data) { value, _ in
            Text("\(value)")
        }

        data.set(2)

        #expect(try #require(content.rendering.content).value == 2)
    }

    @Test("Configured phase animation replaces the transaction animation")
    func configuredPhaseAnimation() {
        var transaction = Transaction(animation: .linear)

        applyAsyncContentPhaseAnimation(.snappy, to: &transaction)

        #expect(transaction.animation == .snappy)
    }

    @Test("Nil phase animation preserves inherited structural or consumer animation")
    func nilPhaseAnimationPreservesInheritedTransaction() {
        var transaction = Transaction(animation: .default)

        applyAsyncContentPhaseAnimation(nil, to: &transaction)

        #expect(transaction.animation == .default)
        #expect(transaction.disablesAnimations == false)
    }

    @Test("Phase animation respects transactions that disable animations")
    func disabledAnimationTransaction() {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        applyAsyncContentPhaseAnimation(.snappy, to: &transaction)

        #expect(transaction.animation == nil)
        #expect(transaction.disablesAnimations)
    }

    @Test("Phase identity distinguishes placeholder-to-success without replacing content identity")
    func placeholderReplacementChangesPhase() {
        let data = ViewData<Int>()
        let content = AsyncContent(data, loading: .placeholder(0)) { value, _ in
            Text("\(value)")
        }
        #expect(content.presentation.phase == .empty)
        #expect(content.rendering.kind == .content)

        data.beginLoading()
        #expect(content.presentation.phase == .loading)
        #expect(content.rendering.kind == .content)

        data.set(42)
        #expect(content.presentation.phase == .content)
        #expect(content.rendering.kind == .content)

        data.set(43)
        #expect(content.presentation.phase == .content)

        data.fail(TestError.expected)
        #expect(content.presentation.phase == .failure)

        data.reset()
        #expect(content.presentation.phase == .empty)
    }

    @Test("Optional rendering uses the underlying lifecycle phase even when hidden or retained")
    func optionalPresentationPhase() {
        let data = ViewData<Int?>(nil)
        let content = AsyncContent(unwrapping: data, failure: .retained) { value, _ in
            Text("\(value)")
        }
        #expect(content.presentation.phase == .content)
        #expect(content.rendering.kind == .hidden)

        data.beginLoading()
        #expect(content.presentation.phase == .loading)
        data.fail(TestError.expected)
        #expect(content.presentation.phase == .failure)

        data.set(42)
        data.beginLoading()
        #expect(content.presentation.phase == .loading)
        #expect(content.rendering.kind == .content)
        data.fail(TestError.expected)
        #expect(content.presentation.phase == .failure)
        #expect(content.rendering.kind == .content)
    }

    @Test("Latest, retained, and placeholder presentations are all content")
    func successfulPresentationCategories() {
        let latest = AsyncContentRendering<Int>.content(1, .latest)
        let retained = AsyncContentRendering<Int>.content(1, .retained)
        let placeholder = AsyncContentRendering<Int>.content(1, .placeholder)

        #expect(latest.kind == .content)
        #expect(retained.kind == .content)
        #expect(placeholder.kind == .content)
    }

    @Test("Failure policies map to the category actually rendered")
    func failurePolicyCategories() {
        let data = ViewData(42)
        data.fail(TestError.expected)

        let retained = AsyncContent(data, failure: .retained) { value, _ in
            Text("\(value)")
        } failure: { error, _ in
            Text(error.localizedDescription)
        }
        let replacement = AsyncContent(data, failure: .failureContent) { value, _ in
            Text("\(value)")
        } failure: { error, _ in
            Text(error.localizedDescription)
        }
        let hidden = AsyncContent(data, failure: .hidden) { value, _ in
            Text("\(value)")
        }
        let emptyData = ViewData<Int>()
        emptyData.fail(TestError.expected)
        let retainedFallback = AsyncContent(emptyData, failure: .retained) { value, _ in
            Text("\(value)")
        }

        #expect(retained.rendering.kind == .content)
        #expect(replacement.rendering.kind == .failure)
        #expect(hidden.rendering.kind == .hidden)
        #expect(retainedFallback.rendering.kind == .hidden)
    }

    @Test("Retry changes update builder input without changing the rendering category")
    func retryChangesUpdateBuilderInput() {
        let data = ViewData<Int>()
        data.fail(TestError.expected)
        let content = AsyncContent(data) { value, _ in
            Text("\(value)")
        } failure: { error, retry in
            Button(error.localizedDescription) { retry?() }
        }
        let withoutRetry = content.rendering

        data.installRetryAction(ViewDataRetryAction {})

        let withRetry = content.rendering
        #expect(withoutRetry.failure?.retryAction == nil)
        #expect(withRetry.failure?.retryAction != nil)
        #expect(withoutRetry.kind == .failure)
        #expect(withRetry.kind == .failure)
    }

    @Test("Unwrapping renders a non-optional latest value")
    func unwrappingLatestValue() throws {
        let data = ViewData<Int?>(42)
        let content = AsyncContent(unwrapping: data) { value, _ in
            Text("\(value)")
        }

        let presentation = try #require(content.rendering.content)
        #expect(presentation.value == 42)
        #expect(presentation.source == .latest)
    }

    @Test("Unwrapping omits a successful nil value")
    func unwrappingNilValue() {
        let data = ViewData<Int?>(nil)
        let content = AsyncContent(unwrapping: data) { value, _ in
            Text("\(value)")
        }

        #expect(content.rendering.isHidden)
    }

    @Test("The standard initializer preserves a successful optional nil")
    func standardInitializerPreservesOptionalNil() throws {
        let data = ViewData<Int?>(nil)
        let content = AsyncContent(data) { value, _ in
            Text("\(String(describing: value))")
        }

        let presentation = try #require(content.rendering.content)
        #expect(presentation.value == nil)
        #expect(presentation.source == .latest)
    }

    @Test("Empty presentation follows the loading policy immediately")
    func emptyPresentationUsesLoadingPolicy() throws {
        let data = ViewData<Int>()

        let placeholderContent = AsyncContent(
            data,
            loading: .placeholder(10)
        ) { value, _ in
            Text("\(value)")
        }
        let placeholder = try #require(placeholderContent.rendering.content)
        #expect(placeholder.value == 10)
        #expect(placeholder.source == .placeholder)

        let optionalData = ViewData<Int?>()
        let unwrappedContent = AsyncContent(
            unwrapping: optionalData,
            loading: .placeholder(20)
        ) { value, _ in
            Text("\(value)")
        }
        let unwrappedPlaceholder = try #require(unwrappedContent.rendering.content)
        #expect(unwrappedPlaceholder.value == 20)
        #expect(unwrappedPlaceholder.source == .placeholder)

        let retainedContent = AsyncContent(data, loading: .retained) { value, _ in
            Text("\(value)")
        }
        #expect(retainedContent.rendering.isHidden)

        let hiddenContent = AsyncContent(data, loading: .hidden) { value, _ in
            Text("\(value)")
        }
        #expect(hiddenContent.rendering.isHidden)
    }

    @Test("Unwrapping treats a retained nil as unavailable while loading")
    func unwrappingRetainedNilWhileLoading() {
        let data = ViewData<Int?>(nil)
        data.beginLoading()

        let content = AsyncContent(unwrapping: data) { value, _ in
            Text("\(value)")
        }
        #expect(content.rendering.isHidden)
    }

    @Test("Unwrapping can render an explicit placeholder for a retained nil")
    func unwrappingPlaceholderForNil() throws {
        let data = ViewData<Int?>(nil)
        data.beginLoading()

        let content = AsyncContent(
            unwrapping: data,
            loading: .placeholder(10)
        ) { value, _ in
            Text("\(value)")
        }

        let presentation = try #require(content.rendering.content)
        #expect(presentation.value == 10)
        #expect(presentation.source == .placeholder)
    }

    @Test("Unwrapping treats a retained nil as unavailable after failure")
    func unwrappingRetainedNilAfterFailure() throws {
        let data = ViewData<Int?>(nil)
        data.fail(TestError.expected)

        let content = AsyncContent(
            unwrapping: data,
            failure: .retained
        ) { value, _ in
            Text("\(value)")
        } failure: { error, _ in
            Text(error.localizedDescription)
        }

        let error = try #require(content.rendering.failure?.error as? TestError)
        #expect(error == .expected)
    }

    @Test("A placeholder policy yields to retained content")
    func placeholderPolicy() {
        let placeholder = AsyncContentLoadingPolicy.placeholder(10).presentation(retained: nil)
        let retained = AsyncContentLoadingPolicy.placeholder(10).presentation(retained: 20)

        #expect(placeholder?.value == 10)
        #expect(placeholder?.source == .placeholder)
        #expect(retained?.value == 20)
        #expect(retained?.source == .retained)
    }

    @Test("Hidden loading content retains a presented failure during retry")
    func hiddenLoadingRetainsPresentedFailure() throws {
        let data = ViewData<Int>()
        data.fail(TestError.expected)

        let failedContent = hiddenLoadingContent(data)

        let failureError = try #require(failedContent.rendering.failure?.error as? TestError)
        #expect(failureError == .expected)

        data.beginLoading()

        let retryingContent = hiddenLoadingContent(data)
        let retryError = try #require(retryingContent.rendering.failure?.error as? TestError)
        #expect(retryError == .expected)

        data.set(42)

        let successfulContent = hiddenLoadingContent(data)
        let success = try #require(successfulContent.rendering.content)
        #expect(success.value == 42)
        #expect(success.source == .latest)

        data.fail(TestError.expected)
        data.beginLoading()
        data.fail(TestError.subsequent)

        let subsequentContent = hiddenLoadingContent(data)
        let subsequentError = try #require(
            subsequentContent.rendering.failure?.error as? TestError
        )
        #expect(subsequentError == .subsequent)
    }

    @Test("Retry keeps failure content ahead of a placeholder until the next result")
    func retryKeepsFailureAheadOfPlaceholder() async throws {
        var continuations: [AsyncStream<Result<Int, TestError>>.Continuation] = []
        let data = ViewData<Int>()
        let context = ViewDataContext()

        context.bind({
            let (stream, continuation) = AsyncStream<Result<Int, TestError>>.makeStream()
            continuations.append(continuation)
            return stream
        }, to: data)

        continuations[0].yield(.failure(.expected))
        #expect(await eventually { data.phase.kind == .failure })

        let initialFailure = try #require(placeholderLoadingContent(data).rendering.failure)
        #expect(initialFailure.error as? TestError == .expected)

        let firstRetry = try #require(initialFailure.retryAction)
        firstRetry()
        #expect(await eventually { continuations.count == 2 && data.phase.kind == .loading })

        let firstRetryingFailure = try #require(
            placeholderLoadingContent(data).rendering.failure
        )
        #expect(firstRetryingFailure.error as? TestError == .expected)

        continuations[1].yield(.failure(.subsequent))
        #expect(await eventually { data.phase.kind == .failure })

        let subsequentFailure = try #require(placeholderLoadingContent(data).rendering.failure)
        #expect(subsequentFailure.error as? TestError == .subsequent)

        let secondRetry = try #require(subsequentFailure.retryAction)
        secondRetry()
        #expect(await eventually { continuations.count == 3 && data.phase.kind == .loading })

        let secondRetryingFailure = try #require(
            placeholderLoadingContent(data).rendering.failure
        )
        #expect(secondRetryingFailure.error as? TestError == .subsequent)

        continuations[2].yield(.success(42))
        #expect(await eventually { data.phase.kind == .success })

        let success = try #require(placeholderLoadingContent(data).rendering.content)
        #expect(success.value == 42)
        #expect(success.source == .latest)

        continuations[2].finish()
    }

    private func hiddenLoadingContent(
        _ data: ViewData<Int>
    ) -> AsyncContent<Int, Text, Text> {
        AsyncContent(
            data,
            loading: .hidden,
            failure: .failureContent
        ) { value, _ in
            Text("\(value)")
        } failure: { error, _ in
            Text(error.localizedDescription)
        }
    }

    private func placeholderLoadingContent(
        _ data: ViewData<Int>
    ) -> AsyncContent<Int, Text, Text> {
        AsyncContent(
            data,
            loading: .placeholder(10),
            failure: .failureContent
        ) { value, _ in
            Text("\(value)")
        } failure: { error, _ in
            Text(error.localizedDescription)
        }
    }

}

private func eventually(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if predicate() { return true }
        await Task.yield()
    }
    return false
}

@MainActor
private final class ObservationCounter {
    private(set) var cycles = 0

    func track(_ apply: () -> Void) {
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                self?.cycles += 1
            }
        }
    }
}

private extension AsyncContentRendering {
    var isHidden: Bool {
        if case .hidden = self {
            true
        } else {
            false
        }
    }

    var content: (value: Value, source: AsyncContentSource)? {
        if case .content(let value, let source) = self {
            (value, source)
        } else {
            nil
        }
    }

    var failure: (error: any Error, retryAction: ViewDataRetryAction?)? {
        if case .failure(let error, let retryAction) = self {
            (error, retryAction)
        } else {
            nil
        }
    }
}
