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
import Observation
import SwiftUI

struct CachedRefreshExample: View {
    @State private var viewModel = CachedRefreshViewModel()

    var body: some View {
        AsyncContent(
            viewModel.entries,
            loading: .placeholder(SampleEntry.placeholders),
            transitionAnimation: .default,
            failure: .retained
        ) { entries, source in
            List {
                Section {
                    SampleEntryRows(entries: entries, source: source)
                } header: {
                    HStack {
                        Text("Entries")
                        Spacer()
                        SampleSourceBadge(source: source)
                    }
                } footer: {
                    Text(viewModel.phaseDescription)
                        .accessibilityIdentifier(SampleAppAccessibility.cachedRefreshPhase)
                }

                Section("Actions") {
                    Button("Refresh successfully") {
                        viewModel.refreshSuccessfully()
                    }
                    .accessibilityIdentifier(SampleAppAccessibility.cachedRefreshSuccess)
                    Button("Refresh with failure") {
                        viewModel.refreshWithFailure()
                    }
                    .accessibilityIdentifier(SampleAppAccessibility.cachedRefreshFailure)
                    Button("Load one value") {
                        viewModel.loadOneValue()
                    }
                    .accessibilityIdentifier(SampleAppAccessibility.cachedRefreshDirect)
                }

                Section("What this shows") {
                    Label("ViewData starts with seeded content", systemImage: "1.circle")
                    Label("Placeholder policy prefers the retained value", systemImage: "2.circle")
                    Label("One binding observes the long-lived stream", systemImage: "3.circle")
                    Label("Reload signals the existing producer", systemImage: "4.circle")
                    Label("Failure can keep rendering the retained value", systemImage: "5.circle")
                    Label("A one-shot load can update it in tandem", systemImage: "6.circle")
                }
            }
            .accessibilityIdentifier(SampleAppAccessibility.cachedRefreshScreen)
        } failure: { error, retry in
            ContentUnavailableView {
                Label("No retained entries", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text(error.localizedDescription)
            } actions: {
                if let retry {
                    Button("Try again") { retry() }
                }
            }
        }
        .navigationTitle("Cached refresh")
        .task {
            viewModel.start()
        }
    }
}

@Observable
private final class CachedRefreshViewModel {
    let entries = ViewData(SampleEntry.cached)

    @ObservationIgnored private let context = ViewDataContext()
    @ObservationIgnored private let useCase = CachedRefreshUseCase()
    @ObservationIgnored private var hasStarted = false

    var phaseDescription: String {
        switch entries.phase {
        case .empty:
            "No value is available."
        case .loading:
            "A refresh is running while the seeded value remains visible."
        case .success:
            "The current value is the latest successful update."
        case .failure:
            "The refresh failed, so AsyncContent is rendering the retained value."
        }
    }

    func start() {
        guard hasStarted == false else { return }
        hasStarted = true
        context.bind(
            useCase.values,
            to: entries,
            reload: .refresh(useCase.reload)
        )
    }

    func refreshSuccessfully() {
        useCase.prepare(.success(SampleEntry.refreshed))
        context.reload(entries)
    }

    func refreshWithFailure() {
        useCase.prepare(.failure(.offline))
        context.reload(entries)
    }

    func loadOneValue() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await context.load({
                [
                    SampleEntry(
                        id: 200,
                        title: "One-shot value",
                        detail: "A load and binding can update the same presentation state"
                    ),
                ]
            }, to: entries)
        }
    }
}

private final class CachedRefreshUseCase {
    typealias Update = Result<[SampleEntry], SampleFailure>

    private let stream: AsyncStream<Update>
    private let continuation: AsyncStream<Update>.Continuation
    private var nextUpdate: Update = .success(SampleEntry.cached)
    private var reloadTask: Task<Void, Never>?

    init() {
        let (stream, continuation) = AsyncStream<Update>.makeStream()
        self.stream = stream
        self.continuation = continuation
        continuation.yield(.success(SampleEntry.cached))
    }

    func values() -> AsyncStream<Update> {
        stream
    }

    func prepare(_ update: Update) {
        nextUpdate = update
    }

    func reload() {
        reloadTask?.cancel()
        let update = nextUpdate
        reloadTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(700))
            } catch {
                return
            }

            guard let self, Task.isCancelled == false else { return }
            continuation.yield(update)
            reloadTask = nil
        }
    }
}
