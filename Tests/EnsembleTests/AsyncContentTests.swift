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

    @available(*, deprecated)
    @Test("Deprecated presentation names forward to their replacements")
    func deprecatedPresentationNames() {
        #expect(AsyncContentSource.live == .latest)
        #expect(AsyncContentSource.cached == .retained)
        let matchesLive = switch AsyncContentSource.latest {
        case .live: true
        default: false
        }
        #expect(matchesLive)
        let matchesCached = switch AsyncContentSource.retained {
        case .cached: true
        default: false
        }
        #expect(matchesCached)

        let loading: AsyncContentLoadingPolicy<Int> = .cached
        #expect(ifCaseRetained(loading))

        let retainedFailure: AsyncContentFailurePolicy = .cached
        #expect(ifCaseRetained(retainedFailure))

        let replacementFailure: AsyncContentFailurePolicy = .replace
        #expect(ifCaseFailureContent(replacementFailure))

        let fallback: AsyncContentFailureFallbackPolicy = .cached
        #expect(ifCaseRetained(fallback))
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
        let content = AsyncContent(unwrapping: data) { value, _ in
            Text("\(value)")
        }

        data.beginLoading()

        #expect(content.rendering.isHidden)
    }

    @Test("Unwrapping can render an explicit placeholder for a retained nil")
    func unwrappingPlaceholderForNil() throws {
        let data = ViewData<Int?>(nil)
        let content = AsyncContent(
            unwrapping: data,
            loading: .placeholder(10)
        ) { value, _ in
            Text("\(value)")
        }

        data.beginLoading()

        let presentation = try #require(content.rendering.content)
        #expect(presentation.value == 10)
        #expect(presentation.source == .placeholder)
    }

    @Test("Unwrapping treats a retained nil as unavailable after failure")
    func unwrappingRetainedNilAfterFailure() throws {
        let data = ViewData<Int?>(nil)
        let content = AsyncContent(
            unwrapping: data,
            failure: .retained
        ) { value, _ in
            Text("\(value)")
        } failure: { error, _ in
            Text(error.localizedDescription)
        }

        data.fail(TestError.expected)

        let error = try #require(content.rendering.failure as? TestError)
        #expect(error == .expected)
    }

    @Test("A placeholder is used before the first successful value")
    func placeholderWithoutRetainedValue() {
        let presentation = AsyncContentLoadingPolicy.placeholder(10).presentation(retained: nil)

        #expect(presentation?.value == 10)
        #expect(presentation?.source == .placeholder)
    }

    @Test("A placeholder policy prefers the retained successful value")
    func placeholderWithRetainedValue() {
        let presentation = AsyncContentLoadingPolicy.placeholder(10).presentation(retained: 20)

        #expect(presentation?.value == 20)
        #expect(presentation?.source == .retained)
    }

    @Test("Hidden loading content retains a presented failure during retry")
    func hiddenLoadingRetainsPresentedFailure() throws {
        let data = ViewData<Int>()
        let content = AsyncContent(
            data,
            loading: .hidden,
            failure: .failureContent
        ) { value, _ in
            Text("\(value)")
        } failure: { error, _ in
            Text(error.localizedDescription)
        }

        data.fail(TestError.expected)
        data.beginLoading()

        let retryError = try #require(content.rendering.failure as? TestError)
        #expect(retryError == .expected)

        data.set(42)

        let success = try #require(content.rendering.content)
        #expect(success.value == 42)
        #expect(success.source == .latest)

        data.fail(TestError.expected)
        data.beginLoading()
        data.fail(TestError.subsequent)

        let subsequentError = try #require(content.rendering.failure as? TestError)
        #expect(subsequentError == .subsequent)
    }

    @Test("A placeholder replaces a failure while retrying")
    func placeholderReplacesRetryingFailure() throws {
        let data = ViewData<Int>()
        let content = AsyncContent(
            data,
            loading: .placeholder(10),
            failure: .failureContent
        ) { value, _ in
            Text("\(value)")
        } failure: { error, _ in
            Text(error.localizedDescription)
        }

        data.fail(TestError.expected)
        data.beginLoading()

        let presentation = try #require(content.rendering.content)
        #expect(presentation.value == 10)
        #expect(presentation.source == .placeholder)
    }
}

private func ifCaseRetained<Value>(_ policy: AsyncContentLoadingPolicy<Value>) -> Bool {
    if case .retained = policy { true } else { false }
}

private func ifCaseRetained(_ policy: AsyncContentFailurePolicy) -> Bool {
    if case .retained = policy { true } else { false }
}

private func ifCaseFailureContent(_ policy: AsyncContentFailurePolicy) -> Bool {
    if case .failureContent = policy { true } else { false }
}

private func ifCaseRetained(_ policy: AsyncContentFailureFallbackPolicy) -> Bool {
    if case .retained = policy { true } else { false }
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

    var failure: (any Error)? {
        if case .failure(let error) = self {
            error
        } else {
            nil
        }
    }
}
