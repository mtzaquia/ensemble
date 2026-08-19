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
    /// The latest successful value, whether supplied directly or by a bound source.
    case latest

    /// A previous successful value retained while the current phase is loading or failed.
    case retained

    /// A fallback value supplied by ``AsyncContentLoadingPolicy/placeholder(_:)`` when no
    /// successful value exists.
    case placeholder
}

/// Controls what ``AsyncContent`` renders before a successful value exists and while its data is
/// loading.
public enum AsyncContentLoadingPolicy<Value> {
    /// Renders no successful or placeholder content while the data is empty or loading.
    ///
    /// When loading begins from a presented failure, that failure remains visible until the
    /// destination receives another result.
    case hidden

    /// Renders the retained successful value when one exists, and otherwise renders no content.
    case retained

    /// Renders the retained successful value when one exists, falling back to a caller-supplied
    /// value.
    ///
    /// The retained value is marked with ``AsyncContentSource/retained``. The fallback value is
    /// marked with ``AsyncContentSource/placeholder``; it is presentation input and is never stored
    /// in the `ViewData` value.
    case placeholder(Value)
}

extension AsyncContentLoadingPolicy {
    func presentation(retained: Value?) -> (value: Value, source: AsyncContentSource)? {
        switch self {
        case .hidden:
            nil
        case .retained:
            retained.map { ($0, .retained) }
        case .placeholder(let placeholder):
            retained.map { ($0, .retained) } ?? (placeholder, .placeholder)
        }
    }
}

/// Controls how ``AsyncContent`` uses its failure builder after its data fails.
public enum AsyncContentFailurePolicy {
    /// Renders the retained successful value when one exists, falling back to the failure builder
    /// otherwise.
    case retained

    /// Renders the failure builder instead of successful or retained content.
    case failureContent
}

/// Controls what ``AsyncContent`` renders after failure when no failure builder is supplied.
public enum AsyncContentFailureFallbackPolicy {
    /// Renders no content for the failure.
    case hidden

    /// Renders the retained successful value when one exists, and otherwise renders no content.
    case retained
}

private enum AsyncContentFailureRendering {
    case hidden
    case retainedOrHidden
    case retainedOrFailure
    case failureContent

    init(_ policy: AsyncContentFailurePolicy) {
        self = switch policy {
        case .retained: .retainedOrFailure
        case .failureContent: .failureContent
        }
    }

    init(_ policy: AsyncContentFailureFallbackPolicy) {
        self = switch policy {
        case .hidden: .hidden
        case .retained: .retainedOrHidden
        }
    }
}

// Keep every value-backed phase in one case so SwiftUI preserves the content subtree when the
// source changes between latest, retained, and placeholder presentations.
enum AsyncContentRendering<Value> {
    case hidden
    case content(Value, AsyncContentSource)
    case failure(any Error, ViewDataRetryAction?)
}

enum AsyncContentRenderingKind: Equatable {
    case hidden
    case content
    case failure
}

extension AsyncContentRendering {
    var kind: AsyncContentRenderingKind {
        switch self {
        case .hidden: .hidden
        case .content: .content
        case .failure: .failure
        }
    }
}

/// Renders a ``ViewData`` value according to view-local loading and failure policies.
///
/// `AsyncContent` does not impose a list, section, stack, or other layout container. Its policies
/// apply only to the content produced by this instance, whether that content is a row, section, or
/// larger region composed by the app.
///
/// By default, ``AsyncContent`` seeds its initial rendering without animation, then explicitly
/// animates post-mount changes between hidden, successful content, and failure content. Latest,
/// retained, and placeholder values share one content category, so successful-value replacement
/// does not receive an Ensemble-originated animation.
///
/// Content-to-content replacement renders the incoming snapshot directly and inherits the
/// consumer's current transaction. Passing `nil` for `transitionAnimation` supplies no local
/// animation when the rendered category changes.
///
/// This animation does not configure a SwiftUI transition modifier and cannot infer collection
/// identity from the opaque content builder. Animate insertion, removal, reordering, and value
/// changes inside successful content at the identity-bearing consumer boundary.
///
/// The loading policy applies while the data is empty as well as loading. When that policy renders
/// no content, start an initial binding from a stable ancestor rather than a `.task` modifier
/// attached directly to the empty `AsyncContent` value.
public struct AsyncContent<Value, Content: View, FailureContent: View>: View {
    private let renderingSnapshot: AsyncContentRendering<Value>
    private let presentationRevision: ViewDataPresentationRevision
    private let transitionAnimation: Animation?
    private let content: (Value, AsyncContentSource) -> Content
    private let failureContent: (any Error, ViewDataRetryAction?) -> FailureContent

