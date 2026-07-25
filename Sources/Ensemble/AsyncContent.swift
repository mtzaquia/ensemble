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

/// The origin of a value rendered by ``AsyncContent``.
public enum AsyncContentSource: Hashable, Sendable {
    /// The current successful value, whether supplied directly or by a bound source.
    case live

    /// A previous successful value retained while the current phase is loading or failed.
    case cached

    /// A fallback value supplied by ``AsyncContentLoadingPolicy/placeholder(_:)`` when no
    /// successful value exists.
    case placeholder
}

/// Controls what ``AsyncContent`` renders while its data is loading.
public enum AsyncContentLoadingPolicy<Value> {
    /// Renders no successful or placeholder content while the data is loading.
    ///
    /// When loading begins from a presented failure, that failure remains visible until the
    /// destination receives another result.
    case hidden

    /// Renders the latest successful value when one exists, and otherwise renders no content.
    case cached

    /// Renders the latest successful value when one exists, falling back to a caller-supplied value.
    ///
    /// The retained value is marked with ``AsyncContentSource/cached``. The fallback value is
    /// marked with ``AsyncContentSource/placeholder``; it is presentation input and is never stored
    /// in the `ViewData` value.
    case placeholder(Value)
}

extension AsyncContentLoadingPolicy {
    func presentation(latest: Value?) -> (value: Value, source: AsyncContentSource)? {
        switch self {
        case .hidden:
            nil
        case .cached:
            latest.map { ($0, .cached) }
        case .placeholder(let placeholder):
            latest.map { ($0, .cached) } ?? (placeholder, .placeholder)
        }
    }
}

/// Controls how ``AsyncContent`` uses its failure builder after its data fails.
public enum AsyncContentFailurePolicy {
    /// Renders the latest successful value when one exists, falling back to the failure builder otherwise.
    case cached

    /// Renders the failure builder instead of successful or cached content.
    case replace
}

/// Controls what ``AsyncContent`` renders after failure when no failure builder is supplied.
public enum AsyncContentFailureFallbackPolicy {
    /// Renders no content for the failure.
    case hidden

    /// Renders the latest successful value when one exists, and otherwise renders no content.
    case cached
}

private enum AsyncContentFailureRendering {
    case hidden
    case cached
    case replace
}

// Keep every value-backed phase in one case so SwiftUI preserves the content subtree when the
// source changes between live, cached, and placeholder presentations.
enum AsyncContentRendering<Value> {
    case hidden
    case content(Value, AsyncContentSource)
    case failure(any Error)
}

private extension AsyncContentFailurePolicy {
    var rendering: AsyncContentFailureRendering {
        switch self {
        case .cached: .cached
        case .replace: .replace
        }
    }
}

private extension AsyncContentFailureFallbackPolicy {
    var rendering: AsyncContentFailureRendering {
        switch self {
        case .hidden: .hidden
        case .cached: .cached
        }
    }
}

/// Renders a ``ViewData`` value according to view-local loading and failure policies.
///
/// `AsyncContent` does not impose a list, section, stack, or other layout container. Its policies
/// apply only to the content produced by this instance, whether that content is a row, section, or
/// larger region composed by the app.
///
/// The empty phase renders `EmptyView`. Start an initial binding from a stable ancestor rather than
/// a `.task` modifier attached directly to an empty `AsyncContent` value.
public struct AsyncContent<Value, Content: View, FailureContent: View>: View {
    private let data: ViewData<Value>
    private let loadingPolicy: AsyncContentLoadingPolicy<Value>
    private let failureRendering: AsyncContentFailureRendering
    private let content: (Value, AsyncContentSource) -> Content
    private let failureContent: (any Error, ViewDataRetryAction?) -> FailureContent

    public var body: some View {
        Group {
            switch rendering {
            case .hidden:
                EmptyView()
            case .content(let value, let source):
                content(value, source)
            case .failure(let error):
                failureContent(error, data.retryAction)
            }
        }
    }

