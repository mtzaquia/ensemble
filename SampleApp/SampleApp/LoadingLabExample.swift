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

struct LoadingLabExample: View {
    @State private var viewModel = LoadingLabViewModel()

    var body: some View {
        List {
            Section {
                AsyncContent(
                    viewModel.entries,
                    loading: .placeholder(SampleEntry.placeholders),
                    failure: .cached
                ) { entries, source in
                    SampleEntryRows(entries: entries, source: source)
                } failure: { error, retry in
                    SampleInlineFailure(
                        title: "The request failed",
                        error: error,
                        retry: nil,
                        identifier: "loading-lab"
                    )
                    .accessibilityIdentifier(SampleAppAccessibility.loadingLabFailure)
                }
            } header: {
                HStack {
                    Text("Response")
                    Spacer()
                    SampleSourceBadge(source: viewModel.renderedSource)
                }
            } footer: {
                Text(viewModel.phaseDescription)
            }

            Section("Loading controls") {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Request state", systemImage: "arrow.trianglehead.2.clockwise")

                    Picker(
                        "Request state",
                        selection: Binding(
                            get: { viewModel.requestStage },
                            set: { viewModel.select($0) }
                        )
                    ) {
                        ForEach(LoadingLabRequestStage.allCases) { stage in
                            Text(stage.title)
                                .tag(stage)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier(SampleAppAccessibility.loadingLabStage)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Automatic duration", systemImage: "timer")
                        Spacer()
                        Text(viewModel.duration, format: .number.precision(.fractionLength(1)))
                            .monospacedDigit()
                        Text("seconds")
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: $viewModel.duration, in: 0.5...8, step: 0.5)
                }

                Toggle(
                    "Fail when complete",
                    isOn: Binding(
                        get: { viewModel.shouldFail },
                        set: { viewModel.setShouldFail($0) }
                    )
                )

                Button {
                    viewModel.toggleAutomaticLoading()
                } label: {
                    Label(viewModel.automaticButtonTitle, systemImage: viewModel.automaticButtonImage)
                }
                .accessibilityIdentifier(SampleAppAccessibility.loadingLabStart)
            }

            Section("Cache") {
                Button(role: .destructive) {
                    viewModel.deleteCache()
                } label: {
                    Label("Delete cached value", systemImage: "trash")
                }
                .disabled(viewModel.hasCache == false)
                .accessibilityIdentifier(SampleAppAccessibility.loadingLabDeleteCache)

                Button {
                    viewModel.restoreCache()
                } label: {
                    Label("Restore sample cache", systemImage: "internaldrive")
                }
                .disabled(viewModel.hasCache)
                .accessibilityIdentifier(SampleAppAccessibility.loadingLabRestoreCache)
            }

            Section {
                ForEach(viewModel.events) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack {
                            Image(systemName: event.systemImage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(width: 20)

                            Text("#\(event.id)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.title)
                                .font(.footnote)
                                .fontWeight(.semibold)
                            Text(event.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if viewModel.events.isEmpty {
                    ContentUnavailableView(
                        "No events yet",
                        systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                        description: Text("Use the controls above to build a new history.")
                    )
                } else {
                    Button(role: .destructive) {
                        viewModel.clearHistory()
                    } label: {
                        Label("Clear history", systemImage: "trash")
                    }
                    .accessibilityIdentifier(SampleAppAccessibility.loadingLabClearHistory)
                }
            } header: {
                Text("What happened")
            } footer: {
                Text("Newest first. The lab keeps the most recent 20 events.")
            }
            .accessibilityIdentifier(SampleAppAccessibility.loadingLabHistory)

            Section("Try this") {
                Label("Delete the cache, then choose In-flight to reveal placeholders.", systemImage: "hand.tap")
                Label("Choose Finished to watch the response rows replace the old data.", systemImage: "sparkles")
                Label("Enable failure to compare failure with and without retained content.", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
            }
        }
        .animation(.default, value: viewModel.entries.animationValue)
        .accessibilityIdentifier(SampleAppAccessibility.loadingLabScreen)
        .navigationTitle("Loading lab")
        .task {
            viewModel.start()
        }
    }
}

private struct LoadingLabEvent: Identifiable {
    let id: Int
    let title: String
    let detail: String
    let systemImage: String
}

private enum LoadingLabRequestStage: String, CaseIterable, Identifiable {
    case idle
    case inFlight
    case finished

    var id: Self { self }

    var title: String {
        switch self {
        case .idle: "Idle"
        case .inFlight: "In-flight"
        case .finished: "Finished"
        }
    }
}

@Observable
private final class LoadingLabViewModel {
    let entries = ViewData(SampleEntry.cached)

    var duration = 3.0
    private(set) var shouldFail = false
    private(set) var requestStage = LoadingLabRequestStage.idle
    private(set) var isRunningAutomatically = false
    private(set) var events: [LoadingLabEvent] = []

    @ObservationIgnored private let context = ViewDataContext()
    @ObservationIgnored private let useCase = LoadingLabUseCase()
    @ObservationIgnored private var automaticTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var nextEventID = 0
    @ObservationIgnored private var requestIsActive = false

    var hasCache: Bool {
        entries.latest != nil
    }

    var renderedSource: AsyncContentSource {
        switch entries.phase {
        case .loading:
            entries.latest == nil ? .placeholder : .cached
        case .empty:
            .placeholder
        case .success:
            .live
        case .failure:
            entries.latest == nil ? .placeholder : .cached
        }
    }

    var phaseDescription: String {
        switch entries.phase {
        case .empty:
            "The presentation cache is empty. Choose In-flight or start an automatic request."
        case .loading:
            entries.latest == nil
                ? "No cached value is available, so the placeholder rows are visible."
                : "The retained response stays visible while the next request is in flight."
        case .success:
            "The latest request completed and installed live rows."
        case .failure:
            entries.latest == nil
                ? "The request failed without a value to retain."
                : "The request failed, but the cached rows remain visible."
        }
    }

    var automaticButtonTitle: String {
        isRunningAutomatically ? "Pause automatic loading" : "Run automatically"
    }

    var automaticButtonImage: String {
        isRunningAutomatically ? "pause.fill" : "play.fill"
    }

    func start() {
        guard hasStarted == false else { return }
        hasStarted = true
        context.bind(
            useCase.values,
            to: entries,
            reload: .refresh {}
        )
        useCase.finish(with: .success(SampleEntry.cached))
        record(
            title: "Sample cache installed",
            detail: "The lab started with cached rows ready for the first request.",
            systemImage: "internaldrive"
        )
    }

    func select(_ stage: LoadingLabRequestStage) {
        pauseAutomaticLoading()
        switch stage {
        case .idle:
            moveToIdle()
        case .inFlight:
            beginRequest()
        case .finished:
            beginRequestIfNeeded()
            finishRequest()
        }
    }

    func toggleAutomaticLoading() {
        if isRunningAutomatically {
            pauseAutomaticLoading()
            record(
                title: "Automatic loading paused",
                detail: "The active request remains in its current stage.",
                systemImage: "pause.fill"
            )
        } else {
            runAutomatically()
        }
    }

    func setShouldFail(_ shouldFail: Bool) {
        self.shouldFail = shouldFail
        record(
            title: shouldFail ? "Failure enabled" : "Success enabled",
            detail: shouldFail
                ? "The next completed request will emit an offline failure."
                : "The next completed request will install a new live response.",
            systemImage: shouldFail ? "exclamationmark.triangle" : "checkmark.circle"
        )
    }

    func deleteCache() {
        pauseAutomaticLoading()
        requestIsActive = false
        requestStage = .idle
        entries.reset()
        record(
            title: "Cache deleted",
            detail: "The next in-flight request will render placeholder rows.",
            systemImage: "trash"
        )
    }

    func restoreCache() {
        pauseAutomaticLoading()
        requestIsActive = false
        requestStage = .idle
        useCase.finish(with: .success(SampleEntry.cached))
        record(
            title: "Sample cache restored",
            detail: "The cached response is available for the next loading transition.",
            systemImage: "internaldrive"
        )
    }

    func clearHistory() {
        events.removeAll()
        nextEventID = 0
    }

    private func runAutomatically() {
        beginRequestIfNeeded()
        isRunningAutomatically = true
        record(
            title: "Automatic completion scheduled",
            detail: "The request will finish in \(duration.formatted(.number.precision(.fractionLength(1)))) seconds.",
            systemImage: "timer"
        )

        automaticTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }

            finishRequest()
        }
    }

    private func pauseAutomaticLoading() {
        automaticTask?.cancel()
        automaticTask = nil
        isRunningAutomatically = false
    }

    private func beginRequestIfNeeded() {
        guard requestIsActive == false else { return }
        beginRequest()
    }

    private func beginRequest() {
        let hadCache = entries.latest != nil
        requestIsActive = true
        requestStage = .inFlight
        context.reload(entries)
        record(
            title: "Request started",
            detail: hadCache
                ? "The cached rows remain visible while the request is in flight."
                : "No cached value is available, so placeholder rows are visible.",
            systemImage: "arrow.trianglehead.2.clockwise"
        )
    }

    private func finishRequest() {
        guard requestIsActive else { return }
        requestIsActive = false
        requestStage = .finished
        pauseAutomaticLoading()
        if shouldFail {
            useCase.finish(with: .failure(.offline))
            record(
                title: "Request failed",
                detail: entries.latest == nil
                    ? "No cached value is available, so the failure view replaces the placeholders."
                    : "The cached rows remain visible after the failure.",
                systemImage: "exclamationmark.triangle"
            )
        } else {
            let response = nextResponse()
            useCase.finish(with: .success(response))
            record(
                title: "Request succeeded",
                detail: "The response installed \(response.count) live rows.",
                systemImage: "checkmark.circle"
            )
        }
    }

    private func moveToIdle() {
        requestIsActive = false
        requestStage = .idle
        if let latest = entries.latest {
            useCase.finish(with: .success(latest))
        } else {
            entries.reset()
        }
        record(
            title: "Returned to idle",
            detail: entries.latest == nil
                ? "The response remains empty until another request begins."
                : "The latest response remains available without an active request.",
            systemImage: "pause.circle"
        )
    }

    private func record(
        title: String,
        detail: String,
        systemImage: String
    ) {
        nextEventID += 1
        events.insert(
            LoadingLabEvent(
                id: nextEventID,
                title: title,
                detail: detail,
                systemImage: systemImage
            ),
            at: 0
        )
        if events.count > 20 {
            events.removeLast(events.count - 20)
        }
    }

    private func nextResponse() -> [SampleEntry] {
        let generation = useCase.nextGeneration()
        return [
            SampleEntry(
                id: generation * 100 + 1,
                title: "Request \(generation) completed",
                detail: "This row arrived when the request moved to Finished."
            ),
            SampleEntry(
                id: generation * 100 + 2,
                title: "Animated replacement",
                detail: "Stable data identity drives the list transition."
            ),
            SampleEntry(
                id: generation * 100 + 3,
                title: "Ready to experiment",
                detail: "Choose In-flight to begin another request."
            ),
        ]
    }
}

private final class LoadingLabUseCase {
    typealias Update = Result<[SampleEntry], SampleFailure>

    private let stream: AsyncStream<Update>
    private let continuation: AsyncStream<Update>.Continuation
    private var generation = 0

    init() {
        let (stream, continuation) = AsyncStream<Update>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    func values() -> AsyncStream<Update> {
        stream
    }

    func finish(with update: Update) {
        continuation.yield(update)
    }

    func nextGeneration() -> Int {
        generation += 1
        return generation
    }
}