    @ViewBuilder
    public var body: some View {
        AsyncContentRenderer(
            rendering: renderingSnapshot,
            presentationRevision: presentationRevision,
            transitionAnimation: transitionAnimation,
            content: content,
            failureContent: failureContent
        )
    }

    /// Creates content with a dedicated failure view.
    ///
    /// By default, loading renders the retained successful value when one exists, and a failure
    /// replaces this content with the failure builder.
    ///
    /// The failure builder runs for ``AsyncContentFailurePolicy/failureContent`` and for
    /// ``AsyncContentFailurePolicy/retained`` when no retained successful value exists. It does not
    /// run when the retained policy can render that value.
    ///
    /// - Parameters:
    ///   - data: The presentation state to render.
    ///   - loading: The presentation used while `data` is empty or loading.
    ///   - transitionAnimation: The animation for post-mount changes between rendered categories,
    ///     or `nil` for no Ensemble-supplied animation.
    ///   - failure: The presentation used after `data` receives a failure.
    ///   - content: A builder receiving the rendered value and whether its source is latest,
    ///     retained, or a placeholder.
    ///   - failureContent: A builder receiving the error and the binding's configured retry action,
    ///     when available.
    public init(
        _ data: ViewData<Value>,
        loading: AsyncContentLoadingPolicy<Value> = .retained,
        transitionAnimation: Animation? = .default,
        failure: AsyncContentFailurePolicy = .failureContent,
        @ViewBuilder content: @escaping (Value, AsyncContentSource) -> Content,
        @ViewBuilder failure failureContent: @escaping (any Error, ViewDataRetryAction?) -> FailureContent
    ) {
        self.init(
            data: data,
            loading: loading,
            failureRendering: AsyncContentFailureRendering(failure),
            transitionAnimation: transitionAnimation,
            project: { .some($0) },
            content: content,
            failureContent: failureContent
        )
    }

    /// Creates content without a dedicated failure view.
    ///
    /// By default, loading and failure render the retained successful value when one exists, and
    /// otherwise render nothing.
    ///
    /// Use ``AsyncContentFailureFallbackPolicy/retained`` to render retained successful content
    /// after a failure, or ``AsyncContentFailureFallbackPolicy/hidden`` to render nothing.
    /// ``AsyncContentFailurePolicy/failureContent`` is intentionally unavailable because this
    /// overload has no failure content to render.
    ///
    /// - Parameters:
    ///   - data: The presentation state to render.
    ///   - loading: The presentation used while `data` is empty or loading.
    ///   - transitionAnimation: The animation for post-mount changes between rendered categories,
    ///     or `nil` for no Ensemble-supplied animation.
    ///   - failure: The presentation used after `data` receives a failure.
    ///   - content: A builder receiving the rendered value and whether its source is latest,
    ///     retained, or a placeholder.
    public init(
        _ data: ViewData<Value>,
        loading: AsyncContentLoadingPolicy<Value> = .retained,
        transitionAnimation: Animation? = .default,
        failure: AsyncContentFailureFallbackPolicy = .retained,
        @ViewBuilder content: @escaping (Value, AsyncContentSource) -> Content
    ) where FailureContent == EmptyView {
        self.init(
            data: data,
            loading: loading,
            failureRendering: AsyncContentFailureRendering(failure),
            transitionAnimation: transitionAnimation,
            project: { .some($0) },
            content: content,
            failureContent: { _, _ in EmptyView() }
        )
    }

