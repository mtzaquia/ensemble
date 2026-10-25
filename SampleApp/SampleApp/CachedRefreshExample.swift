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
        // The List, controls, and task stay mounted even when content is invalidated or fails.
        List {
            AsyncContent(
                viewModel.entries,
                loading: .placeholder(SampleEntry.placeholders),
                failure: .retained
            ) { entries, source in
                CachedRefreshEntries(
                    entries: entries,
                    source: source,
                    phaseDescription: viewModel.phaseDescription,
                    rowTaps: viewModel.rowTaps,
                    onSelect: { viewModel.rowTaps += 1 }
                )
            } failure: { error, retry in
                Section {
                    SampleInlineFailure(
                        title: "No retained entries",
                        error: error,
                        retry: retry,
                        identifier: "cached-refresh"
                    )
                }
            }

            CachedRefreshControls(viewModel: viewModel)

            Section("What this shows") {
                Text("Refresh keeps real rows readable and interactive until the next result, however long it takes.")
                Text("A successful empty result is retained too. Only invalidation brings back the initial placeholders.")
                Text("Timing controls the local stream producer. Ensemble never delays presentation or results.")
                Text("One binding observes a long-lived stream; a one-shot load can update the same ViewData in tandem.")
            }
        }
        .accessibilityIdentifier(SampleAppAccessibility.cachedRefreshScreen)
        .navigationTitle("Cached refresh")
        .task {
            viewModel.start()
        }
    }
}

private struct CachedRefreshEntries: View {
    let entries: [SampleEntry]
    let source: AsyncContentSource
    let phaseDescription: String
    let rowTaps: Int
    let onSelect: () -> Void

    var body: some View {
        Section {
            if entries.isEmpty {
                Text("No entries. This is a successful empty result.")
                    .accessibilityIdentifier(SampleAppAccessibility.cachedRefreshEmptyState)
            }

            ForEach(entries) { entry in
                Button(action: onSelect) {
                    SampleEntryRow(entry: entry)
                }
                .buttonStyle(.plain)
                // Retained content is real data, not a loading skeleton.
                .redacted(reason: source == .placeholder ? .placeholder : [])
                .disabled(source == .placeholder)
                .accessibilityHidden(source == .placeholder)
                .accessibilityIdentifier(SampleAppAccessibility.cachedRefreshSelect(entry.id))
            }
        } header: {
            HStack {
                Text("Entries")
                Spacer()
                SampleSourceBadge(source: source)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(phaseDescription)
                    .accessibilityIdentifier(SampleAppAccessibility.cachedRefreshPhase)
                Text("Row taps: \(rowTaps)")
                    .accessibilityIdentifier(SampleAppAccessibility.cachedRefreshRowTaps)
            }
        }
    }
}

private struct CachedRefreshControls: View {
    let viewModel: CachedRefreshViewModel