    /// Creates content with a dedicated failure view.
    ///
    /// By default, loading renders the latest successful value when one exists, and a failure
    /// replaces this content with the failure builder.
    ///
    /// The failure builder runs for ``AsyncContentFailurePolicy/replace`` and for
    /// ``AsyncContentFailurePolicy/cached`` when no latest successful value exists. It does not run
    /// when the cached policy can render a retained value.
    ///
    /// - Parameters:
    ///   - data: The presentation state to render.
    ///   - loading: The presentation used while `data` is loading.
    ///   - failure: The presentation used after `data` receives a failure.
    ///   - content: A builder receiving the rendered value and whether it is live, cached, or a placeholder.
    ///   - failureContent: A builder receiving the error and the binding's configured retry action, when available.
    public init(
        _ data: ViewData<Value>,
        loading: AsyncContentLoadingPolicy<Value> = .cached,
        failure: AsyncContentFailurePolicy = .replace,
        @ViewBuilder content: @escaping (Value, AsyncContentSource) -> Content,
        @ViewBuilder failure failureContent: @escaping (any Error, ViewDataRetryAction?) -> FailureContent
    ) {
        self.init(
            data,
            loading: loading,
            failureRendering: failure.rendering,
            content: content,
            failureContent: failureContent
        )
    }

    /// Creates content without a dedicated failure view.
    ///
    /// By default, loading and failure retain the latest successful value when one exists, and
    /// otherwise render nothing.
    ///
    /// Use ``AsyncContentFailureFallbackPolicy/cached`` to retain previous successful content after
    /// a failure, or ``AsyncContentFailureFallbackPolicy/hidden`` to render nothing. Replacement is
    /// intentionally unavailable because this overload has no failure content to render.
    ///
    /// - Parameters:
    ///   - data: The presentation state to render.
    ///   - loading: The presentation used while `data` is loading.
    ///   - failure: The presentation used after `data` receives a failure.
    ///   - content: A builder receiving the rendered value and whether it is live, cached, or a placeholder.
    public init(
        _ data: ViewData<Value>,
        loading: AsyncContentLoadingPolicy<Value> = .cached,
        failure: AsyncContentFailureFallbackPolicy = .cached,
        @ViewBuilder content: @escaping (Value, AsyncContentSource) -> Content
    ) where FailureContent == EmptyView {
        self.init(
            data,
            loading: loading,
            failureRendering: failure.rendering,
            content: content,
            failureContent: { _, _ in EmptyView() }
        )
    }

    private init(
        _ data: ViewData<Value>,
        loading: AsyncContentLoadingPolicy<Value>,
        failureRendering: AsyncContentFailureRendering,
        content: @escaping (Value, AsyncContentSource) -> Content,
        failureContent: @escaping (any Error, ViewDataRetryAction?) -> FailureContent
    ) {
        self.data = data
        self.loadingPolicy = loading
        self.failureRendering = failureRendering
        self.content = content
        self.failureContent = failureContent
    }
}

extension AsyncContent {
    var rendering: AsyncContentRendering<Value> {
        switch data.phase {
        case .empty:
            .hidden
        case .loading:
            loadingPolicy.presentation(latest: data.latest)
                .map { .content($0.value, $0.source) }
                ?? retainedFailureRendering
                ?? .hidden
        case .success:
            data.latest.map { .content($0, .live) } ?? .hidden
        case .failure(let error):
            switch failureRendering {
            case .hidden:
                .hidden
            case .cached:
                data.latest.map { .content($0, .cached) } ?? .failure(error)
            case .replace:
                .failure(error)
            }
        }
    }

    private var retainedFailureRendering: AsyncContentRendering<Value>? {
        guard let error = data.loadingFailure else { return nil }

        return switch failureRendering {
        case .hidden:
            nil
        case .cached where data.latest != nil:
            nil
        case .cached, .replace:
            .failure(error)
        }
    }
}
