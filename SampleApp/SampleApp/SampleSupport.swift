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

import Ensemble
import SwiftUI

struct SampleEntry: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let detail: String

    static let placeholders = [
        SampleEntry(id: 0, title: "Placeholder title", detail: "Placeholder detail"),
        SampleEntry(id: 1, title: "Another title", detail: "Another detail"),
        SampleEntry(id: 2, title: "One more title", detail: "One more detail"),
    ]

    static let cached = [
        SampleEntry(id: 10, title: "Previously downloaded", detail: "Available from the first frame"),
        SampleEntry(id: 11, title: "Still useful", detail: "Retained while a refresh is in flight"),
    ]

    static let refreshed = [
        SampleEntry(id: 20, title: "Fresh result", detail: "Replaced the seeded value"),
        SampleEntry(id: 21, title: "Current content", detail: "Delivered by the latest stream"),
        SampleEntry(id: 22, title: "Ready for another refresh", detail: "The source can be rebound at any time"),
    ]

    static let recovered = [
        SampleEntry(id: 30, title: "Stable state", detail: "The retry emitted this value"),
        SampleEntry(id: 31, title: "Recoverable failure", detail: "A failure result did not crash the stream"),
        SampleEntry(id: 32, title: "Fresh subscription", detail: "Retry recreated the source"),
    ]
}

enum SampleFailure: LocalizedError, Sendable {
    case offline
    case unavailable

    var errorDescription: String? {
        switch self {
        case .offline:
            "The source is offline. Cached content can remain on screen."
        case .unavailable:
            "This required source failed. Retry to create a fresh stream."
        }
    }
}

struct DelayedSource<Value: Sendable> {
    let result: Result<Value, SampleFailure>
    var delay: Duration = .milliseconds(700)

    func values() -> AsyncStream<Result<Value, SampleFailure>> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    continuation.finish()
                    return
                }

                continuation.yield(result)
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

struct SampleEntryRow: View {
    let entry: SampleEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title)
                .font(.headline)
            Text(entry.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier(SampleAppAccessibility.entry(entry.id))
    }
}

struct SampleEntryRows: View {
    let entries: [SampleEntry]
    let source: AsyncContentSource

    var body: some View {
        ForEach(entries) { entry in
            SampleEntryRow(entry: entry)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .trailing)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 0.96)),
                        removal: .move(edge: .leading)
                            .combined(with: .opacity)
                    )
                )
        }
        .redacted(reason: source == .placeholder ? .placeholder : [])
    }
}

struct SampleSourceBadge: View {
    let source: AsyncContentSource

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .accessibilityIdentifier(SampleAppAccessibility.source(source))
    }

    private var label: String {
        switch source {
        case .live: "Live"
        case .cached: "Cached"
        case .placeholder: "Placeholder"
        }
    }

    private var color: Color {
        switch source {
        case .live: .green
        case .cached: .orange
        case .placeholder: .secondary
        }
    }
}

struct SampleInlineFailure: View {
    let title: String
    let error: any Error
    let retry: ViewDataRetryAction?
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "exclamationmark.triangle")
                .font(.headline)
                .accessibilityIdentifier(SampleAppAccessibility.failure(identifier))
            Text(error.localizedDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let retry {
                Button("Try again") {
                    retry()
                }
                .accessibilityIdentifier(SampleAppAccessibility.failureRetry(identifier))
            }
        }
        .padding(.vertical, 6)
    }
}