    private init<SourceValue>(
        data: ViewData<SourceValue>,
        loading: AsyncContentLoadingPolicy<Value>,
        failureRendering: AsyncContentFailureRendering,
        transitionAnimation: Animation?,
        project: (SourceValue) -> Value?,
        content: @escaping (Value, AsyncContentSource) -> Content,
        failureContent: @escaping (any Error, ViewDataRetryAction?) -> FailureContent
    ) {
        self.renderingSnapshot = data.asyncContentRendering(
            loadingPolicy: loading,
            failureRendering: failureRendering,
            project: project
        )
        self.presentationRevision = data.presentationRevision
        self.transitionAnimation = transitionAnimation
        self.content = content
        self.failureContent = failureContent
    }
}

extension AsyncContent {
    /// Creates content by unwrapping each non-`nil` value, with a dedicated failure view.
    ///
    /// A successful `nil` value omits the content without changing the underlying ``ViewData``
    /// phase. Loading and failure policies cannot present a retained `nil` as content. While the
    /// phase is empty or loading, an explicit placeholder is still rendered because it is
    /// non-optional presentation input.
    ///
    /// - Parameters:
    ///   - data: The optional presentation state to render.
    ///   - loading: The presentation used while `data` is empty or loading.
    ///   - transitionAnimation: The animation for post-mount changes between rendered categories,
    ///     or `nil` for no Ensemble-supplied animation.
    ///   - failure: The presentation used after `data` receives a failure.
    ///   - content: A builder receiving the unwrapped value and whether its source is latest,
    ///     retained, or a placeholder.
    ///   - failureContent: A builder receiving the error and the binding's configured retry action,
    ///     when available.
    public init(
        unwrapping data: ViewData<Value?>,
        loading: AsyncContentLoadingPolicy<Value> = .retained,
        transitionAnimation: Animation? = .default,
        failure: AsyncContentFailurePolicy = .failureContent,
        @ViewBuilder content: @escaping (Value, AsyncContentSource) -> Content,
        @ViewBuilder failure failureContent: @escaping (any Error, ViewDataRetryAction?) -> FailureContent
    ) {
        self.init(
            data: data,
            loading: loading,
            failureRendering: AsyncContentFailureRendering(failure),
            transitionAnimation: transitionAnimation,
            project: { $0 },
            content: content,
            failureContent: failureContent
        )
    }

    /// Creates content by unwrapping each non-`nil` value, without a dedicated failure view.
    ///
    /// A successful `nil` value omits the content without changing the underlying ``ViewData``
    /// phase. Loading and failure policies cannot present a retained `nil` as content. While the
    /// phase is empty or loading, an explicit placeholder is still rendered because it is
    /// non-optional presentation input.
    ///
    /// - Parameters:
    ///   - data: The optional presentation state to render.
    ///   - loading: The presentation used while `data` is empty or loading.
    ///   - transitionAnimation: The animation for post-mount changes between rendered categories,
    ///     or `nil` for no Ensemble-supplied animation.
    ///   - failure: The presentation used after `data` receives a failure.
    ///   - content: A builder receiving the unwrapped value and whether its source is latest,
    ///     retained, or a placeholder.
    public init(
        unwrapping data: ViewData<Value?>,
        loading: AsyncContentLoadingPolicy<Value> = .retained,
        transitionAnimation: Animation? = .default,
        failure: AsyncContentFailureFallbackPolicy = .retained,
        @ViewBuilder content: @escaping (Value, AsyncContentSource) -> Content
    ) where FailureContent == EmptyView {
        self.init(
            data: data,
            loading: loading,
            failureRendering: AsyncContentFailureRendering(failure),
            transitionAnimation: transitionAnimation,
            project: { $0 },
            content: content,
            failureContent: { _, _ in EmptyView() }
        )
    }
}

extension AsyncContent {
    var rendering: AsyncContentRendering<Value> {
        renderingSnapshot
    }
}

struct AsyncContentRenderingResolution<Value> {
    let displayedRendering: AsyncContentRendering<Value>
    let transitionAnimation: Animation?

