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

    @Test("The transition animation parameter composes across every initializer family")
    func transitionAnimationParameterComposes() {
        let data = ViewData<Int>()
        let optionalData = ViewData<Int?>(42)

        for animation in [Animation.default, nil] {
            _ = AsyncContent(data, transitionAnimation: animation) { value, _ in
                Text("\(value)")
            }

            _ = AsyncContent(data, transitionAnimation: animation) { value, _ in
                Text("\(value)")
            } failure: { error, _ in
                Text(error.localizedDescription)
            }

            _ = AsyncContent(unwrapping: optionalData, transitionAnimation: animation) { value, _ in
                Text("\(value)")
            }

            _ = AsyncContent(
                unwrapping: optionalData,
                transitionAnimation: animation
            ) { value, _ in
                Text("\(value)")
            } failure: { error, _ in
                Text(error.localizedDescription)
            }
        }
    }

    @Test("Each AsyncContent value captures one presentation snapshot")
    func capturesPresentationSnapshot() throws {
        let data = ViewData(1)
        let original = AsyncContent(data) { value, _ in
            Text("\(value)")
        }

        data.set(2)

        let updated = AsyncContent(data) { value, _ in
            Text("\(value)")
        }
        #expect(try #require(original.rendering.content).value == 1)
        #expect(try #require(updated.rendering.content).value == 2)
    }

    @Test("Same-category updates display the incoming snapshot")
    func sameCategoryUpdatesDisplayIncomingSnapshot() throws {
        let committed = AsyncContentRendering.content([1, 2, 3], AsyncContentSource.latest)
        let incoming = AsyncContentRendering.content([3, 1, 2], AsyncContentSource.latest)

        let resolution = AsyncContentRenderingResolution(
            incomingRendering: incoming,
            committedRendering: committed,
            transitionAnimation: .default
        )

        #expect(try #require(resolution.displayedRendering.content).value == [3, 1, 2])
        #expect(resolution.transitionAnimation == nil)
    }

    @Test("Placeholder replacement supplies no local transition animation")
    func placeholderReplacementIsUnanimated() throws {
        let placeholder = AsyncContentRendering.content(0, AsyncContentSource.placeholder)
        let latest = AsyncContentRendering.content(42, AsyncContentSource.latest)

        let resolution = AsyncContentRenderingResolution(
            incomingRendering: latest,
            committedRendering: placeholder,
            transitionAnimation: .default
        )

        let displayed = try #require(resolution.displayedRendering.content)
        #expect(displayed.value == 42)
        #expect(displayed.source == .latest)
        #expect(resolution.transitionAnimation == nil)
    }

    @Test("Category changes retain the committed snapshot until transition commit")
    func categoryChangesRetainCommittedSnapshot() throws {
        let committed = AsyncContentRendering<Int>.hidden
        let incoming = AsyncContentRendering.content(42, AsyncContentSource.latest)

        let beforeCommit = AsyncContentRenderingResolution(
            incomingRendering: incoming,
            committedRendering: committed,
            transitionAnimation: .default
        )
        #expect(beforeCommit.displayedRendering.isHidden)

        let afterCommit = AsyncContentRenderingResolution(
            incomingRendering: incoming,
            committedRendering: incoming,
            transitionAnimation: .default
        )
        #expect(try #require(afterCommit.displayedRendering.content).value == 42)
    }

    @Test("Transition animation is selected only for category changes")
    func transitionAnimationSelection() {
        let categories: [AsyncContentRenderingKind] = [.hidden, .content, .failure]

        for previous in categories {
            for next in categories {
                let resolution = AsyncContentRenderingResolution(
                    incomingRendering: rendering(for: next),
                    committedRendering: rendering(for: previous),
                    transitionAnimation: .default
                )

                #expect((resolution.transitionAnimation != nil) == (previous != next))
            }
        }
    }

    @Test("Nil configuration supplies no local transition animation")
    func nilTransitionAnimation() {
        let resolution = AsyncContentRenderingResolution(
            incomingRendering: AsyncContentRendering.content(42, AsyncContentSource.latest),
            committedRendering: AsyncContentRendering<Int>.hidden,
            transitionAnimation: nil
        )

        #expect(resolution.displayedRendering.isHidden)
        #expect(resolution.transitionAnimation == nil)
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
        let withoutRetry = AsyncContent(data) { value, _ in
            Text("\(value)")
        } failure: { error, retry in
            Button(error.localizedDescription) { retry?() }
        }

        data.installRetryAction(ViewDataRetryAction {})

        let withRetry = AsyncContent(data) { value, _ in
            Text("\(value)")
        } failure: { error, retry in
            Button(error.localizedDescription) { retry?() }
        }
        #expect(withoutRetry.rendering.failure?.retryAction == nil)
        #expect(withRetry.rendering.failure?.retryAction != nil)
        #expect(withoutRetry.rendering.kind == .failure)
        #expect(withRetry.rendering.kind == .failure)
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

    private func rendering(
        for kind: AsyncContentRenderingKind
    ) -> AsyncContentRendering<Int> {
        switch kind {
        case .hidden:
            .hidden
        case .content:
            .content(42, .latest)
        case .failure:
            .failure(TestError.expected, nil)
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