    var body: some View {
        @Bindable var viewModel = viewModel

        Section {
            Picker("Response timing", selection: $viewModel.timing) {
                ForEach(CachedRefreshTiming.allCases) { timing in
                    Text(timing.rawValue).tag(timing)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier(SampleAppAccessibility.cachedRefreshTiming)
            .disabled(viewModel.isLoading)

            Group {
                Button("Refresh successfully", action: viewModel.refreshSuccessfully)
                    .accessibilityIdentifier(SampleAppAccessibility.cachedRefreshSuccess)
                Button("Refresh with failure", action: viewModel.refreshWithFailure)
                    .accessibilityIdentifier(SampleAppAccessibility.cachedRefreshFailure)
                Button("Load empty result", action: viewModel.refreshToEmpty)
                    .accessibilityIdentifier(SampleAppAccessibility.cachedRefreshEmpty)
                Button("Invalidate and reload", action: viewModel.invalidateAndReload)
                    .accessibilityIdentifier(SampleAppAccessibility.cachedRefreshInvalidate)
                Button("Load one value", action: viewModel.loadOneValue)
                    .accessibilityIdentifier(SampleAppAccessibility.cachedRefreshDirect)
            }
            .disabled(viewModel.isLoading)

            if viewModel.timing == .manual {
                Button("Deliver pending response", action: viewModel.deliverPendingResponse)
                    .disabled(!viewModel.hasPendingResponse)
                    .accessibilityIdentifier(SampleAppAccessibility.cachedRefreshDeliver)
            }
        } header: {
            Text("Refresh controls")
        } footer: {
            Text("Fast responds immediately; Slow waits two seconds. Manual holds the response until you deliver it.")
        }
    }
}

private enum CachedRefreshTiming: String, CaseIterable, Identifiable {
    case fast = "Fast"
    case slow = "Slow"
    case manual = "Manual"

    var id: Self { self }
}

@Observable
private final class CachedRefreshViewModel {
    let entries = ViewData(SampleEntry.cached)
    var timing = CachedRefreshTiming.slow
    var rowTaps = 0

    @ObservationIgnored private let context = ViewDataContext()
    @ObservationIgnored private let useCase = CachedRefreshUseCase()
    @ObservationIgnored private var hasStarted = false

    var isLoading: Bool { entries.phase.kind == .loading }
    var hasPendingResponse: Bool { useCase.hasPendingResponse }

    var phaseDescription: String {
        switch entries.phase {
        case .empty:
            "Invalidated: no successful value is available, so placeholders appear immediately."
        case .loading:
            switch entries.latestValue {
            case .unavailable:
                "Loading without a successful value: placeholders appear immediately."
            case .available(let entries) where entries.isEmpty:
                "Refreshing: the successful empty state stays visible until the next result."
            case .available:
                "Refreshing: real rows stay visible and interactive until the next result."
            }
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
        refresh(with: .success(SampleEntry.refreshed))
    }

    func refreshWithFailure() {
        refresh(with: .failure(.offline))
    }

    func refreshToEmpty() {
        refresh(with: .success([]))
    }

    func invalidateAndReload() {
        // Unlike refresh, invalidation deliberately discards the last successful value.
        // Controls exclude overlapping work in this fixture; real apps must cancel stale producers.
        entries.reset()
        refreshSuccessfully()
    }

    func deliverPendingResponse() {
        useCase.deliverPendingResponse()
    }

    private func refresh(with update: CachedRefreshUseCase.Update) {
        useCase.prepare(update, timing: timing)
        // Reload the same destination. Do not reset it or redact retained content.
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

@Observable
private final class CachedRefreshUseCase {
    typealias Update = Result<[SampleEntry], SampleFailure>

    private(set) var hasPendingResponse = false
    @ObservationIgnored private let stream: AsyncStream<Update>
    @ObservationIgnored private let continuation: AsyncStream<Update>.Continuation
    @ObservationIgnored private var nextUpdate: Update = .success(SampleEntry.cached)
    @ObservationIgnored private var timing = CachedRefreshTiming.slow
    @ObservationIgnored private var pendingUpdate: Update?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    init() {
        let (stream, continuation) = AsyncStream<Update>.makeStream()
        self.stream = stream
        self.continuation = continuation
        continuation.yield(.success(SampleEntry.cached))
    }

    func values() -> AsyncStream<Update> {
        stream
    }

    func prepare(_ update: Update, timing: CachedRefreshTiming) {
        nextUpdate = update
        self.timing = timing
    }

    func reload() {
        reloadTask?.cancel()
        pendingUpdate = nextUpdate
        hasPendingResponse = true

        switch timing {
        case .fast:
            deliverPendingResponse()
        case .slow:
            reloadTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.deliverPendingResponse()
            }
        case .manual:
            break
        }
    }

    func deliverPendingResponse() {
        guard let update = pendingUpdate else { return }
        reloadTask?.cancel()
        reloadTask = nil
        pendingUpdate = nil
        hasPendingResponse = false
        continuation.yield(update)
    }
}