    init(
        incomingRendering: AsyncContentRendering<Value>,
        committedRendering: AsyncContentRendering<Value>,
        transitionAnimation: Animation?
    ) {
        if incomingRendering.kind == committedRendering.kind {
            self.displayedRendering = incomingRendering
            self.transitionAnimation = nil
        } else {
            self.displayedRendering = committedRendering
            self.transitionAnimation = transitionAnimation
        }
    }
}

// Same-category snapshots remain attached to the parent's transaction. Category changes stay on
// the previously committed snapshot until this renderer commits them in its own transaction.
private struct AsyncContentRenderer<Value, Content: View, FailureContent: View>: View {
    let rendering: AsyncContentRendering<Value>
    // This concrete input distinguishes accepted presentation changes whose opaque rendering values
    // cannot be compared structurally by SwiftUI.
    let presentationRevision: ViewDataPresentationRevision
    let transitionAnimation: Animation?
    let content: (Value, AsyncContentSource) -> Content
    let failureContent: (any Error, ViewDataRetryAction?) -> FailureContent

    @State private var committedRendering: AsyncContentRendering<Value>

    init(
        rendering: AsyncContentRendering<Value>,
        presentationRevision: ViewDataPresentationRevision,
        transitionAnimation: Animation?,
        content: @escaping (Value, AsyncContentSource) -> Content,
        failureContent: @escaping (any Error, ViewDataRetryAction?) -> FailureContent
    ) {
        self.rendering = rendering
        self.presentationRevision = presentationRevision
        self.transitionAnimation = transitionAnimation
        self.content = content
        self.failureContent = failureContent
        self._committedRendering = State(initialValue: rendering)
    }

    var body: some View {
        let resolution = AsyncContentRenderingResolution(
            incomingRendering: rendering,
            committedRendering: committedRendering,
            transitionAnimation: transitionAnimation
        )

        Group {
            switch resolution.displayedRendering {
            case .hidden:
                EmptyView()
            case .content(let value, let source):
                content(value, source)
            case .failure(let error, let retryAction):
                failureContent(error, retryAction)
            }
        }
        .onChange(of: presentationRevision) {
            if let animation = resolution.transitionAnimation {
                withAnimation(animation) {
                    committedRendering = rendering
                }
            } else {
                committedRendering = rendering
            }
        }
    }
}

private extension ViewData {
    func asyncContentRendering<Output>(
        loadingPolicy: AsyncContentLoadingPolicy<Output>,
        failureRendering: AsyncContentFailureRendering,
        project: (Value) -> Output?
    ) -> AsyncContentRendering<Output> {
        let projectedLatest: Output? = switch latestValue {
        case .unavailable:
            nil
        case .available(let value):
            project(value)
        }

        return switch phase {
        case .empty:
            loadingPolicy.presentation(retained: projectedLatest)
                .map { .content($0.value, $0.source) }
                ?? .hidden
        case .loading:
            loadingPolicy.presentation(retained: projectedLatest)
                .map { .content($0.value, $0.source) }
                ?? loadingFailureRendering(
                    failureRendering: failureRendering,
                    hasProjectedLatest: projectedLatest != nil
                )
                ?? .hidden
        case .success:
            projectedLatest.map { .content($0, .latest) } ?? .hidden
        case .failure(let error):
            switch failureRendering {
            case .hidden:
                .hidden
            case .retainedOrHidden:
                projectedLatest.map { .content($0, .retained) } ?? .hidden
            case .retainedOrFailure:
                projectedLatest.map { .content($0, .retained) }
                    ?? .failure(error, retryAction)
            case .failureContent:
                .failure(error, retryAction)
            }
        }
    }

    private func loadingFailureRendering<Output>(
        failureRendering: AsyncContentFailureRendering,
        hasProjectedLatest: Bool
    ) -> AsyncContentRendering<Output>? {
        guard let error = loadingFailure else { return nil }

        return switch failureRendering {
        case .hidden, .retainedOrHidden:
            nil
        case .retainedOrFailure where hasProjectedLatest:
            nil
        case .retainedOrFailure, .failureContent:
            .failure(error, retryAction)
        }
    }
}
